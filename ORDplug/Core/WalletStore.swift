import Foundation
import SwiftUI
import Combine

/// Central wallet state — the iOS counterpart of the extension's in-memory
/// state (_accounts/_active/_wif/_address) plus all wallet operations.
/// Keys are held in memory ONLY while unlocked; the persistent copy lives in
/// the hardware-encrypted Keychain (Face ID gated).
@MainActor
final class WalletStore: ObservableObject {

    enum Phase {
        case loading
        case setup          // no vault on this device yet
        case locked
        case unlocked
    }

    @Published var phase: Phase = .loading
    @Published var accounts: [Account] = []
    @Published var active: Int = 0
    @Published var balance: Balance?
    @Published var usdRate: Double?
    @Published var holdings: [Holding] = []
    @Published var indexerOk = true
    /// OpNS index reachable? Kept SEPARATE from indexerOk so a broken OpNS API
    /// degrades only the OpNS tab — SNS/BSVmaps stay exactly as they were.
    @Published var opnsOk = true
    @Published var addressBook: [BookEntry] = []
    @Published var connectedSites: [String: Bool] = [:]   // session-only, like chrome.storage.session
    @Published var pendingProviderRequest: ProviderRequest?
    /// v2.3 — cross-tab request: ORD/ner asks the Browser tab to open a TXID
    @Published var browserOpenRequest: String?
    /// v2.5 — BRC-100 permission prompt (native SwiftUI sheet + Face ID)
    @Published var pendingBrc100Permission: Brc100PermissionRequest?
    /// v2.6 — BRC-100 per-transaction confirmation (money ≠ grant: never persisted)
    @Published var pendingBrc100TxConfirm: Brc100TxConfirmRequest?

    /// recovery phrases entered/created THIS session, keyed by address —
    /// memory only, never persisted (only the WIF is stored). Port of _sessionPhrases.
    var sessionPhrases: [String: String] = [:]

    private var lastBackgrounded: Date?

    let engine = WalletEngine.shared

    static let autolockKey = "ordplug_autolock_min"
    static let addressBookKey = "ordplug_addressbook"

    var activeAccount: Account? {
        accounts.indices.contains(active) ? accounts[active] : nil
    }
    var address: String { activeAccount?.address ?? "" }
    var wif: String { activeAccount?.wif ?? "" }

