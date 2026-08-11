import SwiftUI

// MARK: - Send ordinal (SNS name / BSVmap) — true 1Sat transfer

struct SendOrdinalView: View {
    @EnvironmentObject private var store: WalletStore
    let holding: Holding

    @State private var to = ""
    @State private var error = ""
    @State private var success = ""
    @State private var ownerWarning = ""
    @State private var busy = false
    @State private var showScanner = false
    @State private var fees: Fees?

    var body: some View {
        Form {
            Section("Item") {
                KVRow(k: "Name", v: holding.name)
                KVRow(k: "Type", v: holding.kindLabel)
                KVRow(k: "Ordinal UTXO", v: holding.utxoShort, mono: true)
                KVRow(k: "Status", v: holding.status)
                KVRow(k: "From wallet", v: Fmt.shortAddress(store.address), mono: true)
            }

            if !ownerWarning.isEmpty {
                Section { InlineAlert(kind: .error, text: ownerWarning) }
            }

            if holding.kind == .opns {
                // paymail bindings are signed by the CURRENT holder and die on
                // transfer — warn inline, before the send
                Section {
                    InlineAlert(kind: .warning, text: "If this OpNS name has a paymail binding (\(holding.name)@host), that binding expires when the name is transferred. The new owner must create a new binding.")
                }
            }

            Section("Recipient") {
                HStack {
                    TextField("BSV address of the new owner", text: $to)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button { showScanner = true } label: { Image(systemName: "qrcode.viewfinder") }
                        .buttonStyle(.borderless)
                }
                if let f = fees {
                    Text("Fee: ~\(Fmt.bsv(f.ordinalMinerFee)) BSV network + \(Fmt.bsv(f.totalServiceFees)) BSV service")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                InlineAlert(kind: .error, text: error)
                InlineAlert(kind: .success, text: success)
                Button {
                    send()
                } label: {
                    if busy { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("Send \(holding.shortKindLabel)").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || !ownerWarning.isEmpty)
            }
        }
        .ordnetBackground()
        .navigationTitle("Send \(holding.shortKindLabel)")
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { code in to = code }
        }
        .task {
            fees = try? store.engine.fees()
            // up-front ownership check, port of the soOwnerWarn block
            if let owner = await store.ordinalOwner(holding), owner != store.address {
                ownerWarning = "This ordinal is owned by \(owner), not your active wallet (\(store.address)). You must import the seed/key that controls \(owner) before you can send it."
            }
        }
    }

    private func send() {
        error = ""; success = ""
        let addr = to.trimmingCharacters(in: .whitespaces)
        guard !addr.isEmpty else { error = "Enter a recipient address."; return }
        guard store.engine.validateAddress(addr) else { error = "That is not a valid BSV address."; return }
        guard addr != store.address else { error = "That is your own address — the ordinal is already there."; return }
        guard holding.status != "contract" else { error = "This ordinal sits in a contract output and cannot be sent from here."; return }
        busy = true
        Task {
            do {
                let txid = try await store.sendOrdinal(holding, to: addr)
                success = "Sent! \(holding.name) is on its way. TXID: \(txid)"
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await store.loadHoldings()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - List for sale (Optie-1 atomic swap, two-step confirm)

struct ListOrdinalView: View {
    @EnvironmentObject private var store: WalletStore
    let holding: Holding

    @State private var priceBSV = ""
    @State private var confirming = false
    @State private var error = ""
    @State private var success = ""
    @State private var busy = false

    private var priceSats: Int {
        let v = Double(priceBSV.replacingOccurrences(of: ",", with: ".")) ?? 0
        return v > 0 ? Int((v * 1e8).rounded()) : 0
    }

    var body: some View {
        Form {
            Section("Item") {
                KVRow(k: "Name", v: holding.name)
                KVRow(k: "Type", v: holding.kindLabel)
                KVRow(k: "Ordinal UTXO", v: holding.utxoShort, mono: true)
            }

            if !confirming {
                Section("Price") {
                    TextField("Price in BSV (e.g. 0.0001)", text: $priceBSV)
                        .keyboardType(.decimalPad)
                    if priceSats >= 1 {
                        Text("= \(Fmt.sats(priceSats)) sats")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("You sign a one-sided atomic swap. The ordinal stays in your wallet until a buyer pays your price.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    InlineAlert(kind: .error, text: error)
                    Button("Continue") { toConfirm() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Section("Confirm — exactly this will be signed") {
                    KVRow(k: "Item", v: holding.name)
                    KVRow(k: "Price", v: "\(Fmt.bsv(priceSats)) BSV (\(Fmt.sats(priceSats)) sats)")
                    KVRow(k: "Paid to", v: Fmt.shortAddress(store.address), mono: true)
                    KVRow(k: "Ordinal", v: holding.utxoShort, mono: true)
                }
                Section {
                    InlineAlert(kind: .error, text: error)
                    InlineAlert(kind: .success, text: success)
                    if success.isEmpty {
                        Button {
                            list()
                        } label: {
                            if busy { ProgressView().frame(maxWidth: .infinity) }
                            else { Text("Confirm & sign").frame(maxWidth: .infinity) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                        Button("Back") { confirming = false }
                            .disabled(busy)
                    }
                }
            }
        }
        .ordnetBackground()
        .keyboardDismissBar()   // v2.5.1: decimalPad had no way out
        .navigationTitle("List for sale")
    }

    private func toConfirm() {
        error = ""
        guard priceSats >= 1 else { error = "Enter a price in BSV (minimum 0.00000001)."; return }
        // OpNS: no marketplace flows at all — display, resolve and send only
        guard holding.kind != .opns else { error = "OpNS names cannot be listed for sale from this wallet."; return }
        guard holding.kind == .bsvmap else { error = "Marketplace listing is currently for BSVmaps. SNS listings coming soon."; return }
        confirming = true
    }

    private func list() {
        error = ""; busy = true
        Task {
            do {
                try await store.listRequest(holding, priceSat: priceSats)
                // trust-but-verify: HTTP 200 does not guarantee the global registry got it
                let missing = await store.verifyListedInRegistry([holding])
                if !missing.isEmpty {
                    throw WalletEngine.EngineError.callFailed(
                        "The server accepted the listing (HTTP 200) and wrote the district record, but it never appeared in the global GET /listings registry — the registry is full or out of sync SERVER-side. The wallet and the map will keep showing this item as unlisted until the server is fixed.")
                }
                success = "Listed for \(Fmt.bsv(priceSats)) BSV — verified present in the marketplace registry! Turns green on bsvmap.io within a minute."
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await store.loadHoldings()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Delist (signed instruction + verify-gone)

struct DelistView: View {
    @EnvironmentObject private var store: WalletStore
    let holding: Holding

    @State private var error = ""
    @State private var success = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section("Listing") {
                KVRow(k: "Item", v: holding.name)
                KVRow(k: "Type", v: holding.kindLabel)
                if let p = holding.priceSat, p > 0 {
                    KVRow(k: "Price", v: "\(Fmt.bsv(p)) BSV (\(Fmt.sats(p)) sats)")
                }
                KVRow(k: "Ordinal UTXO", v: holding.utxoShort, mono: true)
                KVRow(k: "Seller", v: Fmt.shortAddress(store.address), mono: true)
            }
            Section {
                Text("You sign a delist instruction with your seller key — no coins move. The wallet then verifies the listing is really gone from BOTH server stores.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                InlineAlert(kind: .error, text: error)
                InlineAlert(kind: .success, text: success)
                if success.isEmpty {
                    Button {
                        delist()
                    } label: {
                        if busy { ProgressView().frame(maxWidth: .infinity) }
                        else { Text("Sign & remove listing").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                }
            }
        }
        .ordnetBackground()
        .navigationTitle("Remove listing")
    }

    private func delist() {
        error = ""; busy = true
        Task {
            do {
                try await store.delistRequest(holding)
                let still = await store.verifyStillListed([holding])
                if let (_, whereStr) = still.first {
                    throw WalletEngine.EngineError.callFailed(
                        "The server answered OK but the listing is still present in the \(whereStr). The server-side delist must clear BOTH the global registry and the per-district record.")
                }
                success = "Listing removed and verified gone from the registry — \(holding.name) is no longer for sale."
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await store.loadHoldings()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Bulk list / delist (max 300 per run, rate-limit friendly, trust-but-verify)

struct BulkActionSheet: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.dismiss) private var dismiss

    enum Kind { case list, delist }
    let kind: Kind
    let items: [Holding]
    var onDone: () -> Void

    @State private var priceBSV = ""
    @State private var progress = ""
    @State private var error = ""
    @State private var success = ""
    @State private var busy = false

    private var priceSats: Int {
        let v = Double(priceBSV.replacingOccurrences(of: ",", with: ".")) ?? 0
        return v > 0 ? Int((v * 1e8).rounded()) : 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(items.count) BSVmap\(items.count == 1 ? "" : "s") selected")
                        .font(.callout.weight(.semibold))
                }
                if kind == .list {
                    Section("Price per item") {
                        TextField("Price in BSV per item", text: $priceBSV)
                            .keyboardType(.decimalPad)
                        if priceSats >= 1 {
                            Text("= \(Fmt.sats(priceSats)) sats per item · \(Fmt.bsv(priceSats * items.count)) BSV total if all sell")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if !progress.isEmpty {
                        HStack(spacing: 8) {
                            if busy { ProgressView() }
                            Text(progress).font(.footnote)
                        }
                    }
                    InlineAlert(kind: .error, text: error)
                    InlineAlert(kind: .success, text: success)
                    if success.isEmpty {
                        Button {
                            run()
                        } label: {
                            Text(kind == .list
                                 ? "Sign \(items.count) listing\(items.count == 1 ? "" : "s")"
                                 : "Sign \(items.count) delisting\(items.count == 1 ? "" : "s")")
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || (kind == .list && priceSats < 1) || items.isEmpty)
                    }
                }
            }
            .ordnetBackground()
            .keyboardDismissBar()   // v2.5.1
            .navigationTitle(kind == .list ? "Bulk list" : "Bulk delist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(busy ? "Working…" : "Close") {
                        onDone()
                        dismiss()
                    }
                    .disabled(busy)
                }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    private func run() {
        error = ""; success = ""; busy = true
        let isDelist = (kind == .delist)
        let price = priceSats
        Task {
            var done = 0
            var failed: [String] = []
            var okItems: [Holding] = []
            for (i, it) in items.enumerated() {
                progress = "\(isDelist ? "Delisting" : "Listing") \(it.name) (\(i + 1)/\(items.count))…"
                if i > 0 { try? await Task.sleep(nanoseconds: 250_000_000) } // stay under API rate limits
                do {
                    if isDelist { try await store.delistRequest(it) }
                    else { try await store.listRequest(it, priceSat: price) }
                    done += 1
                    okItems.append(it)
                } catch {
                    failed.append("\(it.name) (\(error.localizedDescription))")
                }
            }
            if isDelist && !okItems.isEmpty {
                progress = "Verifying removal on the server…"
                let still = await store.verifyStillListed(okItems)
                if !still.isEmpty {
                    done -= still.count
                    for (it, whereStr) in still { failed.append("\(it.name) (still in the \(whereStr))") }
                }
            }
            if !isDelist && !okItems.isEmpty {
                progress = "Verifying listings in the marketplace registry…"
                let missing = await store.verifyListedInRegistry(okItems)
                if !missing.isEmpty {
                    done -= missing.count
                    for it in missing { failed.append("\(it.name) (accepted by the server but NOT in the global registry — registry full/out of sync server-side)") }
                }
            }
            progress = ""
            if !failed.isEmpty {
                error = "\(done) \(isDelist ? "delisted" : "listed"), \(failed.count) failed: \(failed.prefix(4).joined(separator: ", "))\(failed.count > 4 ? " …" : "")"
            } else {
                success = isDelist
                    ? "All \(done) listings removed."
                    : "All \(done) items listed for \(Fmt.bsv(price)) BSV each! Turning green on bsvmap.io within a minute."
            }
            await store.loadHoldings()
            busy = false
        }
    }
}
