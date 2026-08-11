import SwiftUI

/// "My .web3 domains" — port of the extension's browse + domain detail views:
/// registry list, whois, signed set-target, subdomains, routes, marketplace
/// (list/update/delist in USD) and domain transfer. All writes are signed
/// wallet actions (key = ownership) in the exact `ordnet-registry|…` format.
struct DomainsView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var domains: [MyDomain] = []
    @State private var loading = true
    @State private var error = ""
    // since v1.10 — search + pagination (10 per page), pager bar ABOVE the list (SNS pattern)
    @State private var search = ""
    @State private var page = 0

    private let perPage = 10
    private var filtered: [MyDomain] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? domains : domains.filter { $0.name.lowercased().contains(q) }
    }
    private var pages: Int { max(1, (filtered.count + perPage - 1) / perPage) }
    private var safePage: Int { min(max(page, 0), pages - 1) }
    private var pageItems: [MyDomain] { Array(filtered.dropFirst(safePage * perPage).prefix(perPage)) }

    var body: some View {
        List {
            Section {
                if loading {
                    ProgressView()
                } else if !error.isEmpty {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                } else if domains.isEmpty {
                    Text("No .web3 domains on this wallet yet — claim one via ORD/domains in the Browser tab.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    // volgorde: zoekveld -> pagineringsbalk -> domeinen (zoals de SNS-lijst)
                    TextField("Search…", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: search) { _, _ in page = 0 }
                    if pages > 1 {
                        HStack {
                            Button("‹ Prev") { page = safePage - 1 }
                                .disabled(safePage <= 0)
                            Spacer()
                            Text("Page \(safePage + 1) / \(pages) · \(filtered.count) total")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Next ›") { page = safePage + 1 }
                                .disabled(safePage >= pages - 1)
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                    if pageItems.isEmpty {
                        Text("No domains match \"\(search)\".")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pageItems) { d in
                            NavigationLink {
                                DomainDetailView(name: d.name)
                            } label: {
                                HStack {
                                    Text(d.name).font(.callout.weight(.medium))
                                    Spacer()
                                    if d.isForSale {
                                        Text("For sale\(d.listingPrice.map { String(format: " · $%.0f", $0) } ?? "")")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 7).padding(.vertical, 3)
                                            .background(Capsule().fill(Theme.statusGreen.opacity(0.15)))
                                            .foregroundStyle(Theme.statusGreen)
                                    } else {
                                        Text(d.status)
                                            .font(.caption2)
                                            .padding(.horizontal, 7).padding(.vertical, 3)
                                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("My .web3 domains")
            } footer: {
                Text("Domains owned by \(Fmt.shortAddress(store.address))")
            }
        }
        .ordnetBackground()
        .navigationTitle("Domains")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        error = ""
        do {
            domains = try await Api.myDomains(address: store.address)
        } catch {
            self.error = "Could not load your domains right now."
        }
        loading = false
    }
}

// MARK: - Domain detail

struct DomainDetailView: View {
    @EnvironmentObject private var store: WalletStore
    let name: String

    @State private var whois: DomainWhois?
    @State private var subs: [DomainRecord] = []
    @State private var routes: [DomainRecord] = []
    @State private var listing: DomainListing?

    @State private var targetTxid = ""
    @State private var targetVout = ""
    @State private var subNew = ""
    @State private var subTx = ""
    @State private var rtPath = ""
    @State private var rtSub = ""
    @State private var rtTx = ""
    @State private var mktPrice = ""
    @State private var trAddr = ""
    @State private var trConfirm = ""

    @State private var error = ""
    @State private var ok = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section("Domain") {
                if let w = whois {
                    KVRow(k: "Status", v: w.status)
                    KVRow(k: "Owner", v: Fmt.shortAddress(w.owner), mono: true)
                    KVRow(k: "Target", v: w.targetTxid.map { String($0.prefix(16)) + "…" } ?? "not set", mono: true)
                    KVRow(k: "Registered", v: w.registeredAt ?? "—")
                } else {
                    ProgressView()
                }
            }

            Section {
                InlineAlert(kind: .error, text: error)
                InlineAlert(kind: .success, text: ok)
            }

            Section("Content target (TXID the domain points to)") {
                TextField("Transaction ID (64 hex chars)", text: $targetTxid)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Output index (vout, default 0)", text: $targetVout)
                    .keyboardType(.numberPad)
                Button("Sign & save target") { saveTarget() }
                    .disabled(busy)
                Button("Remove target", role: .destructive) {
                    signedAction("Removing target…") {
                        // v2.5.2: same fix as set-target — the target handlers
                        // identify the domain by the canonical `name` field
                        try await store.signedRegistryPost("/wallet/remove-target", action: "remove-target",
                                                           fields: [name], body: ["name": name, "domain": name])
                        targetTxid = ""; targetVout = ""
                        return "Target removed ✓"
                    }
                }
                .disabled(busy)
            }

            Section("Subdomains") {
                ForEach(subs) { r in
                    recordRow(label: r.subdomain ?? "", txid: r.txid) {
                        signedAction("Removing…") {
                            try await store.signedRegistryPost("/wallet/subdomain-delete", action: "subdomain-delete",
                                                               fields: [name, r.subdomain ?? ""],
                                                               body: ["domain": name, "subdomain": r.subdomain ?? ""])
                            return "Subdomain removed ✓"
                        }
                    }
                }
                TextField("subdomain (e.g. blog)", text: $subNew)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("TXID or TXID:vout", text: $subTx)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Add subdomain") { addSubdomain() }
                    .disabled(busy)
            }

            Section("Routes (paths)") {
                ForEach(routes) { r in
                    recordRow(label: "\(r.subdomain.map { "\($0) · " } ?? "")/\(r.path ?? "")", txid: r.txid) {
                        signedAction("Removing…") {
                            let subValue: Any = r.subdomain.map { $0 as Any } ?? NSNull()
                            try await store.signedRegistryPost("/wallet/route-delete", action: "route-delete",
                                                               fields: [name, r.subdomain ?? "", r.path ?? ""],
                                                               body: ["domain": name, "subdomain": subValue, "path": r.path ?? ""])
                            return "Route removed ✓"
                        }
                    }
                }
                TextField("path (e.g. about)", text: $rtPath)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("subdomain (optional)", text: $rtSub)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("TXID or TXID:vout", text: $rtTx)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Add route") { addRoute() }
                    .disabled(busy)
            }

            if FeatureFlags.marketplaceEnabled {
            Section("Marketplace") {
                if let l = listing {
                    KVRow(k: "Listed", v: String(format: "$%.0f", l.priceUsd))
                    TextField("New price USD", text: $mktPrice)
                        .keyboardType(.numberPad)
                    Button("Update price") { listOrUpdate(update: true) }
                        .disabled(busy)
                    Button("Delist", role: .destructive) {
                        signedAction("Delisting…") {
                            try await store.signedRegistryPost("/wallet/delist", action: "delist",
                                                               fields: [name], body: ["domain": name])
                            return "Delisted ✓"
                        }
                    }
                    .disabled(busy)
                } else {
                    TextField("Price USD", text: $mktPrice)
                        .keyboardType(.numberPad)
                    Button("List for sale") { listOrUpdate(update: false) }
                        .disabled(busy)
                }
            }
            }   // FeatureFlags.marketplaceEnabled

            Section("Transfer domain") {
                TextField("New owner BSV address", text: $trAddr)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Type the domain name to confirm", text: $trConfirm)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Sign & transfer domain", role: .destructive) { transfer() }
                    .disabled(busy)
            }
        }
        .ordnetBackground()
        .keyboardDismissBar()   // v2.5.1: vout-numberPad had no way out
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private func recordRow(label: String, txid: String, onDelete: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            Text(String(txid.prefix(12)) + "…").font(.caption2.monospaced()).foregroundStyle(.secondary)
            Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
    }

    private func load() async {
        whois = try? await Api.whois(name: name)
        if let w = whois {
            targetTxid = w.targetTxid ?? ""
            targetVout = w.targetVout.map(String.init) ?? ""
        }
        if let recs = try? await Api.domainRecords(name: name) {
            subs = recs.subs
            routes = recs.routes
            listing = recs.listing
        }
    }

    private func signedAction(_ progress: String, _ run: @escaping () async throws -> String) {
        error = ""; ok = ""; busy = true
        Task {
            do {
                ok = try await run()
                await load()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    /// port of parseTx(): TXID with optional :vout
    private func parseTx(_ v: String) -> (txid: String, vout: Int)? {
        let s = v.trimmingCharacters(in: .whitespaces).lowercased()
        guard let m = s.range(of: "^([0-9a-f]{64})(?::(\\d+))?$", options: .regularExpression) else { return nil }
        let parts = String(s[m]).split(separator: ":")
        return (String(parts[0]), parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
    }
    private func validName(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]?$", options: .regularExpression) != nil
    }

    private func saveTarget() {
        error = ""; ok = ""
        let txid = targetTxid.trimmingCharacters(in: .whitespaces).lowercased()
        let vout = Int(targetVout) ?? 0
        guard txid.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            error = "Enter a valid 64-character transaction ID."
            return
        }
        guard vout >= 0 else { error = "Output index must be 0 or higher."; return }
        busy = true
        Task {
            do {
                try await store.setDomainTarget(domain: name, txid: txid, vout: vout)
                ok = "Target updated ✓"
                await load()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func addSubdomain() {
        error = ""; ok = ""
        let sd = subNew.trimmingCharacters(in: .whitespaces).lowercased()
        guard validName(sd) else { error = "Invalid subdomain name (alphanumeric, hyphens)."; return }
        guard let tx = parseTx(subTx) else { error = "Enter a valid TXID, optionally as TXID:vout."; return }
        signedAction("Saving…") {
            try await store.signedRegistryPost("/wallet/subdomain", action: "subdomain",
                                               fields: [name, sd, tx.txid, String(tx.vout)],
                                               body: ["domain": name, "subdomain": sd, "txid": tx.txid, "vout": tx.vout])
            subNew = ""; subTx = ""
            return "Subdomain saved ✓"
        }
    }

    private func addRoute() {
        error = ""; ok = ""
        var p = rtPath.trimmingCharacters(in: .whitespaces).lowercased()
        while p.hasPrefix("/") { p.removeFirst() }
        let sub = rtSub.trimmingCharacters(in: .whitespaces).lowercased()
        guard validName(p) else { error = "Invalid path (alphanumeric, hyphens)."; return }
        guard let tx = parseTx(rtTx) else { error = "Enter a valid TXID, optionally as TXID:vout."; return }
        signedAction("Saving…") {
            do {
                let subValue: Any = sub.isEmpty ? NSNull() : (sub as Any)
                try await store.signedRegistryPost("/wallet/route", action: "route",
                                                   fields: [name, sub, p, tx.txid, String(tx.vout)],
                                                   body: ["domain": name, "subdomain": subValue, "path": p, "txid": tx.txid, "vout": tx.vout])
            } catch {
                if error.localizedDescription.contains("subdomain_not_found") {
                    throw WalletEngine.EngineError.callFailed("That subdomain does not exist yet — create it first.")
                }
                throw error
            }
            rtPath = ""; rtSub = ""; rtTx = ""
            return "Route saved ✓"
        }
    }

    /// format a number exactly like JavaScript's String(n) — the signed message
    /// must match the extension byte-for-byte ("25", not "25.0")
    private func jsNum(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
    }

    private func listOrUpdate(update: Bool) {
        error = ""; ok = ""
        guard let price = Double(mktPrice), price > 0 else { error = "Enter a valid price in USD."; return }
        signedAction(update ? "Updating…" : "Listing…") {
            do {
                if update {
                    try await store.signedRegistryPost("/wallet/listing-update", action: "listing-update",
                                                       fields: [name, jsNum(price)],
                                                       body: ["domain": name, "price_usd": price])
                } else {
                    try await store.signedRegistryPost("/wallet/list", action: "list",
                                                       fields: [name, jsNum(price)],
                                                       body: ["domain": name, "price_usd": price])
                }
            } catch {
                let m = error.localizedDescription
                if m.contains("invalid_price") { throw WalletEngine.EngineError.callFailed("Price is below the minimum listing price.") }
                if m.contains("has_pending_order") { throw WalletEngine.EngineError.callFailed("A purchase is in progress — listing is locked.") }
                throw error
            }
            return update ? "Price updated ✓" : "Listed for sale ✓"
        }
    }

    private func transfer() {
        error = ""; ok = ""
        let to = trAddr.trimmingCharacters(in: .whitespaces)
        guard to.range(of: "^1[a-km-zA-HJ-NP-Z1-9]{25,34}$", options: .regularExpression) != nil else {
            error = "Enter a valid BSV address for the new owner."
            return
        }
        guard trConfirm.trimmingCharacters(in: .whitespaces).lowercased() == name else {
            error = "Type the domain name exactly to confirm the transfer."
            return
        }
        signedAction("Transferring…") {
            do {
                try await store.signedRegistryPost("/wallet/transfer", action: "transfer",
                                                   fields: [name, to],
                                                   body: ["domain": name, "new_owner": to])
            } catch {
                if error.localizedDescription.contains("listed_delist_first") {
                    throw WalletEngine.EngineError.callFailed("This domain is listed for sale — delist it first.")
                }
                throw error
            }
            trAddr = ""; trConfirm = ""
            return "Domain transferred ✓"
        }
    }
}
