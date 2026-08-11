import Foundation

/// BRC-100 provider — native side (v2.4, FASE 1 only).
///
/// The wallet is the BRC-100 *provider* (substrate); apps in the WKWebView are
/// clients. The page only ever sees the key-free shim (brc100-shim.js); this
/// type decides what each method does. Phase 1 is purely informative — no
/// keys, no money. Everything else fails EXPLICITLY with a standards-shaped
/// WalletError (name WERR_*, code, message) that the shim turns into a
/// promise REJECTION — an app must never mistake a refusal for success.
///
/// Phasing (per the BRC-100 briefing):
///   fase 1 (now): getVersion, getNetwork, getHeight, isAuthenticated,
///                 waitForAuthentication  (getHeaderForHeight: explicit error
///                 until a header-by-height endpoint is verified)
///   fase 2: keys/crypto via the bundled @bsv/sdk ProtoWallet, behind native
///           permission sheets (per app, per protocol — BRC-43 grants)
///   fase 3: money (createAction c.s.) — evaluate @bsv/wallet-toolbox first
///   fase 4: certificates + the two privacy-sensitive linkage methods
enum Brc100 {

    /// standards-shaped error (mirrors @bsv/sdk WalletError semantics)
    struct Err: Error {
        let name: String
        let code: Int
        let message: String
    }

    static let versionString = "ordplug-1.0.0"

    /// fase 2 (v2.5): keys & crypto — permission-gated, executed by the
    /// bundled @bsv/sdk ProtoWallet inside the JSC engine (keys never leave it)
    static let phase2Methods: Set<String> = [
        "getPublicKey", "encrypt", "decrypt",
        "createSignature", "verifySignature", "createHmac", "verifyHmac"
    ]

    @MainActor
    static func handle(method: String, argsJson: String, originator: String, store: WalletStore?) async throws -> [String: Any] {
        switch method {

        // ---- fase 1: informative, no keys, no money ----
        case "getVersion":
            return ["version": versionString]
        case "getNetwork":
            return ["network": "mainnet"]
        case "getHeight":
            do {
                return ["height": try await Api.chainHeight()]
            } catch {
                throw Err(name: "WERR_UNKNOWN", code: 1,
                          message: "Could not read the chain height right now: \(error.localizedDescription)")
            }
        case "isAuthenticated", "waitForAuthentication":
            // the in-app browser is only reachable while the wallet is unlocked
            return ["authenticated": true]

        // ---- fase 2 (v2.5): keys & crypto via ProtoWallet, behind grants ----
        case _ where phase2Methods.contains(method):
            guard let store, !store.wif.isEmpty else {
                throw Err(name: "WERR_UNKNOWN", code: 1, message: "The wallet is locked.")
            }
            let args = (try? JSONSerialization.jsonObject(with: Data(argsJson.utf8))) as? [String: Any] ?? [:]
            // BRC-43 grants: level 0 open; level 1 per app+protocol; level 2
            // + counterparty; identity key has its own per-app grant. Native
            // Face ID sheet on first use, persistent afterwards.
            try await store.requireBrc100Permission(origin: originator, method: method, args: args)
            return try await store.engine.callBrc100(method: method, argsJson: argsJson, wif: store.wif)

        // ---- fase 3 (v2.6): geld — per-transactie Face ID, geld ≠ grant ----
        case "createAction":
            return try await createAction(argsJson: argsJson, originator: originator, store: store)
        case "internalizeAction":
            return try await internalizeAction(argsJson: argsJson, originator: originator, store: store)
        case "listActions":
            return try listActions(argsJson: argsJson, store: store)
        case "listOutputs":
            return try await listOutputs(argsJson: argsJson, store: store)
        case "relinquishOutput":
            return try await relinquishOutput(argsJson: argsJson, store: store)
        case "signAction":
            // regel 1: het signableTransaction-pad bestaat pas als het er ECHT is
            throw Err(name: "WERR_UNSUPPORTED_ACTION", code: 2,
                      message: "signAction is not supported yet: this wallet only processes outputs-only createAction calls (no signableTransaction path).")
        case "abortAction":
            // zonder signableTransaction-pad is er nooit een af te breken actie
            throw Err(name: "WERR_INVALID_PARAMETER", code: 3,
                      message: "abortAction: no abortable action exists for this reference — this wallet fully processes actions at createAction time.")

        // ---- privacy-sensitive: explicitly unsupported (feedback point 2) ----
        case "revealCounterpartyKeyLinkage", "revealSpecificKeyLinkage":
            throw Err(name: "WERR_UNSUPPORTED_ACTION", code: 2,
                      message: "\(method) is privacy-sensitive and not supported by the ORDnet wallet.")

        // ---- everything else: explicit, standards-shaped refusal (rule 4) ----
        default:
            throw Err(name: "WERR_UNSUPPORTED_ACTION", code: 2,
                      message: "\(method) is not yet supported by the ORDnet wallet. Supported today: fase 1 (getVersion, getNetwork, getHeight, isAuthenticated, waitForAuthentication), fase 2 (getPublicKey, encrypt, decrypt, createSignature, verifySignature, createHmac, verifyHmac) and fase 3 (createAction, internalizeAction, listActions, listOutputs, relinquishOutput).")
        }
    }

