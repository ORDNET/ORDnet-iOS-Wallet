import SwiftUI

/// Wallet home: balance card + holdings (SNS names / BSVmaps / For sale),
/// port of the extension's idle view.
struct HomeView: View {
    @EnvironmentObject private var store: WalletStore

    // v2.1 — OpNS as third category next to SNS and BSVmaps; labels kept
    // compact so four segments fit ("SNS names" -> "SNS")
    enum HoldTab: String, CaseIterable, Identifiable {
        case sns = "SNS"
        case bsvmap = "BSVmaps"
        case opns = "OpNS"
        case sale = "For sale"
        var id: String { rawValue }

        var kind: HoldingKind? {
            switch self {
            case .sns: return .sns
            case .bsvmap: return .bsvmap
            case .opns: return .opns
            case .sale: return nil
            }
        }
    }

    @State private var tab: HoldTab = .sns
    @State private var search = ""
    @State private var copied = false

    // v2.0 — pagination for the SNS names and BSVmaps lists, identical to the
    // Chrome extension pattern: search bar -> pager bar -> list, 20 per page
    @State private var page = 0
    private let holdPerPage = 20

    // programmatic navigation for the action row (no List chevrons)
    @State private var goSend = false
    @State private var goReceive = false
    @State private var goHistory = false

    // bulk list / delist selection mode
    @State private var bulkMode = false
    @State private var bulkSelection = Set<String>()   // Holding.id
    @State private var showBulkSheet = false

