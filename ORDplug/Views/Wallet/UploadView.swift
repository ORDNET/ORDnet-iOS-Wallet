import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Upload & inscribe — fifth tab. Pick an image, text or HTML file and inscribe
/// it as a 1Sat Ordinal on the active wallet. The transaction is built by the
/// same engine call the ORDnet HTML tools use (identical envelope, ORDnet.io
/// OP_RETURN, service fees, fee formula and 100MB limit). Below the tool:
/// every TXID inscribed via this app with this wallet.
struct UploadView: View {
    @EnvironmentObject private var store: WalletStore

    @State private var fileData: Data?
    @State private var filename = ""
    @State private var contentType = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var error = ""
    @State private var success = ""
    /// v2.6.1 — de TXID van de laatste geslaagde inscribe. Eigen state, want
    /// de succesmelding stond vóór deze fix in de bestandsselectie-sectie die
    /// direct na succes wordt geleegd (fileData = nil) — de melding bestond
    /// dus wel maar was nooit zichtbaar.
    @State private var lastTxid = ""
    @State private var txidCopied = ""
    @State private var busy = false

    // type-it-directly editor
    enum TypedKind: String, CaseIterable, Identifiable {
        case text = "Text"
        case html = "HTML"
        var id: String { rawValue }
        var mime: String { self == .html ? "text/html" : "text/plain" }
        var ext: String { self == .html ? "html" : "txt" }
    }
    @State private var typedText = ""
    @State private var typedKind: TypedKind = .text
    @FocusState private var editorFocused: Bool
    @State private var staged = ""            // inline feedback after staging typed content

    // image compression (JPEG/PNG sources)
    @State private var originalImageData: Data?
    @State private var originalImageCT = ""
    @State private var quality: Double = 1.0   // 1.0 = original

    private static let maxSize = 100 * 1024 * 1024   // 100MB — parity with the ORDnet tools