    // MARK: - fase 3 helpers (v2.6)

    /// engine-validatieresultaten dragen {valid:false, werr:{…}} — vertaal dat
    /// 1-op-1 naar het BRC-100-foutcontract (promise-REJECTION in de pagina)
    private static func requireValid(_ r: [String: Any]) throws -> [String: Any] {
        if (r["valid"] as? Bool) == true { return r }
        let w = r["werr"] as? [String: Any]
        throw Err(name: w?["name"] as? String ?? "WERR_INVALID_PARAMETER",
                  code: w?["code"] as? Int ?? 3,
                  message: w?["message"] as? String ?? "Invalid parameters.")
    }

    @MainActor
    private static func unlockedStore(_ store: WalletStore?) throws -> WalletStore {
        guard let store, !store.wif.isEmpty else {
            throw Err(name: "WERR_UNKNOWN", code: 1, message: "The wallet is locked.")
        }
        return store
    }

    /// outputs-only createAction: valideren → native Face ID-sheet (bedrag +
    /// bestemming, elke transactie opnieuw) → bouwen via het bestaande
    /// buildTx-pad (ordinal-bescherming, service fees, change) → broadcast
    /// via broadcastAndRegister (chain tips + spent-guard) → actielog
    @MainActor
    private static func createAction(argsJson: String, originator: String, store: WalletStore?) async throws -> [String: Any] {
        let store = try unlockedStore(store)
        let v = try requireValid(try store.engine.dict("brc100ValidateCreate", ["argsJson": argsJson]))

        let outs = v["outputs"] as? [[String: Any]] ?? []
        let lines = outs.map { o in
            Brc100TxLine(dest: (o["dest"] as? String) ?? "script output (not an address)",
                         sats: (o["satoshis"] as? Int) ?? 0,
                         note: (o["outputDescription"] as? String) ?? "")
        }
        try await store.requireBrc100TxConfirm(
            origin: originator,
            title: "Approve payment",
            description: (v["description"] as? String) ?? "",
            lines: lines,
            minerFeeEstimate: (v["minerFeeEstimate"] as? Int) ?? 0,
            serviceFees: (v["serviceFees"] as? Int) ?? 0,
            totalSat: (v["totalSat"] as? Int) ?? 0,
            incoming: false)

        let utxos = try await store.utxos()
        let utxosJson = String(data: try JSONSerialization.data(withJSONObject: utxos), encoding: .utf8) ?? "[]"
        let built: [String: Any]
        do {
            built = try store.engine.dict("brc100BuildCreate",
                ["wif": store.wif, "utxos": utxosJson, "argsJson": argsJson])
        } catch {
            throw Err(name: "WERR_INSUFFICIENT_FUNDS", code: 5, message: error.localizedDescription)
        }
        guard let rawtx = built["rawtx"] as? String else {
            throw Err(name: "WERR_UNKNOWN", code: 1, message: "The engine returned an unreadable transaction.")
        }
        let txid: String
        do {
            txid = try await store.broadcastAndRegister(rawtx: rawtx)
        } catch {
            throw Err(name: "WERR_UNKNOWN", code: 1,
                      message: "Broadcast failed: \(error.localizedDescription)")
        }
        store.brc100LogAction(Brc100ActionRecord(
            txid: txid,
            description: (v["description"] as? String) ?? "",
            labels: (v["labels"] as? [String]) ?? [],
            satoshis: (v["totalSat"] as? Int) ?? 0,
            origin: originator,
            ts: Date().timeIntervalSince1970 * 1000,
            status: "completed",
            isOutgoing: true))
        return ["txid": txid]   // CreateActionResult: tx (BEEF) volgt in een latere fase
    }

    /// internalizeAction: AtomicBEEF met 'wallet payment'-outputs aan het
    /// wallet-adres — geverifieerd in de engine, bevestigd met Face ID,
    /// daarna (indien nodig) gebroadcast; al-bekende transacties tellen als
    /// geaccepteerd (de betaling bestaat dan al on-chain)
    @MainActor
    private static func internalizeAction(argsJson: String, originator: String, store: WalletStore?) async throws -> [String: Any] {
        let store = try unlockedStore(store)
        let v = try requireValid(try store.engine.dict("brc100ParseInternalize",
            ["argsJson": argsJson, "address": store.address]))
        let outs = v["outputs"] as? [[String: Any]] ?? []
        let lines = outs.map { o in
            Brc100TxLine(dest: Fmt.shortAddress(store.address) + " (this wallet)",
                         sats: (o["satoshis"] as? Int) ?? 0,
                         note: "incoming payment output \((o["vout"] as? Int) ?? 0)")
        }
        let desc = ((try? JSONSerialization.jsonObject(with: Data(argsJson.utf8))) as? [String: Any])?["description"] as? String ?? ""
        try await store.requireBrc100TxConfirm(
            origin: originator,
            title: "Accept incoming payment",
            description: desc,
            lines: lines,
            minerFeeEstimate: 0, serviceFees: 0,
            totalSat: (v["totalSat"] as? Int) ?? 0,
            incoming: true)

        guard let rawtx = v["rawtx"] as? String, let txid = v["txid"] as? String else {
            throw Err(name: "WERR_UNKNOWN", code: 1, message: "The engine returned an unreadable transaction.")
        }
        do {
            _ = try await store.broadcastAndRegister(rawtx: rawtx)
        } catch {
            // een al-bekende transactie is GEEN fout: de betaling staat al on-chain
            let m = error.localizedDescription.lowercased()
            guard m.contains("already") || m.contains("txn-mempool-conflict") || m.contains("257") else {
                throw Err(name: "WERR_UNKNOWN", code: 1,
                          message: "Broadcast failed: \(error.localizedDescription)")
            }
        }
        store.brc100LogAction(Brc100ActionRecord(
            txid: txid, description: desc, labels: [],
            satoshis: (v["totalSat"] as? Int) ?? 0,
            origin: originator,
            ts: Date().timeIntervalSince1970 * 1000,
            status: "completed", isOutgoing: false))
        return ["accepted": true]
    }