    private var filtered: [Holding] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matches: (Holding) -> Bool = { h in
            q.isEmpty || h.name.lowercased().contains(q) || (h.district.map { String($0).contains(q) } ?? false)
        }
        let arr = store.holdings.filter { h in
            if let k = tab.kind { guard h.kind == k else { return false } }
            // For sale: bsvmap-listings ÉN domain-registry-listings (v2.6.1)
            else { guard h.isListed || h.domainListedUsd != nil else { return false } }
            return matches(h)
        }
        // listed items always on top, original order preserved within each group
        return arr.sorted { a, b in
            ((a.isListed || a.domainListedUsd != nil) ? 1 : 0) > ((b.isListed || b.domainListedUsd != nil) ? 1 : 0)
        }
    }

    // v2.0 — pagination over the filtered SNS/BSVmaps/OpNS items ("For sale" stays unpaged)
    private var paged: Bool { tab != .sale }
    private var holdPages: Int { max(1, (filtered.count + holdPerPage - 1) / holdPerPage) }
    private var holdSafePage: Int { min(max(page, 0), holdPages - 1) }
    private var holdPageItems: [Holding] { Array(filtered.dropFirst(holdSafePage * holdPerPage).prefix(holdPerPage)) }

    private func count(_ t: HoldTab) -> Int {
        switch t {
        case .sns: return store.holdings.filter { $0.kind == .sns }.count
        case .bsvmap: return store.holdings.filter { $0.kind == .bsvmap }.count
        case .opns: return store.holdings.filter { $0.kind == .opns }.count
        case .sale: return store.holdings.filter { $0.isListed || $0.domainListedUsd != nil }.count
        }
    }

    /// each segment shows "—" when ITS OWN index is unreachable
    private func countLabel(_ t: HoldTab) -> String {
        let ok = (t == .opns) ? store.opnsOk : store.indexerOk
        return ok ? String(count(t)) : "—"
    }

    var body: some View {
        List {
            Section {
                balanceCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                HStack(spacing: 10) {
                    actionButton("Send", icon: "arrow.up.right", prominent: true) { goSend = true }
                    actionButton("Receive", icon: "qrcode") { goReceive = true }
                    actionButton("History", icon: "clock.arrow.circlepath") { goHistory = true }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                // v2.2.1 — two stacked segmented bars, each as its OWN list
                // row with exactly the original picker's modifiers, so both
                // bars render pixel-identical to the old single bar (a shared
                // VStack row clipped the top rounding). Row 1 SNS + OpNS,
                // row 2 BSVmaps + For sale. Both share the same selection;
                // the bar without the selected tag shows no highlight.
                Picker("Holdings", selection: $tab) {
                    Text("\(HoldTab.sns.rawValue) (\(countLabel(.sns)))").tag(HoldTab.sns)
                    Text("\(HoldTab.opns.rawValue) (\(countLabel(.opns)))").tag(HoldTab.opns)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)   // v2.2.2: no separator line between the bars
                .onChange(of: tab) { _, _ in page = 0 }

                Picker("Holdings (row 2)", selection: $tab) {
                    Text("\(HoldTab.bsvmap.rawValue) (\(countLabel(.bsvmap)))").tag(HoldTab.bsvmap)
                    Text("\(HoldTab.sale.rawValue) (\(countLabel(.sale)))").tag(HoldTab.sale)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())   // v2.2.2: no extra top inset — half the old gap
                .listRowSeparator(.hidden)

                if !store.holdings.isEmpty || !search.isEmpty {
                    TextField("Search name or district…", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .onChange(of: search) { _, _ in page = 0 }
                }

                // v2.0 — pager bar ABOVE the list (search -> pager -> items),
                // exactly like the Chrome extension's SNS list
                if paged && holdPages > 1 {
                    HStack {
                        Button("‹ Prev") { page = holdSafePage - 1 }
                            .disabled(holdSafePage <= 0)
                        Spacer()
                        Text("Page \(holdSafePage + 1) / \(holdPages) · \(filtered.count) total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Next ›") { page = holdSafePage + 1 }
                            .disabled(holdSafePage >= holdPages - 1)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                }

                if bulkMode {
                    bulkBar
                    if let hint = bulkHint {
                        InlineAlert(kind: .warning, text: hint)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    }
                }

                if filtered.isEmpty {
                    Text(emptyNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    // v2.0 — SNS/BSVmaps render per page; "For sale" shows all
                    ForEach(paged ? holdPageItems : filtered) { h in
                        holdingRow(h)
                    }
                }
            } header: {
                HStack {
                    Text("Holdings")
                    Spacer()
                    if FeatureFlags.marketplaceEnabled {
                        Button(bulkMode ? "Done" : (tab == .sale ? "Bulk delist" : "Bulk list")) {
                            bulkMode.toggle()
                            bulkSelection = []
                            if bulkMode {
                                // pre-select every eligible item, like the extension
                                bulkSelection = Set(filtered.filter(bulkEligible).map(\.id))
                            }
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .ordnetBackground()
        .navigationDestination(isPresented: $goSend) { SendView() }
        .navigationDestination(isPresented: $goReceive) { ReceiveView() }
        .navigationDestination(isPresented: $goHistory) { HistoryView() }
        .navigationTitle(store.activeAccount?.name ?? "Wallet")
        .toolbar {
            // v2.3.2 — Settings and UTXO tools live top-left on the lock's
            // line (user layout: settings first, then UTXO); lock stays right
            ToolbarItemGroup(placement: .topBarLeading) {
                NavigationLink { SettingsView() } label: {
                    Image(systemName: "gearshape")
                }
                NavigationLink { UtxoToolsView() } label: {
                    Image(systemName: "arrow.triangle.branch")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.lock()
                } label: {
                    Image(systemName: "lock")
                }
            }
        }
        .refreshable {
            await store.refreshBalance()
            await store.loadHoldings()
        }
        .task {
            if store.balance == nil { await store.refreshBalance() }
            if store.holdings.isEmpty { await store.loadHoldings() }
        }
        .sheet(isPresented: $showBulkSheet) {
            BulkActionSheet(
                kind: tab == .sale ? .delist : .list,
                items: store.holdings.filter { bulkSelection.contains($0.id) }
            ) {
                bulkMode = false
                bulkSelection = []
            }
            .environmentObject(store)
        }
    }

    /// equal-width action button: icon above a single-line label, no chevrons
    @ViewBuilder
    private func actionButton(_ title: String, icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        let label = VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
            Text(title)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)

        if prominent {
            Button(action: action) { label }.buttonStyle(.ordnetProminent)
        } else {
            Button(action: action) { label }.buttonStyle(.ordnetOutline)
        }
    }

    private var emptyNote: String {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return "No items match \"\(search)\"." }
        // the OpNS tab degrades on ITS OWN flag — a broken OpNS index never
        // touches the SNS/BSVmaps tabs, and vice versa
        if tab == .opns {
            if !store.opnsOk { return "Could not reach the OpNS index at search.ordnet.io." }
            return "No OpNS names on this address yet."
        }
        if !store.indexerOk { return "Could not reach the ORDnet indexer at bsvmap.io." }
        switch tab {
        case .sale: return "Nothing listed for sale yet. Use the tag button on an SNS name or BSVmap to list it."
        case .sns: return "No SNS names on this address yet."
        case .bsvmap: return "No BSVmaps on this address yet. Claim one on bsvmap.io!"
        case .opns: return "No OpNS names on this address yet."
        }
    }

    private var balanceCard: some View {
        VStack(spacing: 8) {
            Text("BitcoinSV").font(.footnote).foregroundStyle(.secondary)
            if let b = store.balance {
                let sats = b.total
                (Text(Fmt.bsv(sats)).font(.system(size: 34, weight: .bold, design: .rounded))
                 + Text(" BSV").font(.headline).foregroundStyle(.secondary))
                Text(subLine(sats: sats))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().padding(.vertical, 6)
            }
            Button {
                UIPasteboard.general.string = store.address
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            } label: {
                HStack(spacing: 6) {
                    Text(store.address)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .foregroundStyle(copied ? Theme.statusGreen : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private func subLine(sats: Int) -> String {
        var s = "\(store.activeAccount?.name ?? "Account") · \(Fmt.sats(sats)) sats"
        if let rate = store.usdRate, rate > 0 {
            s += String(format: " · ≈ $%.2f", Double(sats) / 1e8 * rate)
        }
        return s
    }

    // MARK: holdings rows

    private func bulkEligible(_ h: Holding) -> Bool {
        if tab == .sale { return h.kind == .bsvmap && h.isListed }
        return h.kind == .bsvmap && !h.isListed && h.status != "contract"
    }

    /// why nothing is selectable — mirrors the extension's bulk-mode notes
    private var bulkHint: String? {
        guard bulkMode, !filtered.contains(where: bulkEligible) else { return nil }
        if tab == .sns {
            return "Bulk list currently covers BSVmaps — SNS listings coming soon."
        }
        if tab == .opns {
            return "OpNS names cannot be listed for sale — display, resolve and send only."
        }
        return tab == .sale
            ? "No listed BSVmaps to delist here."
            : "No unlisted BSVmaps here."
    }

    @ViewBuilder
    private func holdingRow(_ h: Holding) -> some View {
        HStack(spacing: 10) {
            if bulkMode {
                Image(systemName: bulkSelection.contains(h.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(bulkEligible(h) ? Color.accentColor : Color.secondary.opacity(0.3))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black)
                if h.kind == .bsvmap {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.bsvmapOrange).padding(8)
                } else if h.kind == .opns {
                    // @-icon like SNS on search.ordnet.io — and deliberately
                    // NO ✓ badge: that mark is reserved for ORDnet inscriptions
                    Image(systemName: "at")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    OrdplugLogo(size: 22)
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(h.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(h.kind == .bsvmap ? "district #\(h.district ?? 0) · block \(h.claimHeight)"
                     : h.kind == .opns ? "OpNS"
                     : "block \(h.claimHeight)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(holding: h)

            if !bulkMode {
                Menu {
                    // OpNS: display, resolve and send ONLY — no marketplace
                    // flows (that decision has explicitly not been taken)
                    if FeatureFlags.marketplaceEnabled, h.kind != .opns {
                        if h.isListed {
                            NavigationLink { DelistView(holding: h) } label: {
                                Label("Remove listing", systemImage: "xmark.circle")
                            }
                        } else if h.domainListedUsd != nil {
                            // v2.6.1 — listed on the DOMAIN registry: manage it
                            // there; never offer a second (bsvmap) listing
                            NavigationLink { DomainDetailView(name: h.name) } label: {
                                Label("Manage domain listing", systemImage: "tag")
                            }
                        } else if h.status != "contract" {
                            NavigationLink { ListOrdinalView(holding: h) } label: {
                                Label("List for sale", systemImage: "tag")
                            }
                        }
                    }
                    NavigationLink { SendOrdinalView(holding: h) } label: {
                        Label("Send", systemImage: "arrow.up.right")
                    }
                    if h.kind == .sns || h.kind == .opns {
                        // never force-unwrap a URL built from a user-controlled name
                        if let enc = h.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                           let url = URL(string: "https://search.ordnet.io/?q=\(enc)") {
                            Link(destination: url) {
                                Label("View on ORDnet", systemImage: "arrow.up.forward.square")
                            }
                        }
                    } else if let d = h.district,
                              let url = URL(string: "https://bsvmap.io/#\(d)") {
                        Link(destination: url) {
                            Label("View on bsvmap.io", systemImage: "map")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard bulkMode, bulkEligible(h) else { return }
            if bulkSelection.contains(h.id) { bulkSelection.remove(h.id) }
            else if bulkSelection.count < 300 { bulkSelection.insert(h.id) }
        }
    }

    private var bulkBar: some View {
        HStack {
            Text("\(bulkSelection.count) selected\(bulkSelection.count >= 300 ? " (max)" : "")")
                .font(.footnote)
            Spacer()
            Button("Select all") {
                for h in filtered where bulkEligible(h) && bulkSelection.count < 300 {
                    bulkSelection.insert(h.id)
                }
            }
            .font(.footnote)
            Button(tab == .sale ? "Delist…" : "List…") {
                showBulkSheet = true
            }
            .font(.footnote.weight(.semibold))
            .disabled(bulkSelection.isEmpty)
        }
        .listRowBackground(Color.clear)
    }
}
