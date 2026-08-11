import SwiftUI

/// Send BSV — port of the extension's send view, including the safety layer:
/// first-time-address warning, near-full-balance warning, self-send detection,
/// clipboard paste verification and send-max.
struct SendView: View {
    @EnvironmentObject private var store: WalletStore

    @State private var to = ""
    @State private var amount = ""
    @State private var error = ""
    @State private var success = ""
    @State private var warnings: [String] = []
    @State private var busy = false
    @State private var showScanner = false
    @State private var lastSentAddr: String?
    @State private var showSaveToBook = false
    @State private var fees: Fees?
    /// v2.1 — verified OpNS payment target (two-tap confirm: first Send tap
    /// resolves + verifies, second tap re-verifies and pays)
    @State private var opnsTarget: OpnsPayTarget?
    /// v2.2 — verified SNS payment target (same two-tap pattern; signed
    /// resolver answers, level "prove")
    @State private var snsTarget: SnsPayTarget?

    /// amount is entered in BSV (like the extension's listing price) and
    /// converted to sats internally
    private var amountSats: Int {
        let v = Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0
        return v > 0 ? Int((v * 1e8).rounded()) : 0
    }

    var body: some View {
        Form {
            Section("From") {
                Text("\(store.activeAccount?.name ?? "Account") · \(Fmt.shortAddress(store.address))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Recipient") {
                HStack {
                    TextField("BSV address, SNS or OpNS name", text: $to)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: to) {
                            opnsTarget = nil   // input changed → stale confirmations die
                            snsTarget = nil
                            evaluateSafety()
                        }
                    Button { pasteVerified() } label: { Image(systemName: "doc.on.clipboard") }
                        .buttonStyle(.borderless)
                    Button { showScanner = true } label: { Image(systemName: "qrcode.viewfinder") }
                        .buttonStyle(.borderless)
                }
                if !store.addressBook.isEmpty {
                    Picker("Address book", selection: Binding(
                        get: { "" },
                        set: { v in if !v.isEmpty { to = v; evaluateSafety() } }
                    )) {
                        Text("— pick from address book —").tag("")
                        ForEach(store.addressBook.sorted { $0.name < $1.name }) { e in
                            Text("\(e.name) · \(String(e.address.prefix(8)))…\(String(e.address.suffix(4)))").tag(e.address)
                        }
                    }
                }
            }

            Section("Amount") {
                HStack {
                    TextField("Amount in BSV (e.g. 0.001)", text: $amount)
                        .keyboardType(.decimalPad)
                        .onChange(of: amount) { evaluateSafety() }
                    Button("Max") { sendMax() }
                        .buttonStyle(.borderless)
                }
                if amountSats >= 1 {
                    Text("= \(Fmt.sats(amountSats)) sats")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let f = fees {
                    Text("Fee: ~\(Fmt.bsv(f.sendMinerFee)) BSV network + \(Fmt.bsv(f.totalServiceFees)) BSV service")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !warnings.isEmpty {
                Section {
                    InlineAlert(kind: .warning, text: warnings.joined(separator: "\n"))
                }
            }

            // v2.2 — SNS confirmation: signed answer verified against the
            // pinned resolver key; the pay-to address comes from the SIGNED
            // holder_script, never from the unsigned holder_address field
            if let t = snsTarget {
                Section("Confirm SNS payment") {
                    KVRow(k: "Name", v: t.name)
                    if !t.mailbox.isEmpty {
                        KVRow(k: "Mailbox", v: "\(t.mailbox)@\(t.name)")
                    }
                    KVRow(k: "Holder address", v: t.holderAddress, mono: true)
                    KVRow(k: "Inscription UTXO", v: "\(String(t.currentTxid.prefix(10)))…\(String(t.currentTxid.suffix(6)))_\(t.currentVout)", mono: true)
                    if t.fallback {
                        InlineAlert(kind: .warning, text: "Mailbox \"\(t.mailbox)\" is unknown — the payment goes to the holder of \(t.name).")
                    }
                    if !t.warning.isEmpty {
                        InlineAlert(kind: .warning, text: t.warning)
                    }
                    Text("Signed resolver answer verified against the pinned key; the inscription outpoint was checked unspent. Everything is re-verified the moment you confirm.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // v2.1 — OpNS confirmation: ALWAYS the exact name + the verified
            // holder address, inline, before anything is paid (intermediate
            // names like "alexande" vs "alexander" can have different owners)
            if let t = opnsTarget {
                Section("Confirm OpNS payment") {
                    KVRow(k: "Exact name", v: t.name)
                    KVRow(k: "Holder address", v: t.holderAddress, mono: true)
                    KVRow(k: "Ordinal UTXO", v: "\(String(t.currentTxid.prefix(10)))…\(String(t.currentTxid.suffix(6)))_\(t.currentVout)", mono: true)
                    Text("Verified on-chain: the holder address was recomputed from the current outpoint's locking script and the outpoint checked unspent. It is re-verified again the moment you confirm.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                InlineAlert(kind: .error, text: error)
                InlineAlert(kind: .success, text: success)
                if showSaveToBook, let addr = lastSentAddr {
                    NavigationLink {
                        AddressBookView(prefillAddress: addr)
                    } label: {
                        Label("Save \(String(addr.prefix(8)))… to address book", systemImage: "book")
                            .font(.footnote)
                    }
                }
                Button {
                    send()
                } label: {
                    if busy { ProgressView().frame(maxWidth: .infinity) }
                    else { Text(confirmButtonLabel).frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
        }
        .ordnetBackground()
        .keyboardDismissBar()   // v2.5.1: decimalPad had no way out
        .navigationTitle("Send BSV")
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { code in
                to = code
                evaluateSafety()
            }
        }
        .task {
            fees = try? store.engine.fees()
            await store.refreshBalance()
        }
    }

    // MARK: name recognition (v2.1 OpNS, v2.2 SNS)

    private var confirmButtonLabel: String {
        if let t = snsTarget { return "Confirm & pay \"\(t.mailbox.isEmpty ? t.name : "\(t.mailbox)@\(t.name)")\"" }
        if let t = opnsTarget { return "Confirm & pay \"\(t.name)\"" }
        return "Send"
    }

    /// bare OpNS name candidate: a-z, 0-9, hyphen — and NO dot (a dotted name
    /// is SNS, never OpNS) and no @ (paymail is not a payment target here)
    private func opnsNameCandidate(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty, !t.contains("."), !t.contains("@"),
              t.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil,
              !store.engine.validateAddress(t) else { return nil }
        return t
    }

    /// SNS candidate: `naam.tld` or `mailbox@naam.tld` — a dot in the domain
    /// part is what separates SNS from OpNS. ASCII lowercase only by
    /// construction, so homograph/mixed-script inputs never reach the
    /// resolver from here. The TLD list is NOT hardcoded: the resolver itself
    /// answers unknown_tld/retired_tld with a readable inline message.
    private func snsInputCandidate(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.range(of: "^(?:[a-z0-9][a-z0-9._-]{0,63}@)?(?:[a-z0-9][a-z0-9-]{0,62}\\.)+[a-z][a-z0-9-]{1,24}$",
                      options: .regularExpression) != nil else { return nil }
        return t
    }

    // MARK: safety — port of evaluateSendSafety()

    private func evaluateSafety() {
        var notes: [String] = []
        let addr = to.trimmingCharacters(in: .whitespaces)
        if !addr.isEmpty, !store.engine.validateAddress(addr) {
            if snsInputCandidate(addr) != nil {
                notes.append("This looks like an SNS name\(addr.contains("@") ? " mailbox" : ""). Press Send to resolve it via the signed SNS resolver — you confirm the verified holder address before anything is paid.")
            } else if opnsNameCandidate(addr) != nil {
                notes.append("This looks like a bare OpNS name (no dot = not SNS). Press Send to resolve it — exact match only, and you confirm the verified holder address before anything is paid.")
            }
        }
        if !addr.isEmpty, store.engine.validateAddress(addr) {
            if addr == store.address {
                notes.append("This is your own active address — the coins will not leave this wallet.")
            } else if store.bookLabel(for: addr) == nil && !store.accounts.contains(where: { $0.address == addr }) {
                notes.append("First time sending to this address. Double-check it character by character — BSV transfers cannot be reversed.")
            } else if let lbl = store.bookLabel(for: addr) {
                notes.append("Recipient: \"\(lbl)\" from your address book.")
            }
        }
        if amountSats > 0, let bal = store.balance, let f = fees {
            let spendable = bal.confirmed - (f.sendMinerFee + f.totalServiceFees)
            if amountSats >= spendable && spendable > 0 {
                notes.append("This sends essentially your entire spendable balance.")
            }
        }
        warnings = notes
    }

    /// clipboard paste with verification — defends against clipboard-hijack malware
    private func pasteVerified() {
        error = ""
        guard let txt = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !txt.isEmpty else {
            error = "Clipboard is empty."
            return
        }
        guard store.engine.validateAddress(txt) else {
            error = "Clipboard does not contain a valid BSV address."
            return
        }
        to = txt
        evaluateSafety()
    }

    private func sendMax() {
        error = ""
        Task {
            await store.refreshBalance()
            guard let bal = store.balance, let f = fees else {
                error = "Could not read balance for max."
                return
            }
            let spendable = bal.confirmed // only confirmed sats are safely spendable
            let max = spendable - (f.sendMinerFee + f.totalServiceFees)
            if max < 1 {
                error = "Balance too low to cover the network + service fee."
                amount = ""
            } else {
                amount = Fmt.bsv(max)
                evaluateSafety()
            }
        }
    }

    private func send() {
        error = ""; success = ""
        let addr = to.trimmingCharacters(in: .whitespaces)
        guard !addr.isEmpty else { error = "Enter a recipient address."; return }

        // plain BSV address — the original path, unchanged
        if store.engine.validateAddress(addr) {
            opnsTarget = nil
            snsTarget = nil
            let amt = amountSats
            guard amt >= 1 else { error = "Enter an amount in BSV (minimum 0.00000001)."; return }
            busy = true
            Task {
                await performSend(to: addr, amountSat: amt)
                busy = false
            }
            return
        }

        // v2.2 — SNS name or mailbox (naam.tld / mailbox@naam.tld): resolve
        // via the SIGNED resolver, two-tap confirm, re-verified at signing.
        // The freshness/expires checks live in resolveSnsPayment.
        if let snsInput = snsInputCandidate(addr) {
            let amt = amountSats
            guard amt >= 1 else { error = "Enter an amount in BSV (minimum 0.00000001)."; return }
            busy = true
            Task {
                do {
                    let target = try await store.resolveSnsPayment(input: snsInput)
                    if let seen = snsTarget, seen == target {
                        await performSend(to: target.holderAddress, amountSat: amt)
                        snsTarget = nil
                    } else if let seen = snsTarget,
                              seen.name == target.name, seen.holderAddress == target.holderAddress {
                        // same verified holder, only freshness fields moved
                        // (expires/outpoint re-issued) — safe to pay
                        await performSend(to: target.holderAddress, amountSat: amt)
                        snsTarget = nil
                    } else if snsTarget != nil {
                        snsTarget = target
                        error = "The verified details of \(target.name) changed while you were confirming — review them and press the button again. Nothing was paid."
                    } else {
                        snsTarget = target
                    }
                } catch {
                    snsTarget = nil
                    self.error = error.localizedDescription
                }
                busy = false
            }
            return
        }

        // v2.1 — not an address, not SNS: OpNS name or paymail?
        if addr.contains("@") {
            error = "Paymail (name@host) is not accepted as a payment target: any host can serve any name and bindings expire on transfer. Enter the bare OpNS name, an SNS mailbox (mailbox@naam.tld) or a BSV address."
            return
        }
        guard let name = opnsNameCandidate(addr) else {
            error = "That is not a valid BSV address."
            return
        }
        let amt = amountSats
        guard amt >= 1 else { error = "Enter an amount in BSV (minimum 0.00000001)."; return }

        // two-tap confirm; the resolve (exact match + on-chain recompute +
        // unspent outpoint) runs on EVERY tap, so the confirm tap re-verifies
        // right before broadcasting — never a cached address
        busy = true
        Task {
            do {
                let target = try await store.resolveOpnsPayment(name: name)
                if let seen = opnsTarget, seen == target {
                    await performSend(to: target.holderAddress, amountSat: amt)
                    opnsTarget = nil
                } else if let seen = opnsTarget, seen != target {
                    opnsTarget = target
                    error = "The verified details of \"\(target.name)\" changed while you were confirming — review them and press the button again. Nothing was paid."
                } else {
                    opnsTarget = target
                }
            } catch {
                opnsTarget = nil
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    /// the actual broadcast + aftercare — shared by the address path and the
    /// verified OpNS path
    private func performSend(to addr: String, amountSat amt: Int) async {
        do {
            let txid = try await store.sendBSV(to: addr, amountSat: amt)
            success = "Sent! TXID: \(txid)"
            lastSentAddr = addr
            if store.bookLabel(for: addr) == nil && !store.accounts.contains(where: { $0.address == addr }) {
                showSaveToBook = true
            }
            to = ""; amount = ""; warnings = []
            await store.refreshBalance()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Receive

struct ReceiveView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var copied = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("\(store.activeAccount?.name ?? "Account") · BSV mainnet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                QRCodeView(text: store.address)
                    .frame(maxWidth: 260)
                Text(store.address)
                    .font(.callout.monospaced())
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal)
                InlineAlert(kind: .success, text: copied)
                HStack {
                    Button {
                        UIPasteboard.general.string = store.address
                        copied = "Address copied to clipboard."
                    } label: {
                        Label("Copy address", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    ShareLink(item: store.address) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.ordnetOutline)
                }
                Text("Only send BSV or 1Sat Ordinals to this address.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .ordnetBackground()
        .navigationTitle("Receive")
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var txs: [HistoryTx] = []
    @State private var error = ""
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if !error.isEmpty {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            } else if txs.isEmpty {
                Text("No transactions on this address yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(txs.prefix(50)) { t in
                    Link(destination: URL(string: "https://whatsonchain.com/tx/\(t.txHash)")!) {
                        HStack {
                            Image(systemName: "arrow.left.arrow.right")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Fmt.shortTxid(t.txHash)).font(.callout.monospaced())
                                Text(t.isPending ? "pending (mempool)" : "block \(t.height)")
                                    .font(.caption2)
                                    .foregroundStyle(t.isPending ? Theme.statusYellow : .secondary)
                            }
                        }
                    }
                }
            }
        }
        .ordnetBackground()
        .navigationTitle(Fmt.shortAddress(store.address))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                txs = try await Api.history(address: store.address)
            } catch {
                self.error = "Could not load history from WhatsOnChain."
            }
            loading = false
        }
    }
}