    /// listActions uit het lokale actielog (alleen acties via deze app —
    /// gedocumenteerde, eerlijke scope; filters conform BRC-100 any/all)
    @MainActor
    private static func listActions(argsJson: String, store: WalletStore?) throws -> [String: Any] {
        let store = try unlockedStore(store)
        let args = (try? JSONSerialization.jsonObject(with: Data(argsJson.utf8))) as? [String: Any] ?? [:]
        var actions = store.brc100Actions()
        if let labels = args["labels"] as? [String], !labels.isEmpty {
            let wanted = Set(labels.map { $0.lowercased() })
            let mode = (args["labelQueryMode"] as? String) ?? "any"
            guard mode == "any" || mode == "all" else {
                throw Err(name: "WERR_INVALID_PARAMETER", code: 3,
                          message: "listActions: labelQueryMode must be \"any\" or \"all\".")
            }
            actions = actions.filter { rec in
                let have = Set(rec.labels)
                return mode == "all" ? wanted.isSubset(of: have) : !wanted.isDisjoint(with: have)
            }
        }
        let limit = min(max((args["limit"] as? Int) ?? 10, 1), 10000)
        let offset = max((args["offset"] as? Int) ?? 0, 0)
        let page = actions.dropFirst(offset).prefix(limit)
        return [
            "totalActions": actions.count,
            "actions": page.map { rec in [
                "txid": rec.txid,
                "satoshis": rec.satoshis,
                "status": rec.status,
                "isOutgoing": rec.isOutgoing,
                "description": rec.description,
                "labels": rec.labels,
                "version": 1,
                "lockTime": 0
            ] as [String: Any] }
        ]
    }

    /// listOutputs over de live, ordinal-beschermde UTXO-set ('default'
    /// basket) — vreemde baskets/tags weigeren expliciet in de engine
    @MainActor
    private static func listOutputs(argsJson: String, store: WalletStore?) async throws -> [String: Any] {
        let store = try unlockedStore(store)
        let utxos = try await store.utxos()
        let utxosJson = String(data: try JSONSerialization.data(withJSONObject: utxos), encoding: .utf8) ?? "[]"
        let v = try requireValid(try store.engine.dict("brc100ListOutputs",
            ["utxos": utxosJson, "argsJson": argsJson]))
        return ["totalOutputs": v["totalOutputs"] as? Int ?? 0,
                "outputs": v["outputs"] as? [[String: Any]] ?? []]
    }

    /// relinquishOutput: bestaand outpoint uit de 'default' basket loslaten —
    /// persistent uitgesloten van funding; onbekende outpoints weigeren
    @MainActor
    private static func relinquishOutput(argsJson: String, store: WalletStore?) async throws -> [String: Any] {
        let store = try unlockedStore(store)
        let args = (try? JSONSerialization.jsonObject(with: Data(argsJson.utf8))) as? [String: Any] ?? [:]
        let basket = (args["basket"] as? String) ?? "default"
        guard basket == "default" else {
            throw Err(name: "WERR_INVALID_PARAMETER", code: 3,
                      message: "relinquishOutput: basket \"\(basket)\" is not tracked by this wallet — only \"default\" exists.")
        }
        guard let outpoint = (args["output"] as? String)?.lowercased(),
              outpoint.range(of: "^[0-9a-f]{64}\\.\\d+$", options: .regularExpression) != nil else {
            throw Err(name: "WERR_INVALID_PARAMETER", code: 3,
                      message: "relinquishOutput: output must be an outpoint like \"txid.vout\".")
        }
        let utxos = try await store.utxos()
        let known = utxos.contains { "\(($0["txid"] as? String) ?? "").\(($0["vout"] as? Int) ?? -1)" == outpoint }
        guard known else {
            throw Err(name: "WERR_INVALID_PARAMETER", code: 3,
                      message: "relinquishOutput: outpoint \(outpoint) is not a spendable output of this wallet.")
        }
        store.brc100Relinquish(outpoint: outpoint)
        return ["relinquished": true]
    }
}
