import SwiftUI

/// ORD/ner (v2.3) — the on-chain file browser, native port of ord-app v42:
/// accounts are FOLDERS; a folder shows every inscription the address
/// currently holds (1Sat index), in grid or list view. Tapping a file opens
/// a detail screen with preview + "Open in Browser" / "Copy TX info" / "Send"
/// (1-sat ordinal transfer). The Upload tab's "Inscribed with this wallet"
/// log lives here now: it supplies filenames, and items the address no
/// longer holds appear with a "sent" label (hideable).
struct OrdnerView: View {
    @EnvironmentObject private var store: WalletStore

    var body: some View {
        List {
            Section {
                ForEach(Array(store.accounts.enumerated()), id: \.element.id) { i, acc in
                    NavigationLink {
                        OrdnerFolderView(account: acc)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Theme.statusYellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(acc.name).font(.callout.weight(.medium))
                                Text(Fmt.shortAddress(acc.address))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if i == store.active {
                                Text("active")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Capsule().fill(Theme.statusGreen.opacity(0.15)))
                                    .foregroundStyle(Theme.statusGreen)
                            }
                        }
                    }
                }
            } header: {
                Text("ORD/ner")
            } footer: {
                Text("Every account is a folder with the on-chain files it currently holds.")
            }
        }
        .ordnetBackground()
        .navigationTitle("ORD/ner")
    }
}

// MARK: - folder: the files of one account

struct OrdnerFolderView: View {
    @EnvironmentObject private var store: WalletStore
    let account: Account

    @AppStorage("ordner_view_grid") private var gridView = true
    @AppStorage("ordner_hide_sent") private var hideSent = false
    @State private var files: [OrdnerFile] = []
    @State private var loading = true
    @State private var error = ""

    private var visibleFiles: [OrdnerFile] {
        hideSent ? files.filter { !$0.sentLabel } : files
    }
    private var sentCount: Int { files.filter { $0.sentLabel }.count }