    var autolockMinutes: Int {
        get {
            let v = UserDefaults.standard.object(forKey: Self.autolockKey) as? Int
            return v ?? 15
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.autolockKey)
        }
    }

    init() {
        phase = Keychain.vaultExists() ? .locked : .setup
        loadAddressBook()
        loadChainState()
    }

    // MARK: - chain mechanism (v2.3) — consecutive TXs without waiting
    //
    // After every successful broadcast the wallet registers its own change /
    // split outputs as immediately-spendable "chain tips" and puts the inputs
    // it just spent in a spent-guard. utxos() then serves: WoC list minus the
    // guard, plus the tips WoC doesn't know yet. Result: Send, Inscribe,
    // ordinal transfers and the UTXO tools can run back-to-back without
    // "no spendable UTXOs". 1-sat outputs are NEVER tips (ordinal protection
    // lives in txSpendInfo and shapeUtxos alike).

    struct ChainTip: Codable, Equatable {
        var txid: String
        var vout: Int
        var satoshis: Int
    }
    static let chainTipsKey = "ordplug_chain_tips_v1"
    static let spentGuardKey = "ordplug_spent_guard_v1"
    private var chainTips: [String: [ChainTip]] = [:]
    private var spentGuard: [String: Set<String>] = [:]

    private func loadChainState() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.chainTipsKey),
           let tips = try? JSONDecoder().decode([String: [ChainTip]].self, from: data) {
            chainTips = tips
        }
        if let data = d.data(forKey: Self.spentGuardKey),
           let g = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            spentGuard = g
        }
    }
    private func saveChainState() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(chainTips) { d.set(data, forKey: Self.chainTipsKey) }
        if let data = try? JSONEncoder().encode(spentGuard) { d.set(data, forKey: Self.spentGuardKey) }
    }

    /// on unlock / account switch: drop tips that are provably spent (the
    /// direct spent-endpoint; unknown keeps the tip — it fails fast on
    /// conflict anyway) and keep the guard bounded.
    func validateChainTips() async {
        let addr = address
        guard !addr.isEmpty else { return }
        let tips = chainTips[addr] ?? []
        if !tips.isEmpty {
            var keep: [ChainTip] = []
            for t in tips {
                if await Api.outpointSpent(txid: t.txid, vout: t.vout) == true { continue }
                keep.append(t)
            }
            chainTips[addr] = keep
        }
        if (spentGuard[addr]?.count ?? 0) > 300 { spentGuard[addr] = [] }
        saveChainState()
    }

    /// bookkeeping after a successful broadcast of OUR OWN tx
    private func registerBroadcast(rawtx: String) {
        guard let info = try? engine.dict("txSpendInfo", ["rawtx": rawtx, "address": address]) else { return }
        var g = spentGuard[address] ?? []
        for i in (info["inputs"] as? [[String: Any]] ?? []) {
            if let t = i["txid"] as? String, let v = i["vout"] as? Int { g.insert("\(t):\(v)") }
        }
        spentGuard[address] = g
        var tips = chainTips[address] ?? []
        tips.removeAll { g.contains("\($0.txid):\($0.vout)") }
        for o in (info["ownOutputs"] as? [[String: Any]] ?? []) {
            if let t = o["txid"] as? String, let v = o["vout"] as? Int, let s = o["satoshis"] as? Int {
                tips.append(ChainTip(txid: t, vout: v, satoshis: s))
            }
        }
        chainTips[address] = tips
        saveChainState()
    }

    /// broadcast + chain bookkeeping. On a mempool-conflict the local picture
    /// was stale: guard the attempted inputs, drop the tips and ask (inline)
    /// for one retry on a fresh set.
    func broadcastAndRegister(rawtx: String) async throws -> String {
        do {
            let txid = try await Api.broadcast(rawtx: rawtx)
            registerBroadcast(rawtx: rawtx)
            return txid
        } catch {
            let m = error.localizedDescription.lowercased()
            if m.contains("conflict") || m.contains("missing inputs") || m.contains("mempool") {
                if let info = try? engine.dict("txSpendInfo", ["rawtx": rawtx, "address": address]) {
                    var g = spentGuard[address] ?? []
                    for i in (info["inputs"] as? [[String: Any]] ?? []) {
                        if let t = i["txid"] as? String, let v = i["vout"] as? Int { g.insert("\(t):\(v)") }
                    }
                    spentGuard[address] = g
                }
                chainTips[address] = []
                saveChainState()
                throw WalletEngine.EngineError.callFailed(
                    error.localizedDescription + " — The wallet dropped its local UTXO chain and will fetch a fresh set. Try again.")
            }
            throw error
        }
    }

    // MARK: - vault lifecycle

    private func payloadData() throws -> Data {
        let payload = VaultPayload(
            accounts: accounts.map { .init(name: $0.name, wif: $0.wif, origin: $0.origin, path: $0.path) },
            active: active
        )
        return try JSONEncoder().encode(payload)
    }

    func saveAccounts() throws {
        guard phase == .unlocked else { throw Keychain.KeychainError.authFailed("Wallet is locked.") }
        try Keychain.saveVault(try payloadData())
    }

    private func apply(_ payload: VaultPayload) throws {
        accounts = try payload.accounts.map { a in
            Account(name: a.name, wif: a.wif, origin: a.origin ?? "wif", path: a.path,
                    address: try engine.wifToAddress(a.wif))
        }
        active = min(payload.active, max(0, accounts.count - 1))
    }

    func unlock() async throws {
        // Keychain read blocks while the Face ID prompt is up — keep it off the main thread
        let data = try await Task.detached(priority: .userInitiated) {
            try Keychain.readVault(reason: "Unlock your ORD/net wallet")
        }.value
        let payload = try JSONDecoder().decode(VaultPayload.self, from: data)
        try apply(payload)
        phase = .unlocked
        lastBackgrounded = nil
        loadInscriptions()
        await refreshBalance()
        await loadHoldings()
        await validateChainTips()
    }

    func lock() {
        accounts = []
        active = 0
        balance = nil
        holdings = []
        sessionPhrases = [:]
        pendingProviderRequest = nil
        pendingBrc100Permission = nil
        pendingBrc100TxConfirm = nil   // v2.6: a locked wallet answers no money question
        engine.brc100Reset()   // v2.5: wipe BRC-100 key material from the engine
        phase = .locked
    }

    func removeWallet() {
        Keychain.deleteVault()
        accounts = []
        active = 0
        balance = nil
        holdings = []
        sessionPhrases = [:]
        connectedSites = [:]
        // wipe app data tied to the removed wallet — nothing stays behind
        addressBook = []
        inscriptions = []
        allInscriptions = [:]
        UserDefaults.standard.removeObject(forKey: Self.addressBookKey)
        UserDefaults.standard.removeObject(forKey: Self.inscriptionsKey)
        phase = .setup
    }

    /// auto-lock bookkeeping driven by scenePhase
    func sceneBackgrounded() {
        if phase == .unlocked { lastBackgrounded = Date() }
    }
    func sceneActivated() {
        guard phase == .unlocked, let t = lastBackgrounded else { return }
        lastBackgrounded = nil
        let mins = autolockMinutes
        if mins > 0 && Date().timeIntervalSince(t) > Double(mins) * 60 { lock() }
    }

    // MARK: - create / import

    func createWallet(mnemonic: String, accountName: String) throws {
        guard try engine.validateMnemonic(mnemonic) else {
            throw WalletEngine.EngineError.callFailed("Recovery phrase missing — go back and try again.")
        }
        let wif = try engine.wif(fromMnemonic: mnemonic, mode: .bip44)
        let addr = try engine.wifToAddress(wif)
        accounts = [Account(name: accountName.isEmpty ? "Account 1" : accountName,
                            wif: wif, origin: "bip44", path: Fees.bip44Path, address: addr)]
        sessionPhrases[addr] = mnemonic
        active = 0
        phase = .unlocked
        try saveAccounts()
    }

    struct ImportResult {
        var wif: String
        var origin: String
        var path: String?
        var phrase: String?
    }

    /// port of wifFromImportInputs + otherWalletResolve
    func resolveImport(mode: ImportMode, mnemonic: String, wifInput: String,
                       presetPath: String? = nil, pin: String = "") throws -> ImportResult {
        switch mode {
        case .wif:
            let w = wifInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty else { throw WalletEngine.EngineError.callFailed("Enter a private key (WIF).") }
            _ = try engine.wifToAddress(w) // validates
            return ImportResult(wif: w, origin: "wif", path: nil, phrase: nil)
        case .bip44, .legacy, .path:
            let m = mnemonic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard try engine.validateMnemonic(m) else {
                throw WalletEngine.EngineError.callFailed("Invalid recovery phrase.")
            }
            switch mode {
            case .legacy:
                return ImportResult(wif: try engine.wif(fromMnemonic: m, mode: .legacy), origin: "legacy", path: nil, phrase: m)
            case .path:
                let p = presetPath ?? Fees.bip44Path
                let w = try engine.wif(fromMnemonic: m, mode: .path, path: p, pin: pin)
                return ImportResult(wif: w, origin: "bip44", path: p, phrase: m)
            default:
                return ImportResult(wif: try engine.wif(fromMnemonic: m, mode: .bip44), origin: "bip44", path: Fees.bip44Path, phrase: m)
            }
        }
    }

    func importWallet(_ r: ImportResult, accountName: String) throws {
        let addr = try engine.wifToAddress(r.wif)
        accounts = [Account(name: accountName.isEmpty ? "Account 1" : accountName,
                            wif: r.wif, origin: r.origin, path: r.path, address: addr)]
        if let p = r.phrase { sessionPhrases[addr] = p }
        active = 0
        phase = .unlocked
        try saveAccounts()
    }

    // MARK: - accounts

    func setActive(_ i: Int) {
        guard accounts.indices.contains(i) else { return }
        active = i
        try? saveAccounts()
        loadInscriptions()
        Task {
            await refreshBalance()
            await loadHoldings()
            await validateChainTips()
        }
    }

    func addAccount(name: String, result: ImportResult?) throws {
        let r: ImportResult
        if let result { r = result }
        else { r = ImportResult(wif: try engine.randomWif(), origin: "random", path: nil, phrase: nil) }
        let addr = try engine.wifToAddress(r.wif)
        guard !accounts.contains(where: { $0.address == addr }) else {
            throw WalletEngine.EngineError.callFailed("That account is already in the wallet.")
        }
        let nm = name.isEmpty ? "Account \(accounts.count + 1)" : name
        accounts.append(Account(name: nm, wif: r.wif, origin: r.origin, path: r.path, address: addr))
        if let p = r.phrase { sessionPhrases[addr] = p }
        try saveAccounts()
    }

    func renameAccount(_ i: Int, to name: String) {
        guard accounts.indices.contains(i), !name.isEmpty else { return }
        accounts[i].name = name
        try? saveAccounts()
    }

    func removeAccount(_ i: Int) {
        guard accounts.count > 1, accounts.indices.contains(i) else { return }
        accounts.remove(at: i)
        if active >= accounts.count { active = accounts.count - 1 }
        if active == i { active = max(0, i - 1) }
        active = min(active, accounts.count - 1)
        try? saveAccounts()
    }

    // MARK: - chain data

    func refreshBalance() async {
        guard !address.isEmpty else { return }
        balance = try? await Api.balance(address: address)
        usdRate = await Api.exchangeRate()
    }

    /// shaped UTXOs for the active account (ordinal-protected, like getUTXOs).
    /// v2.3: minus the spent-guard, plus our own chain tips WoC doesn't list
    /// yet — so consecutive transactions never starve for funding.
    func utxos() async throws -> [[String: Any]] {
        let raw = try await Api.rawUnspent(address: address)
        let rawJson = String(data: try JSONSerialization.data(withJSONObject: raw), encoding: .utf8) ?? "[]"
        var shaped = try engine.array("shapeUtxos", ["raw": rawJson, "address": address])
        let guarded = spentGuard[address] ?? []
        shaped.removeAll { u in
            guarded.contains("\((u["txid"] as? String) ?? ""):\((u["vout"] as? Int) ?? -1)")
        }
        // v2.6 — BRC-100 relinquishOutput: outpoints the wallet must no longer
        // manage are excluded from funding (persisted per address)
        let relinquished = brc100Relinquished()
        if !relinquished.isEmpty {
            shaped.removeAll { u in
                relinquished.contains("\((u["txid"] as? String) ?? "").\((u["vout"] as? Int) ?? -1)")
            }
        }
        let listed = Set(shaped.map { "\(($0["txid"] as? String) ?? ""):\(($0["vout"] as? Int) ?? -1)" })
        let freshTips = (chainTips[address] ?? []).filter {
            !listed.contains("\($0.txid):\($0.vout)") && !guarded.contains("\($0.txid):\($0.vout)")
        }
        if !freshTips.isEmpty {
            // shape the tips through the SAME engine path (incl. ordinal filter)
            let tipRaw = freshTips.map { ["tx_hash": $0.txid, "tx_pos": $0.vout, "value": $0.satoshis] as [String: Any] }
            let tipJson = String(data: try JSONSerialization.data(withJSONObject: tipRaw), encoding: .utf8) ?? "[]"
            shaped += try engine.array("shapeUtxos", ["raw": tipJson, "address": address])
        }
        return shaped
    }

    private func utxosJson(_ u: [[String: Any]]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: u), encoding: .utf8) ?? "[]"
    }

    // MARK: - send / inscribe / dApp tx

    func sendBSV(to: String, amountSat: Int, dataStr: String? = nil, feeSat: Int = 0) async throws -> String {
        let u = try await utxos()
        var args: [String: Any] = ["wif": wif, "utxos": try utxosJson(u), "to": to, "amountSat": amountSat, "feeSat": feeSat]
        if let d = dataStr { args["dataStr"] = d }
        let r = try engine.dict("buildSend", args)
        guard let rawtx = r["rawtx"] as? String else { throw WalletEngine.EngineError.badResponse }
        return try await broadcastAndRegister(rawtx: rawtx)
    }

    func inscribe(contentType: String, dataB64: String, feeSat: Int = 0) async throws -> String {
        let u = try await utxos()
        let r = try engine.dict("buildInscribe", ["wif": wif, "utxos": try utxosJson(u),
                                                  "contentType": contentType, "dataB64": dataB64, "feeSat": feeSat])
        guard let rawtx = r["rawtx"] as? String else { throw WalletEngine.EngineError.badResponse }
        return try await broadcastAndRegister(rawtx: rawtx)
    }

    func sendComposedTx(params: [String: Any]) async throws -> (txid: String?, rawtx: String) {
        let u = try await utxos()
        let paramsJson = String(data: try JSONSerialization.data(withJSONObject: params), encoding: .utf8) ?? "{}"
        let r = try engine.dict("buildTx", ["wif": wif, "utxos": try utxosJson(u), "params": paramsJson])
        guard let rawtx = r["rawtx"] as? String else { throw WalletEngine.EngineError.badResponse }
        if let b = params["broadcast"] as? Bool, b == false { return (nil, rawtx) }
        let txid = try await broadcastAndRegister(rawtx: rawtx)
        return (txid, rawtx)
    }

    // MARK: - BRC-100 permissions (v2.5) — BRC-43 grants, persistent
    //
    // Grants follow the standard, not "per keer": security level 0 = open (no
    // prompt), level 1 = ONE persistent grant per app per protocol, level 2 =
    // per app per protocol per counterparty. The identity key has its own
    // per-app grant. Approval is a NATIVE SwiftUI sheet with Face ID — never
    // an HTML dialog the page could fake.

    static let brc100GrantsKey = "ordplug_brc100_grants_v1"

    private var brc100Grants: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.brc100GrantsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.brc100GrantsKey) }
    }

    /// throws a standards-shaped error when the user denies; returns silently
    /// when allowed (level 0, an existing grant, or a fresh approval)
    func requireBrc100Permission(origin: String, method: String, args: [String: Any]) async throws {
        let isIdentity = method == "getPublicKey" && (args["identityKey"] as? Bool) == true
        var level = 0
        var protocolName = "—"
        if let p = args["protocolID"] as? [Any], p.count == 2 {
            level = (p[0] as? Int) ?? (p[0] as? Double).map(Int.init) ?? 0
            protocolName = (p[1] as? String) ?? "—"
        }
        let counterparty = (args["counterparty"] as? String) ?? "self"

        // BRC-43 level 0: open protocol — no permission required
        if !isIdentity && level == 0 { return }

        let grantKey: String = isIdentity
            ? "\(address)|\(origin)|identity"
            : "\(address)|\(origin)|\(level)|\(protocolName)\(level >= 2 ? "|\(counterparty)" : "")"
        if brc100Grants.contains(grantKey) { return }

        let title: String
        switch method {
        case "getPublicKey": title = isIdentity ? "Share identity key" : "Share a derived public key"
        case "encrypt":          title = "Encrypt data"
        case "decrypt":          title = "Decrypt data"
        case "createSignature":  title = "Create a signature"
        case "verifySignature":  title = "Verify a signature"
        case "createHmac":       title = "Create an HMAC"
        case "verifyHmac":       title = "Verify an HMAC"
        default:                 title = method
        }
        var detail = isIdentity
            ? "The app asks for your identity key (a public key that identifies this wallet to the app)."
            : "Protocol: \(protocolName) · security level \(level)"
        if !isIdentity && level >= 2 {
            detail += "\nCounterparty: \(Fmt.shortAddress(counterparty))"
        }

        let approved = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pendingBrc100Permission = Brc100PermissionRequest(
                origin: origin.isEmpty ? "unknown app" : origin,
                title: title, detail: detail, continuation: cont)
        }
        guard approved else {
            throw Brc100.Err(name: "WERR_PERMISSION_DENIED", code: 1,
                             message: "The user denied \(title.lowercased()) for \(origin).")
        }
        var g = brc100Grants
        g.insert(grantKey)
        brc100Grants = g
    }

    // MARK: - BRC-100 grants manager (v2.6, Settings)

    /// decode the stored grant keys for the ACTIVE address into rows the
    /// Settings screen can show — the raw key doubles as the revoke handle
    func brc100GrantsList() -> [Brc100GrantInfo] {
        brc100Grants.compactMap { key in
            let parts = key.components(separatedBy: "|")
            guard parts.count >= 3, parts[0] == address else { return nil }
            let origin = parts[1]
            let detail: String
            if parts[2] == "identity" {
                detail = "Identity key"
            } else if parts.count >= 4 {
                detail = "Level \(parts[2]) · protocol “\(parts[3])”"
                    + (parts.count >= 5 ? " · counterparty \(Fmt.shortAddress(parts[4]))" : "")
            } else {
                detail = parts[2]
            }
            return Brc100GrantInfo(key: key, origin: origin, detail: detail)
        }
        .sorted { ($0.origin, $0.detail) < ($1.origin, $1.detail) }
    }

    func brc100RevokeGrant(_ key: String) {
        var g = brc100Grants
        g.remove(key)
        brc100Grants = g
        objectWillChange.send()
    }

    func brc100RevokeAllGrants(origin: String) {
        var g = brc100Grants
        g = g.filter { !($0.hasPrefix("\(address)|\(origin)|")) }
        brc100Grants = g
        objectWillChange.send()
    }

    // MARK: - BRC-100 fase 3 (v2.6): geld — bevestiging, actielog, relinquish

    static let brc100ActionsKey = "ordplug_brc100_actions_v1"
    static let brc100RelinquishedKey = "ordplug_brc100_relinquished_v1"

    /// per-transaction Face ID confirmation. Money ≠ grant (hard rule 2):
    /// nothing is persisted, every transaction asks again. Throws the
    /// standards-shaped rejection on deny.
    func requireBrc100TxConfirm(origin: String, title: String, description: String,
                                lines: [Brc100TxLine], minerFeeEstimate: Int,
                                serviceFees: Int, totalSat: Int, incoming: Bool) async throws {
        let approved = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pendingBrc100TxConfirm = Brc100TxConfirmRequest(
                origin: origin.isEmpty ? "unknown app" : origin,
                title: title, description: description, lines: lines,
                minerFeeEstimate: minerFeeEstimate, serviceFees: serviceFees,
                totalSat: totalSat, incoming: incoming, continuation: cont)
        }
        guard approved else {
            throw Brc100.Err(name: "WERR_PERMISSION_DENIED", code: 1,
                             message: "The user rejected the transaction for \(origin).")
        }
    }

    /// local action log per address (pattern of the inscription log) — feeds
    /// listActions; contains exactly the BRC-100 actions made via this app
    func brc100Actions() -> [Brc100ActionRecord] {
        guard let data = UserDefaults.standard.data(forKey: Self.brc100ActionsKey),
              let dict = try? JSONDecoder().decode([String: [Brc100ActionRecord]].self, from: data) else { return [] }
        return dict[address] ?? []
    }

    func brc100LogAction(_ rec: Brc100ActionRecord) {
        var dict: [String: [Brc100ActionRecord]] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.brc100ActionsKey),
           let d = try? JSONDecoder().decode([String: [Brc100ActionRecord]].self, from: data) { dict = d }
        var list = dict[address] ?? []
        list.insert(rec, at: 0)   // newest first
        dict[address] = list
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: Self.brc100ActionsKey)
        }
    }

    /// outpoints the wallet was asked to stop managing (relinquishOutput) —
    /// persisted per address and excluded from funding in utxos()
    func brc100Relinquished() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: Self.brc100RelinquishedKey),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [] }
        return Set(dict[address] ?? [])
    }

    func brc100Relinquish(outpoint: String) {
        var dict: [String: [String]] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.brc100RelinquishedKey),
           let d = try? JSONDecoder().decode([String: [String]].self, from: data) { dict = d }
        var list = Set(dict[address] ?? [])
        list.insert(outpoint)
        dict[address] = Array(list)
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: Self.brc100RelinquishedKey)
        }
    }

    // MARK: - UTXO tools (v2.3): split & combine — service fees like everywhere

    /// N equal outputs to self via the existing (verified) buildTx path
    func splitUtxos(count: Int, satsEach: Int) async throws -> String {
        guard count >= 2, count <= 200 else { throw WalletEngine.EngineError.callFailed("Choose between 2 and 200 UTXOs.") }
        guard satsEach >= 547 else { throw WalletEngine.EngineError.callFailed("Each UTXO needs at least 547 sats (above dust).") }
        let u = try await utxos()
        let outs: [[String: Any]] = (0..<count).map { _ in ["type": "p2pkh", "address": address, "satoshis": satsEach] }
        let paramsJson = String(data: try JSONSerialization.data(withJSONObject: ["outputs": outs]), encoding: .utf8) ?? "{}"
        let r = try engine.dict("buildTx", ["wif": wif, "utxos": try utxosJson(u), "params": paramsJson])
        guard let rawtx = r["rawtx"] as? String else { throw WalletEngine.EngineError.badResponse }
        return try await broadcastAndRegister(rawtx: rawtx)
    }

    /// ALL spendable (ordinal-protected) UTXOs into one output to self
    func combineUtxos() async throws -> (txid: String, outputSat: Int) {
        let u = try await utxos()
        let r = try engine.dict("buildConsolidate", ["wif": wif, "utxos": try utxosJson(u)])
        guard let rawtx = r["rawtx"] as? String, let outSat = r["outputSat"] as? Int else {
            throw WalletEngine.EngineError.badResponse
        }
        let txid = try await broadcastAndRegister(rawtx: rawtx)
        return (txid, outSat)
    }

    // MARK: - holdings (SNS + BSVmaps + OpNS)

    func loadHoldings() async {
        guard !address.isEmpty else { return }
        // SNS + BSVmaps: UNCHANGED logic in its own do/catch — an OpNS failure
        // can never touch this, and vice versa (graceful degradation per side)
        var combined: [Holding] = []
        do {
            var h = try await Api.holdings(address: address)
            indexerOk = true
            // mergeListings(): the global registry knows listed items the indexer doesn't
            let listings = await Api.listings()
            let mine = listings.filter { ($0["sellerAddress"] as? String) == address }
            if !mine.isEmpty {
                var byDistrict: [String: [String: Any]] = [:]
                for l in mine {
                    if let d = l["district"] { byDistrict[String(describing: d)] = l }
                }
                for i in h.indices where h[i].kind == .bsvmap {
                    if let d = h[i].district, let l = byDistrict[String(d)] {
                        h[i].status = "listed"
                        let p = (l["priceSat"] as? Double).map { Int($0.rounded()) } ?? (l["priceSat"] as? Int) ?? 0
                        h[i].priceSat = p
                    }
                }
            }
            combined = h
        } catch {
            indexerOk = false
            combined = []
        }
        // OpNS: third category, own do/catch + own status flag
        do {
            combined += try await Api.opnsHoldings(address: address)
            opnsOk = true
        } catch {
            opnsOk = false
        }
        // v2.6.1 — merge DOMAIN-registry listings (v2 platform, USD) into the
        // SNS rows. This is a SEPARATE marketplace from the bsvmap.io ordinal
        // listings: without this merge a domain listed via the Domains tab
        // kept showing "held" here. Display-only; managing the listing stays
        // in the Domains tab (never the bsvmap list/delist flows).
        if let doms = try? await Api.myDomains(address: address) {
            let listedDomains = Dictionary(doms.filter { $0.isForSale }
                .map { ($0.name.lowercased(), $0.listingPrice ?? 0) },
                uniquingKeysWith: { a, _ in a })
            if !listedDomains.isEmpty {
                for i in combined.indices where combined[i].kind == .sns {
                    if let usd = listedDomains[combined[i].name.lowercased()] {
                        combined[i].domainListedUsd = usd
                    }
                }
            }
        }
        holdings = combined
    }

    // MARK: - OpNS payment resolution (the four rules)

    /// Resolve an OpNS name to a VERIFIED payment target:
    /// 1. exact match only — a `fallback: true` answer is a DIFFERENT name and
    ///    surfaces as an inline "did you mean …?" error, never a payment
    /// 2. the current outpoint is checked unspent on WhatsOnChain
    /// 3. the holder address is RECOMPUTED from the outpoint's locking script
    ///    on chain and must equal what the index claims — trust but verify
    /// 4. paymail forms (name@host) are rejected by the caller before this
    func resolveOpnsPayment(name: String) async throws -> OpnsPayTarget {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        let (fallback, records) = try await Api.opnsLookup(name: n)
        guard !fallback, let rec = records.first(where: { $0.name == n }) else {
            if let suggestion = records.first?.name, suggestion != n {
                throw WalletEngine.EngineError.callFailed(
                    "OpNS name \"\(n)\" does not exist. Did you mean \"\(suggestion)\"? Nothing was paid.")
            }
            throw WalletEngine.EngineError.callFailed("OpNS name \"\(n)\" does not exist. Nothing was paid.")
        }
        guard !rec.ambiguous else {
            throw WalletEngine.EngineError.callFailed(
                "OpNS name \"\(n)\" is marked ambiguous by the index — not safe to pay.")
        }
        // recompute the holder address from the chain (raw hex is authoritative)
        let hex = try await Api.txHex(rec.currentTxid)
        let script = try engine.string("outputScriptHex", ["rawTxHex": hex, "vout": rec.currentVout])
        guard let holder = (try? engine.call("scriptLockAddress", ["scriptHex": script])) as? String,
              !holder.isEmpty else {
            throw WalletEngine.EngineError.callFailed(
                "Could not derive the holder address from the chain for \"\(n)\".")
        }
        guard holder == rec.ownerAddress else {
            throw WalletEngine.EngineError.callFailed(
                "The OpNS index and the chain disagree about the holder of \"\(n)\" — refusing to pay. Try again in a moment.")
        }
        // outpoint must be PROVABLY unspent (direct spent-endpoint; v2.2.3):
        // spent → refuse; unknown → refuse honestly (OpNS is fail-closed per
        // its briefing) but NEVER claim "spent" when it is merely unknown
        switch await Api.outpointSpent(txid: rec.currentTxid, vout: rec.currentVout) {
        case true?:
            throw WalletEngine.EngineError.callFailed(
                "The ordinal of \"\(n)\" was spent — the name may have just changed hands. Re-resolve and try again.")
        case false?:
            break
        case nil:
            throw WalletEngine.EngineError.callFailed(
                "Could not verify the spent-status of \"\(n)\" right now (WhatsOnChain gave no answer) — not paying. Try again in a moment.")
        }
        return OpnsPayTarget(name: n, holderAddress: holder,
                             currentTxid: rec.currentTxid, currentVout: rec.currentVout)
    }

    // MARK: - SNS resolver payment (signed answers, level "prove")

    /// resolver key management: pre-pinned key (resolver v1.3, verified live
    /// 03-08-2026); a proven succession chain may move the pin — nothing else.
    static let snsPrePinnedPubkey = "03088f1da3bfc998c1bc7bbc1ffcb7d96c47e094624a52d78406f8c3105b0d0b46"
    static let snsPinKey = "ordplug_sns_pinned_pubkey"
    var snsPinnedPubkey: String {
        UserDefaults.standard.string(forKey: Self.snsPinKey) ?? Self.snsPrePinnedPubkey
    }

    /// Resolve `naam.tld` or `mailbox@naam.tld` to a VERIFIED payment target:
    /// signed answer → signature against the pinned key (rotation only via a
    /// proven succession chain) → expires → holder address derived from the
    /// SIGNED holder_script → outpoint checked unspent (freshness, not script
    /// equality — custody scripts may differ). Every resolver error carries a
    /// readable message; it is thrown for INLINE display, never a popup.
    func resolveSnsPayment(input: String) async throws -> SnsPayTarget {
        let q = input.trimmingCharacters(in: .whitespaces).lowercased()
        let (_, body) = try await Api.snsResolveRaw(q)
        guard let data = body.data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WalletEngine.EngineError.callFailed("The SNS resolver returned an unreadable answer.")
        }
        // error answers: show the resolver's own message inline (not_verified
        // is PERMANENT until the name carries the ✓; no_holder means retry)
        guard (j["ok"] as? Bool) == true else {
            let code = j["error"] as? String ?? "resolver_error"
            let msg = j["message"] as? String ?? "SNS resolver error: \(code)"
            throw WalletEngine.EngineError.callFailed(msg)
        }

        let nowTs = Int(Date().timeIntervalSince1970)
        var v = try engine.dict("snsVerifyAnswer", ["answerJson": body, "expectedSigner": snsPinnedPubkey, "nowTs": nowTs])
        var rotationNote = ""

        // unknown signer → prove the succession chain from the pin; only a
        // closing chain re-pins. Never "accept anyway".
        if (v["valid"] as? Bool) != true, (v["reason"] as? String) == "unknown_signer" {
            let info = try await Api.snsPubkeyInfo()
            // field verified live 03-08-2026: GET /pubkey -> {ok, signer, seq, rotations:[]}
            let records = info["rotations"] as? [[String: Any]] ?? []
            let recordsJson = String(data: try JSONSerialization.data(withJSONObject: records), encoding: .utf8) ?? "[]"
            let proven = try engine.string("snsVerifyRotationChain", ["pinnedPub": snsPinnedPubkey, "records": recordsJson])
            guard proven.lowercased() == (v["signer"] as? String ?? "") else {
                throw WalletEngine.EngineError.callFailed(
                    "The resolver signs with a new key, but the succession chain does not prove it — refusing. The pinned key is unchanged.")
            }
            UserDefaults.standard.set(proven, forKey: Self.snsPinKey)
            rotationNote = "Resolver key rotated — the succession chain was verified and the new key is now pinned."
            v = try engine.dict("snsVerifyAnswer", ["answerJson": body, "expectedSigner": proven, "nowTs": nowTs])
        }

        guard (v["valid"] as? Bool) == true else {
            let reason = v["reason"] as? String ?? "invalid"
            let text: String
            switch reason {
            case "bad_signature": text = "The resolver answer carries an INVALID signature — refusing. Try again; if this persists the resolver may be compromised."
            case "expired":       text = "The resolver answer expired — resolve again and retry."
            case "unsupported_holder_script": text = "The holder script is not a standard P2PKH script — this wallet cannot derive a pay-to address from it safely."
            default:              text = "The resolver answer could not be verified (\(reason))."
            }
            throw WalletEngine.EngineError.callFailed(text)
        }

        guard let holder = v["holderAddress"] as? String,
              let curTxid = v["currentTxid"] as? String else {
            throw WalletEngine.EngineError.callFailed("The verified answer misses required fields.")
        }
        let curVout = (v["currentVout"] as? Int) ?? 0

        // freshness (v2.2.3, direct spent-endpoint): only a PROVABLY spent
        // outpoint gives stale_outpoint; UNKNOWN never blocks as spent — the
        // signed answer (300 s validity) is the authority, with an inline note
        let spent = await Api.outpointSpent(txid: curTxid, vout: curVout)
        if spent == true {
            throw WalletEngine.EngineError.callFailed(
                "stale_outpoint: the inscription of \(v["name"] as? String ?? q) was spent — the name may have just changed hands. Resolve again and retry.")
        }

        var warning = rotationNote
        if spent == nil {
            warning += (warning.isEmpty ? "" : "\n")
                + "Note: the spent-status could not be additionally verified right now (WhatsOnChain gave no answer) — the SIGNED resolver answer (valid for 300 s) is the authority for this payment."
        }
        if (v["addressMismatch"] as? Bool) == true {
            warning += (warning.isEmpty ? "" : "\n")
                + "Note: the resolver's display address differs from the signed script — the wallet pays the SIGNED script's address shown here."
        }
        return SnsPayTarget(
            name: v["name"] as? String ?? q,
            mailbox: v["mailbox"] as? String ?? "",
            fallback: (v["fallback"] as? Bool) ?? false,
            holderAddress: holder,
            currentTxid: curTxid,
            currentVout: curVout,
            expires: (v["expires"] as? Int) ?? 0,
            warning: warning
        )
    }

    // MARK: - ordinal transfer

    func sendOrdinal(_ holding: Holding, to: String) async throws -> String {
        // raw hex is byte-for-byte authoritative — never the WoC verbose endpoint
        let ordHex = try await Api.txHex(holding.currentTxid)
        let ordScriptHex = try engine.string("outputScriptHex", ["rawTxHex": ordHex, "vout": holding.currentVout])

        let fees = try engine.fees()
        var all = try await utxos()
        all.removeAll { ($0["txid"] as? String) == holding.currentTxid && ($0["vout"] as? Int) == holding.currentVout }
        guard !all.isEmpty else {
            throw WalletEngine.EngineError.callFailed("No spendable funding UTXOs for the fee. Your balance may be locked in pending transactions.")
        }
        let required = fees.ordinalMinerFee + fees.totalServiceFees
        guard var sel = try engine.call("selectFunding", ["utxos": try utxosJson(all), "requiredSat": required]) as? [[String: Any]] else {
            throw WalletEngine.EngineError.callFailed("Insufficient balance for fee + service fee.")
        }
        // fetch the REAL locking script of every funding input
        for i in sel.indices {
            if let txid = sel[i]["txid"] as? String, let vout = sel[i]["vout"] as? Int,
               let hex = try? await Api.txHex(txid),
               let real = try? engine.string("outputScriptHex", ["rawTxHex": hex, "vout": vout]) {
                sel[i]["realScriptHex"] = real
            }
        }
        let r = try engine.dict("buildOrdinalTransfer", [
            "wif": wif, "ordTxid": holding.currentTxid, "ordVout": holding.currentVout,
            "ordScriptHex": ordScriptHex, "funding": try utxosJson(sel), "to": to
        ])
        guard let rawtx = r["rawtx"] as? String else { throw WalletEngine.EngineError.badResponse }
        return try await broadcastAndRegister(rawtx: rawtx)
    }

    /// owning address of an ordinal's locking script — up-front ownership check
    func ordinalOwner(_ holding: Holding) async -> String? {
        guard let hex = try? await Api.txHex(holding.currentTxid),
              let script = try? engine.string("outputScriptHex", ["rawTxHex": hex, "vout": holding.currentVout]) else { return nil }
        return (try? engine.call("scriptLockAddress", ["scriptHex": script])) as? String
    }

    // MARK: - marketplace: list / delist (with the extension's trust-but-verify)

    private func listingPartial(_ h: Holding, priceSat: Int) async throws -> (partialTx: String, payScriptHex: String) {
        let ordHex = try await Api.txHex(h.currentTxid)
        let ordScriptHex = try engine.string("outputScriptHex", ["rawTxHex": ordHex, "vout": h.currentVout])
        let r = try engine.dict("buildListingPartial", [
            "wif": wif, "ordTxid": h.currentTxid, "ordVout": h.currentVout,
            "ordScriptHex": ordScriptHex, "priceSat": priceSat
        ])
        guard let p = r["partialTx"] as? String, let s = r["payScriptHex"] as? String else {
            throw WalletEngine.EngineError.badResponse
        }
        return (p, s)
    }

    func delistRequest(_ h: Holding) async throws {
        guard let district = h.district else { throw WalletEngine.EngineError.callFailed("Not a BSVmap.") }
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let msg = try engine.string("delistMessage", ["district": district, "ordinalTxid": h.currentTxid, "ordinalVout": h.currentVout, "ts": ts])
        let sig = try engine.signMessage(wif: wif, message: msg)
        try await Api.postDelist(district: district, body: [
            "sellerAddress": address, "district": district,
            "ordinalTxid": h.currentTxid, "ordinalVout": h.currentVout,
            "timestamp": ts, "message": msg, "signature": sig.signature, "pubkey": sig.pubkey
        ])
    }

    /// list one item incl. SELF-HEAL for stuck server state (stale per-district listing)
    func listRequest(_ h: Holding, priceSat: Int) async throws {
        guard let district = h.district else { throw WalletEngine.EngineError.callFailed("Marketplace listing is currently for BSVmaps. SNS listings coming soon.") }
        if let st = await Api.districtState(district), st["listing"] != nil, !(st["listing"] is NSNull) {
            try? await delistRequest(h)   // best effort — proceed to list
        }
        let signed = try await listingPartial(h, priceSat: priceSat)
        try await Api.postList(district: district, body: [
            "sellerAddress": address, "priceSat": priceSat,
            "ordinalTxid": h.currentTxid, "ordinalVout": h.currentVout,
            "partialTx": signed.partialTx, "payScriptHex": signed.payScriptHex
        ])
    }

    /// districts of THIS address present in the global registry — nil if unreachable
    private func registryDistricts() async -> Set<String>? {
        let ls = await Api.listings()
        guard !ls.isEmpty || indexerOk else { return nil }
        var set = Set<String>()
        for l in ls where (l["sellerAddress"] as? String) == address {
            if let d = l["district"] { set.insert(String(describing: d)) }
        }
        return set
    }

    /// which of these items are STILL listed in EITHER server store? -> [(item, where)]
    func verifyStillListed(_ items: [Holding]) async -> [(Holding, String)] {
        let reg = await registryDistricts()
        var out: [(Holding, String)] = []
        for (i, it) in items.enumerated() {
            guard let district = it.district else { continue }
            if i > 0 { try? await Task.sleep(nanoseconds: 120_000_000) } // be gentle on the API
            let st = await Api.districtState(district)
            let inDistrict = (st?["listing"] != nil) && !(st?["listing"] is NSNull)
            let inRegistry = reg?.contains(String(district)) ?? false
            if inDistrict || inRegistry {
                let whereStr = inDistrict && inRegistry ? "global registry + district record"
                    : inDistrict ? "per-district record (district page still shows it for sale)"
                    : "global registry"
                out.append((it, whereStr))
            }
        }
        return out
    }

    /// trust-but-verify for LIST: which freshly-listed items did NOT reach the registry?
    func verifyListedInRegistry(_ items: [Holding]) async -> [Holding] {
        guard let reg = await registryDistricts() else { return [] }
        return items.filter { it in
            guard let d = it.district else { return false }
            return !reg.contains(String(d))
        }
    }

    // MARK: - atomic swap purchase (dApp buyOrdinal)

    func buyOrdinal(partialTx: String, priceSat: Int, sellerAddress: String, payScriptHex: String) async throws -> String {
        let fees = try engine.fees()
        let need = priceSat + 1 + fees.ordinalMinerFee + fees.totalServiceFees
        let all = try await utxos()
        guard var sel = try engine.call("selectFunding", ["utxos": try utxosJson(all), "requiredSat": need]) as? [[String: Any]] else {
            throw WalletEngine.EngineError.callFailed("Insufficient balance for price + fee + service fee.")
        }
        for i in sel.indices {
            if let txid = sel[i]["txid"] as? String, let vout = sel[i]["vout"] as? Int,
               let hex = try? await Api.txHex(txid),
               let real = try? engine.string("outputScriptHex", ["rawTxHex": hex, "vout": vout]) {
                sel[i]["realScriptHex"] = real
            }
        }
        let r = try engine.dict("buildPurchaseFromPartial", [
            "wif": wif, "partialHex": partialTx, "priceSat": priceSat,
            "sellerAddress": sellerAddress, "payScriptHex": payScriptHex, "funding": try utxosJson(sel)
        ])
        guard let rawtx = r["rawtx"] as? String else { throw WalletEngine.EngineError.badResponse }
        return try await broadcastAndRegister(rawtx: rawtx)
    }

    // MARK: - .web3 domain registry (signed wallet actions — key = ownership)

    func signedRegistryPost(_ pathname: String, action: String, fields: [String], body: [String: Any]) async throws {
        guard !address.isEmpty, !wif.isEmpty else { throw WalletEngine.EngineError.callFailed("Unlock your wallet first.") }
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let auth = try engine.dict("signAction", ["wif": wif, "address": address, "action": action, "fields": fields, "ts": ts])
        _ = try await Api.walletPost(pathname, body: body, auth: auth)
    }

    /// v2.5.2 FIX — root-domain set-target returned `invalid_domain` while the
    /// subdomain/route handlers accepted the exact same domain string. This is
    /// the ONE registry write that never went through signedRegistryPost(): it
    /// was hand-rolled in the v1 era (names.ordnet.io) and kept its old JSON
    /// shape when everything else moved to the v2 platform (v1.10.0). The v2
    /// /wallet/set-target handler identifies the domain by the platform's
    /// canonical `name` field (exactly like /whois and /resolve?name=), so the
    /// body's `domain` key fell through as an empty name → `invalid_domain`,
    /// regardless of how valid the domain was. We now send `name` (and keep
    /// `domain` for compatibility with any older handler that reads it).
    /// The signed message is unchanged — its format was already correct.
    func setDomainTarget(domain: String, txid: String, vout: Int) async throws {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let msg = ["ordnet-registry", "set-target", domain, txid, String(vout), String(ts)].joined(separator: "|")
        let sig = try engine.signMessage(wif: wif, message: msg)
        let (code, data) = try await Api.postJSON(Api.namesBase + "/wallet/set-target", body: [
            "name": domain, "domain": domain, "txid": txid, "vout": vout, "ts": ts,
            "address": address, "signature": sig.signature, "pubkey": sig.pubkey
        ])
        let j = Api.json(data) ?? [:]
        if code != 200 || j["error"] != nil {
            let e = j["error"] as? String ?? "HTTP \(code)"
            throw Api.ApiError.http(code, e == "invalid_signature" ? "Signature rejected — is this domain owned by the active wallet?" : "Could not save: \(e)")
        }
    }

    // MARK: - inscription log (Upload tab: everything inscribed via this app)

    @Published var inscriptions: [InscriptionRecord] = []
    static let inscriptionsKey = "ordnet_inscriptions_v1"
    private var allInscriptions: [String: [InscriptionRecord]] = [:]   // per address

    func loadInscriptions() {
        if let data = UserDefaults.standard.data(forKey: Self.inscriptionsKey),
           let dict = try? JSONDecoder().decode([String: [InscriptionRecord]].self, from: data) {
            allInscriptions = dict
        }
        inscriptions = allInscriptions[address] ?? []
    }

    /// v2.3 — ORD/ner reads the log of ANY account (folders per account)
    func inscriptionLog(for addr: String) -> [InscriptionRecord] {
        if let data = UserDefaults.standard.data(forKey: Self.inscriptionsKey),
           let dict = try? JSONDecoder().decode([String: [InscriptionRecord]].self, from: data) {
            return dict[addr] ?? []
        }
        return []
    }

    func recordInscription(txid: String, contentType: String, filename: String, bytes: Int) {
        let rec = InscriptionRecord(txid: txid, contentType: contentType, filename: filename,
                                    bytes: bytes, ts: Date().timeIntervalSince1970 * 1000)
        var list = allInscriptions[address] ?? []
        list.insert(rec, at: 0)   // newest first
        allInscriptions[address] = list
        inscriptions = list
        if let data = try? JSONEncoder().encode(allInscriptions) {
            UserDefaults.standard.set(data, forKey: Self.inscriptionsKey)
        }
    }

    // MARK: - address book

    func loadAddressBook() {
        if let data = UserDefaults.standard.data(forKey: Self.addressBookKey),
           let book = try? JSONDecoder().decode([BookEntry].self, from: data) {
            addressBook = book
        }
    }
    private func saveAddressBook() {
        if let data = try? JSONEncoder().encode(addressBook) {
            UserDefaults.standard.set(data, forKey: Self.addressBookKey)
        }
    }
    func bookLabel(for addr: String) -> String? {
        addressBook.first { $0.address == addr }?.name
    }
    func bookAdd(name: String, address addr: String) throws {
        guard engine.validateAddress(addr) else {
            throw WalletEngine.EngineError.callFailed("That is not a valid BSV address.")
        }
        let nm = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Saved \(addressBook.count + 1)" : name.trimmingCharacters(in: .whitespaces)
        if let i = addressBook.firstIndex(where: { $0.address == addr }) {
            addressBook[i].name = nm
        } else {
            addressBook.append(BookEntry(name: nm, address: addr, ts: Date().timeIntervalSince1970 * 1000))
        }
        saveAddressBook()
    }
    func bookRemove(address addr: String) {
        addressBook.removeAll { $0.address == addr }
        saveAddressBook()
    }

    // MARK: - connected sites

    func connectSite(_ origin: String) { connectedSites[origin] = true }
    func disconnectSite(_ origin: String) { connectedSites.removeValue(forKey: origin) }
    func isConnected(_ origin: String) -> Bool { connectedSites[origin] == true }
}