    private var minerFee: Int {
        (try? store.engine.fees(inscribeBytes: fileData?.count ?? 0).inscribeMinerFee) ?? 0
    }
    private var serviceFees: Int {
        (try? store.engine.fees().totalServiceFees) ?? 3996
    }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            Section("Pick a file to inscribe") {
                HStack(spacing: 10) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                            .ordnetOutlineLabel()
                    }
                    .buttonStyle(.plain)
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Files", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ordnetOutline)
                }
                .listRowSeparator(.hidden)
                Text("Supported: images (JPEG, PNG, GIF, WebP), text files and HTML. Content is written permanently on-chain as a 1Sat Ordinal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // v2.6.2 — "Selected" (+ inscribe-knop) staat DIRECT onder de
            // bestandskeuze in plaats van onder het tekst/HTML-kader: de
            // foto-kies-flow is de veelvoorkomende route. "Upload this text"
            // scrollt via het bestaande selectedSection-anker hierheen.
            if let data = fileData {
                Section("Selected") {
                    preview(data)
                    if let orig = originalImageData {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Compression").font(.footnote)
                                Spacer()
                                Text(quality >= 0.999
                                     ? "Original · \(sizeLabel(orig.count))"
                                     : "\(Int(quality * 100))% · \(sizeLabel(orig.count)) → \(sizeLabel(data.count))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $quality, in: 0.1...1.0, step: 0.05)
                                .onChange(of: quality) { applyCompression() }
                        }
                        .padding(.vertical, 2)
                    }
                    KVRow(k: "File", v: filename)
                    KVRow(k: "Content type", v: contentType)
                    KVRow(k: "Size", v: sizeLabel(data.count))
                    KVRow(k: "Miner fee", v: "~\(Fmt.bsv(minerFee)) BSV")
                    KVRow(k: "Service fee", v: "\(Fmt.bsv(serviceFees)) BSV")
                    KVRow(k: "Inscribe to", v: Fmt.shortAddress(store.address), mono: true)
                }
                .id("selectedSection")
                Section {
                    InlineAlert(kind: .error, text: error)
                    InlineAlert(kind: .success, text: success)
                    Button {
                        inscribe()
                    } label: {
                        if busy { ProgressView().frame(maxWidth: .infinity) }
                        else { Label("Inscribe on-chain", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    Button("Clear selection") { clearSelection() }
                        .disabled(busy)
                }
            } else if !error.isEmpty {
                Section { InlineAlert(kind: .error, text: error) }
            }

            Section {
                TextEditor(text: $typedText)
                    .font(.callout.monospaced())
                    .frame(minHeight: 140)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($editorFocused)
                Picker("Inscribe as", selection: $typedKind) {
                    ForEach(TypedKind.allCases) { k in Text(k.rawValue).tag(k) }
                }
                .pickerStyle(.segmented)
                if !typedText.isEmpty {
                    let bytes = typedText.utf8.count
                    let fee = (try? store.engine.fees(inscribeBytes: bytes).inscribeMinerFee) ?? 0
                    Text("\(sizeLabel(bytes)) · \(typedKind.mime) · ~\(Fmt.bsv(fee + serviceFees)) BSV total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                InlineAlert(kind: .success, text: staged)
                Button {
                    editorFocused = false          // dismiss the keyboard first
                    useTypedText()
                    withAnimation {
                        proxy.scrollTo("selectedSection", anchor: .top)
                    }
                } label: {
                    Label("Upload this \(typedKind == .html ? "HTML" : "text")", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.ordnetOutline)
                .disabled(typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Or type it directly")
            } footer: {
                Text("The Text/HTML switch sets the content-type in the ordinal envelope: text/plain renders as plain text, text/html as a live on-chain page.")
            }

            // v2.6.1 — persistent succes-sectie: blijft staan NA het legen van
            // de selectie, met volledige TXID (één tik = kopiëren) en de
            // verwijzing naar het ORD/ner-tab
            if !lastTxid.isEmpty {
                Section("Inscribed successfully ✓") {
                    InlineAlert(kind: .success, text: txidCopied.isEmpty ? "Your file is inscribed on-chain." : txidCopied)
                    Button {
                        UIPasteboard.general.string = lastTxid
                        txidCopied = "TXID copied ✓"
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TXID (tap to copy)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(lastTxid)
                                .font(.caption.monospaced())
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                    Label("You can find this inscription back in the ORD/ner tab — browse, copy and send it from there.", systemImage: "folder")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // v2.3 — the "Inscribed with this wallet" list moved to ORD/ner,
            // where every file is browsable, copyable and sendable
            Section {
                Label("Your inscribed files now live in the ORD/ner tab — browse, copy TX info and send them from there.", systemImage: "folder")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .ordnetBackground()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Upload & Inscribe")
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            loadPhoto(item)
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.image, .plainText, .utf8PlainText, .html, .text],
                      allowsMultipleSelection: false) { result in
            handleFileImport(result)
        }
        .task { store.loadInscriptions() }
        }   // ScrollViewReader
    }

    // MARK: rows & preview

    @ViewBuilder
    private func preview(_ data: Data) -> some View {
        if contentType.hasPrefix("image/"), let img = UIImage(data: data) {
            HStack {
                Spacer()
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Spacer()
            }
        } else if contentType.hasPrefix("text/") {
            let text = String(data: data.prefix(600), encoding: .utf8) ?? ""
            Text(text + (data.count > 600 ? "…" : ""))
                .font(.caption.monospaced())
                .lineLimit(10)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: file selection

    private func loadPhoto(_ item: PhotosPickerItem) {
        error = ""; success = ""; lastTxid = ""; txidCopied = ""
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                error = "Could not read the selected photo."
                return
            }
            guard data.count <= Self.maxSize else {
                error = "File too large! Maximum size is 100MB."
                return
            }
            let ct = sniffImageType(data) ?? "image/jpeg"
            fileData = data
            contentType = ct
            let ext = ct.split(separator: "/").last.map(String.init) ?? "img"
            filename = "photo-\(Int(Date().timeIntervalSince1970)).\(ext == "jpeg" ? "jpg" : ext)"
            photoItem = nil
            setupCompression(data: data, contentType: ct)
        }
    }

    /// compression is offered for JPEG/PNG sources (GIF/WebP stay untouched —
    /// recompressing would break animation/alpha)
    private func setupCompression(data: Data, contentType ct: String) {
        staged = ""
        if ct == "image/jpeg" || ct == "image/png" {
            originalImageData = data
            originalImageCT = ct
            quality = 1.0
        } else {
            originalImageData = nil
            originalImageCT = ""
        }
    }

    /// re-encode the ORIGINAL image at the chosen quality; never let
    /// "compression" make the file bigger than the original
    private func applyCompression() {
        guard let orig = originalImageData else { return }
        if quality >= 0.999 {
            fileData = orig
            contentType = originalImageCT
            syncFilenameExtension(to: originalImageCT)
            return
        }
        guard let img = UIImage(data: orig),
              let jpeg = img.jpegData(compressionQuality: quality) else { return }
        if jpeg.count < orig.count {
            fileData = jpeg
            contentType = "image/jpeg"
            syncFilenameExtension(to: "image/jpeg")
        } else {
            fileData = orig
            contentType = originalImageCT
            syncFilenameExtension(to: originalImageCT)
        }
    }

    private func syncFilenameExtension(to ct: String) {
        let ext = ct == "image/png" ? "png" : ct == "image/jpeg" ? "jpg" : nil
        guard let ext, let dot = filename.lastIndex(of: ".") else { return }
        filename = String(filename[..<dot]) + ".\(ext)"
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        error = ""; success = ""; lastTxid = ""; txidCopied = ""
        switch result {
        case .failure(let err):
            error = err.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                error = "Could not read the selected file."
                return
            }
            guard data.count <= Self.maxSize else {
                error = "File too large! Maximum size is 100MB."
                return
            }
            fileData = data
            filename = url.lastPathComponent
            contentType = mimeType(for: url, data: data)
            setupCompression(data: data, contentType: contentType)
        }
    }

    private func sniffImageType(_ d: Data) -> String? {
        if d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if d.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if d.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if d.count > 12, d.subdata(in: 8..<12) == Data("WEBP".utf8) { return "image/webp" }
        return nil
    }

    private func mimeType(for url: URL, data: Data) -> String {
        if let img = sniffImageType(data) { return img }
        if let ut = UTType(filenameExtension: url.pathExtension), let mime = ut.preferredMIMEType {
            return mime
        }
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "txt", "md": return "text/plain"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        default: return "text/plain"
        }
    }

    private func sizeLabel(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) bytes" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.2f MB", Double(bytes) / 1024 / 1024)
    }

    private func clearSelection() {
        fileData = nil
        filename = ""
        contentType = ""
        error = ""
        success = ""
        staged = ""
        originalImageData = nil
        originalImageCT = ""
        quality = 1.0
    }

    /// stage the typed text/HTML as the inscription selection — same flow as a picked file
    private func useTypedText() {
        error = ""; success = ""; lastTxid = ""; txidCopied = ""
        let text = typedText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let data = Data(text.utf8)
        guard data.count <= Self.maxSize else {
            error = "Content too large! Maximum size is 100MB."
            return
        }
        fileData = data
        contentType = typedKind.mime
        filename = "inscription-\(Int(Date().timeIntervalSince1970)).\(typedKind.ext)"
        originalImageData = nil
        originalImageCT = ""
        staged = "Staged below ✓ — review the details and tap Inscribe on-chain."
    }

    // MARK: inscribe

    private func inscribe() {
        guard let data = fileData else { return }
        error = ""; success = ""; busy = true
        Task {
            do {
                let txid = try await store.inscribe(contentType: contentType,
                                                    dataB64: data.base64EncodedString())
                store.recordInscription(txid: txid, contentType: contentType,
                                        filename: filename, bytes: data.count)
                success = "Inscribed! TXID: \(txid)"
                lastTxid = txid          // v2.6.1: zichtbaar in de succes-sectie
                txidCopied = ""
                fileData = nil
                filename = ""
                contentType = ""
                staged = ""
                originalImageData = nil
                originalImageCT = ""
                quality = 1.0
                await store.refreshBalance()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