    var body: some View {
        List {
            // toolbar row: breadcrumb + grid/list toggle (the v42 pattern)
            Section {
                HStack {
                    Text("ORD/ner › \(account.name)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("View", selection: $gridView) {
                        Image(systemName: "square.grid.2x2").tag(true)
                        Image(systemName: "list.bullet").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 100)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                .listRowSeparator(.hidden)

                if sentCount > 0 {
                    Toggle("Hide sent items (\(sentCount))", isOn: $hideSent)
                        .font(.footnote)
                }
            }

            Section {
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if !error.isEmpty {
                    InlineAlert(kind: .error, text: error)
                        .listRowBackground(Color.clear)
                } else if visibleFiles.isEmpty {
                    Text("No inscriptions in this folder yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if gridView {
                    gridContent
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(visibleFiles) { f in
                        NavigationLink { OrdnerFileDetailView(file: f, account: account) } label: {
                            listRow(f)
                        }
                    }
                }
            } footer: {
                if !loading && error.isEmpty {
                    Text("\(visibleFiles.count) file\(visibleFiles.count == 1 ? "" : "s") · on-chain holdings of \(Fmt.shortAddress(account.address))")
                }
            }
        }
        .ordnetBackground()
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private var gridContent: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
            ForEach(visibleFiles) { f in
                NavigationLink {
                    OrdnerFileDetailView(file: f, account: account)
                } label: {
                    VStack(spacing: 6) {
                        OrdnerThumb(file: f, side: 76)
                        Text(f.displayName)
                            .font(.caption2)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.primary)
                        if f.sentLabel { sentPill }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func listRow(_ f: OrdnerFile) -> some View {
        HStack(spacing: 10) {
            OrdnerThumb(file: f, side: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.displayName).font(.callout.weight(.medium)).lineLimit(1)
                Text("\(f.typeLabel) · \(f.sizeLabel) · \(f.height.map { "block \($0)" } ?? "pending")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if f.sentLabel { sentPill }
        }
    }

    private var sentPill: some View {
        Text("sent")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .foregroundStyle(.secondary)
    }

    private func load() async {
        error = ""
        let log = store.inscriptionLog(for: account.address)
        do {
            var chain = try await Api.ordnerFiles(address: account.address)
            // enrich with filenames from the app's inscription log
            let names = Dictionary(uniqueKeysWithValues: log.map { ($0.txid, $0.filename) })
            for i in chain.indices {
                if let n = names[chain[i].originTxid] { chain[i].name = n }
            }
            // log items the address no longer holds -> "sent" entries
            let held = Set(chain.map { $0.originTxid })
            let sent = log.filter { !held.contains($0.txid) }.map { rec in
                OrdnerFile(originTxid: rec.txid, originVout: 0,
                           currentTxid: rec.txid, currentVout: 0,
                           contentType: rec.contentType, size: rec.bytes,
                           height: nil, name: rec.filename, sentLabel: true)
            }
            files = chain + sent
        } catch {
            // index down: degrade to the local log only, inline note
            self.error = "Could not reach the 1Sat index — showing only files inscribed via this app."
            files = log.map { rec in
                OrdnerFile(originTxid: rec.txid, originVout: 0,
                           currentTxid: rec.txid, currentVout: 0,
                           contentType: rec.contentType, size: rec.bytes,
                           height: nil, name: rec.filename)
            }
        }
        loading = false
    }
}

// MARK: - thumbnail (images render, everything else gets its type icon)

struct OrdnerThumb: View {
    let file: OrdnerFile
    var side: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side > 50 ? 10 : 8)
                .fill(Color.black)
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side > 50 ? 10 : 8))
            } else {
                Image(systemName: file.icon)
                    .font(.system(size: side * 0.42, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: side, height: side)
        .task {
            guard image == nil, file.contentType.hasPrefix("image/"),
                  file.size > 0, file.size < 2 * 1024 * 1024 else { return }
            // content via our OWN path: raw hex + extractOrd (txHex is cached)
            guard let hex = try? await Api.txHex(file.originTxid),
                  let ord = try? WalletEngine.shared.call("extractOrd", ["rawTxHex": hex, "vout": file.originVout]) as? [String: Any],
                  let b64 = ord["dataB64"] as? String,
                  let data = Data(base64Encoded: b64) else { return }
            image = UIImage(data: data)
        }
    }
}

// MARK: - file detail: preview + Open in Browser / Copy TX info / Send

struct OrdnerFileDetailView: View {
    @EnvironmentObject private var store: WalletStore
    let file: OrdnerFile
    let account: Account

    @State private var textPreview = ""
    @State private var copied = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        OrdnerThumb(file: file, side: 140)
                        if !textPreview.isEmpty {
                            Text(textPreview)
                                .font(.caption.monospaced())
                                .lineLimit(6)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            if file.sentLabel {
                Section {
                    InlineAlert(kind: .warning, text: "This file was inscribed via this app but the address no longer holds it — it was sent or transferred.")
                }
            }

            Section("File") {
                if let n = file.name { KVRow(k: "Name", v: n) }
                KVRow(k: "Type", v: file.contentType)
                KVRow(k: "Size", v: file.sizeLabel)
                KVRow(k: "Status", v: file.height.map { "confirmed · block \($0)" } ?? (file.sentLabel ? "—" : "pending (mempool)"))
            }

            Section {
                // v2.6.1 — één tik op een rij kopieert de VOLLEDIGE waarde
                // (voorheen: lang-drukken kopieerde de afgekapte weergave)
                copyRow(label: "TXID", shown: Fmt.shortTxid(file.originTxid),
                        full: file.originTxid, what: "TXID")
                copyRow(label: "Origin", shown: "\(Fmt.shortTxid(file.originTxid))_\(file.originVout)",
                        full: "\(file.originTxid)_\(file.originVout)", what: "Origin outpoint")
                if !file.sentLabel {
                    copyRow(label: "Current UTXO", shown: "\(Fmt.shortTxid(file.currentTxid))_\(file.currentVout)",
                            full: "\(file.currentTxid)_\(file.currentVout)", what: "Current outpoint")
                }
            } header: {
                Text("Transaction")
            } footer: {
                Text("Tap a row to copy the full value.")
            }

            Section {
                InlineAlert(kind: .success, text: copied)
                Button {
                    store.browserOpenRequest = file.originTxid
                } label: {
                    Label("Open in Browser", systemImage: "safari").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }   // v2.6.1: scheidingslijn over de hele breedte

                // v2.6.1 — losse knop: alléén de volledige TXID
                Button {
                    UIPasteboard.general.string = file.originTxid
                    copied = "TXID copied ✓"
                } label: {
                    Label("Copy TXID", systemImage: "number").frame(maxWidth: .infinity)
                }
                .buttonStyle(.ordnetOutline)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                Button {
                    var info = "TXID: \(file.originTxid)\nOrigin: \(file.originTxid)_\(file.originVout)"
                    if !file.sentLabel {
                        info += "\nCurrent outpoint: \(file.currentTxid)_\(file.currentVout)"
                    }
                    info += "\nContent-Type: \(file.contentType)\nSize: \(file.sizeLabel)"
                    UIPasteboard.general.string = info
                    copied = "All info copied ✓"
                } label: {
                    Label("Copy all info", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(.ordnetOutline)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                if !file.sentLabel {
                    NavigationLink {
                        SendOrdinalView(holding: asHolding)
                    } label: {
                        Label("Send (1Sat Ordinal)", systemImage: "arrow.up.right").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ordnetOutline)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }
            }
        }
        .ordnetBackground()
        .navigationTitle(file.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadTextPreview() }
    }

    /// v2.6.1 — one TAP copies the FULL value (the truncated text is display
    /// only); inline confirmation via the existing `copied` banner
    @ViewBuilder
    private func copyRow(label: String, shown: String, full: String, what: String) -> some View {
        Button {
            UIPasteboard.general.string = full
            copied = "\(what) copied ✓"
        } label: {
            KVRow(k: label, v: shown, mono: true)
        }
        .buttonStyle(.plain)
    }

    /// the existing 1-sat ordinal transfer flow does the rest (incl. the
    /// ownership check — sending from a non-active account explains itself)
    private var asHolding: Holding {
        Holding(kind: .inscription,
                name: file.displayName,
                district: nil,
                claimHeight: file.height ?? 0,
                status: "held",
                currentTxid: file.currentTxid,
                currentVout: file.currentVout,
                priceSat: nil)
    }

    private func loadTextPreview() async {
        let ct = file.contentType
        guard ct.hasPrefix("text/") || ct.contains("json"), !ct.hasPrefix("text/html"),
              file.size < 512 * 1024 else { return }
        guard let hex = try? await Api.txHex(file.originTxid),
              let ord = try? WalletEngine.shared.call("extractOrd", ["rawTxHex": hex, "vout": file.originVout]) as? [String: Any],
              let b64 = ord["dataB64"] as? String,
              let data = Data(base64Encoded: b64),
              let text = String(data: data, encoding: .utf8) else { return }
        textPreview = String(text.prefix(300))
    }
}
