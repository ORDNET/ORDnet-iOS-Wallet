import SwiftUI
import WebKit

/// The ORDnet Web3 Browser — native port of viewer.html/viewer.js:
/// address bar, app catalog start screen, on-chain content rendering,
/// history, security scanner and the window.ordplug provider bridge.
@MainActor
final class BrowserModel: NSObject, ObservableObject {
    /// what the webview is currently showing: on-chain content or a regular website
    enum BrowseMode { case web3, web2 }

    @Published var addressText = ""
    @Published var displayName = ""
    @Published var loading = false
    @Published var error = ""
    @Published var securityLevel: Int? = nil
    @Published var showingContent = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var mode: BrowseMode = .web3

    private(set) var history: [String] = []
    private(set) var historyIndex = -1
    var pendingFragment = ""

    weak var store: WalletStore?
    let webView: WKWebView
    private let schemeHandler = Web3SchemeHandler()

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: Web3.scheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        super.init()

        let ucc = config.userContentController
        ucc.add(ScriptBridge(model: self), name: "ordnetNavigate")
        ucc.add(ScriptBridge(model: self), name: "ordplug")
        ucc.add(ScriptBridge(model: self), name: "brc100")
        // click-interceptor + provider are injected into every rendered page
        ucc.addUserScript(WKUserScript(source: Web3.interceptorScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: OrdplugProvider.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // v2.4 — BRC-100: the key-free window.CWI shim, injected at document
        // start so WalletClient('auto') detects this wallet (first-priority
        // substrate). The ORDnet provider above stays untouched NEXT to it.
        if let url = Bundle.main.url(forResource: "brc100-shim", withExtension: "js"),
           let src = try? String(contentsOf: url, encoding: .utf8) {
            ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    /// weak bridge so the WKUserContentController doesn't retain-cycle the model
    private final class ScriptBridge: NSObject, WKScriptMessageHandler {
        weak var model: BrowserModel?
        init(model: BrowserModel) { self.model = model }
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let model else { return }
            if message.name == "ordnetNavigate", let body = message.body as? [String: Any],
               let target = body["target"] as? String {
                model.pendingFragment = (body["fragment"] as? String) ?? ""
                model.addressText = target
                Task { await model.load(target) }
            } else if message.name == "ordplug", let body = message.body as? [String: Any] {
                model.handleProviderMessage(body)
            } else if message.name == "brc100", let body = message.body as? [String: Any] {
                model.handleBrc100Message(body)
            }
        }
    }

    // MARK: navigation

    /// classify what the user typed: on-chain (.web3/TXID), a regular web2 URL,
    /// or free text (routed to a search engine — normal browser behaviour)
    private func classify(_ q: String) -> (isWeb3: Bool, url: URL?) {
        if Web3.isValidTxid(q) || Web3.hasWeb3TLD(q) { return (true, nil) }
        let lower = q.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://"), let u = URL(string: q) {
            return (false, u)
        }
        // bare domain like ordnet.io or ordnet.io/path (no spaces, has a dot)
        if !q.contains(" "), q.contains("."),
           q.range(of: "^[a-z0-9][a-z0-9.-]*\\.[a-z]{2,}(/.*)?$", options: [.regularExpression, .caseInsensitive]) != nil,
           let u = URL(string: "https://\(q)") {
            return (false, u)
        }
        // free text -> search
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        return (false, URL(string: "https://duckduckgo.com/?q=\(enc)"))
    }

    func load(_ input: String, addToHistory: Bool = true) async {
        let q = input.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true
        error = ""

        let (isWeb3, web2URL) = classify(q)
        if addToHistory {
            history = Array(history.prefix(historyIndex + 1))
            history.append(q)
            historyIndex = history.count - 1
        }

        if isWeb3 {
            do {
                let (txid, content) = try await Web3.load(input: q)
                mode = .web3
                displayName = q
                addressText = q
                render(content, txid: txid)
            } catch {
                self.error = error.localizedDescription
                securityLevel = nil
                if addToHistory {   // failed load shouldn't pollute history
                    history.removeLast()
                    historyIndex = history.count - 1
                }
            }
        } else if let url = web2URL {
            mode = .web2
            showingContent = true
            displayName = url.host ?? q
            addressText = q
            securityLevel = url.scheme == "https" ? 0 : 1
            webView.load(URLRequest(url: url))
        }
        loading = false
        updateNavState()
    }

    private func updateNavState() {
        canGoBack = (mode == .web2 && webView.canGoBack) || historyIndex > 0
        canGoForward = (mode == .web2 && webView.canGoForward) || historyIndex < history.count - 1
    }

    func goBack() {
        // inside a web2 site, use the webview's own history first
        if mode == .web2, webView.canGoBack {
            webView.goBack()
            return
        }
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        Task { await load(history[historyIndex], addToHistory: false) }
    }
    func goForward() {
        if mode == .web2, webView.canGoForward {
            webView.goForward()
            return
        }
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        Task { await load(history[historyIndex], addToHistory: false) }
    }
    func goHome() {
        showingContent = false
        addressText = ""
        displayName = ""
        securityLevel = nil
        mode = .web3
        webView.loadHTMLString("", baseURL: nil)
    }

    private func render(_ content: Web3.Content, txid: String) {
        showingContent = true
        let base = URL(string: "\(Web3.scheme)://ord/\(txid)_0/")
        if content.isHTML {
            let html = String(data: content.data, encoding: .utf8) ?? ""
            securityLevel = (try? WalletEngine.shared.int("scanSecurity", ["html": html])) ?? 0
            webView.loadHTMLString(Web3.preprocess(html: html), baseURL: base)
        } else {
            securityLevel = 0
            let b64 = content.data.base64EncodedString()
            let ct = content.contentType
            var body: String
            if ct.hasPrefix("image/") {
                body = "<img src=\"data:\(ct);base64,\(b64)\" style=\"max-width:100%;max-height:100vh;object-fit:contain\"/>"
            } else if ct.hasPrefix("video/") {
                body = "<video controls autoplay playsinline style=\"max-width:100%;max-height:100vh\"><source src=\"data:\(ct);base64,\(b64)\" type=\"\(ct)\"></video>"
            } else if ct.hasPrefix("audio/") {
                body = "<audio controls autoplay style=\"width:90%\"><source src=\"data:\(ct);base64,\(b64)\" type=\"\(ct)\"></audio>"
            } else {
                let text = String(data: content.data, encoding: .utf8) ?? "(binary content, \(content.data.count) bytes)"
                let esc = text
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                body = "<pre style=\"white-space:pre-wrap;word-wrap:break-word;padding:16px;font-family:monospace;color:#eee\">\(esc)</pre>"
            }
            let page = "<html><head><meta name=viewport content=\"width=device-width,initial-scale=1\"></head><body style=\"margin:0;display:flex;justify-content:center;align-items:center;min-height:100vh;background:#111\">\(body)</body></html>"
            webView.loadHTMLString(page, baseURL: base)
        }
        // scroll to a pending fragment after load
        if !pendingFragment.isEmpty {
            let frag = pendingFragment
            pendingFragment = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                let js = """
                (function(){ try{ var id=decodeURIComponent('\(frag)'.substring(1));
                var el=document.getElementById(id)||document.querySelector('[name="'+id+'"]');
                if(el) el.scrollIntoView({behavior:'smooth',block:'start'}); }catch(e){} })();
                """
                self?.webView.evaluateJavaScript(js)
            }
        }
    }

    // MARK: window.ordplug provider

    var currentOrigin: String {
        if mode == .web2, let url = webView.url, let host = url.host {
            return "\(url.scheme ?? "https")://\(host)"
        }
        return displayName.isEmpty ? "web3://unknown" : "web3://\(displayName.lowercased())"
    }

    func handleProviderMessage(_ body: [String: Any]) {
        guard let store,
              let id = body["id"] as? String,
              let method = body["method"] as? String else { return }
        let params = body["params"] as? [String: Any] ?? [:]
        let origin = currentOrigin
        let request = ProviderRequest(id: id, method: method, params: params, origin: origin)

        // read methods skip the approval sheet when the origin is already connected
        let readMethods = ["connect", "getAddress", "getPublicKey", "getBalance"]
        if readMethods.contains(method), store.isConnected(origin) {
            Task {
                do {
                    let result = try await OrdplugProvider.performRead(method: method, store: store)
                    deliver(id: id, ok: true, result: result, error: nil)
                } catch {
                    deliver(id: id, ok: false, result: nil, error: error.localizedDescription)
                }
            }
            return
        }
        OrdplugProvider.pendingDelivery[id] = { [weak self] ok, result, err in
            self?.deliver(id: id, ok: ok, result: result, error: err)
        }
        store.pendingProviderRequest = request
    }

    // MARK: BRC-100 bridge (v2.4)

    func handleBrc100Message(_ body: [String: Any]) {
        guard let id = body["id"] as? String, let method = body["method"] as? String else { return }
        let argsJson = body["args"] as? String ?? "{}"
        let originator = body["originator"] as? String ?? ""
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Brc100.handle(method: method, argsJson: argsJson, originator: originator, store: self.store)
                self.deliverBrc100(id: id, ok: true, result: result, error: nil)
            } catch let e as Brc100.Err {
                self.deliverBrc100(id: id, ok: false, result: nil, error: e)
            } catch {
                self.deliverBrc100(id: id, ok: false, result: nil,
                                   error: Brc100.Err(name: "WERR_UNKNOWN", code: 1, message: error.localizedDescription))
            }
        }
    }

    /// ok:true resolves; ok:false REJECTS in the page with a WERR_* error —
    /// never a resolved error-object (BRC-100 error contract)
    func deliverBrc100(id: String, ok: Bool, result: [String: Any]?, error: Brc100.Err?) {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = ["name": error.name, "code": error.code, "message": error.message] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__brc100Deliver(\(json));")
    }

    func deliver(id: String, ok: Bool, result: [String: Any]?, error: String?) {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__ordplugDeliver(\(json));")
    }
}

// MARK: - WKNavigationDelegate (web2: keep the address bar + nav state in sync)

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if mode == .web2 { loading = true }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard mode == .web2, let url = webView.url, url.scheme != Web3.scheme else {
            updateNavState()
            return
        }
        loading = false
        error = ""
        displayName = url.host ?? displayName
        addressText = url.absoluteString
        securityLevel = url.scheme == "https" ? 0 : 1
        updateNavState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError err: Error) {
        guard mode == .web2 else { return }
        loading = false
        let ns = err as NSError
        if ns.code != NSURLErrorCancelled {
            error = err.localizedDescription
        }
        updateNavState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError err: Error) {
        guard mode == .web2 else { return }
        loading = false
        updateNavState()
    }
}

// MARK: - SwiftUI wrapper

struct Web3WebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @EnvironmentObject private var store: WalletStore
    @StateObject private var model = BrowserModel()
    @Environment(\.colorScheme) private var scheme

    /// identical card for every app — fixed height so all tiles line up
    private func catalogCard(_ app: CatalogApp) -> some View {
        VStack(spacing: 8) {
            Image(systemName: app.icon)
                .font(.title3)
                .frame(height: 24)
            Text(app.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .frame(height: 82)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.bgPrimary(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.primary, lineWidth: 1.5))
        .foregroundStyle(Color.primary)
    }

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            if model.loading { ProgressView().padding(.vertical, 2) }
            if !model.error.isEmpty {
                InlineAlert(kind: .error, text: model.error).padding(.horizontal, 10).padding(.top, 6)
            }
            if model.showingContent {
                Web3WebView(webView: model.webView)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                startScreen
            }
        }
        .ordnetBackground()
        .navigationTitle("ORDnet Browser")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.store = store
            consumeBrowserRequest()   // tab may mount AFTER the request was set
        }
        // v2.3 — ORD/ner asks us to render a TXID
        .onChange(of: store.browserOpenRequest) { _, _ in
            consumeBrowserRequest()
        }
    }

    private func consumeBrowserRequest() {
        guard let q = store.browserOpenRequest else { return }
        store.browserOpenRequest = nil
        model.addressText = q
        Task { await model.load(q) }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
            Button { model.goHome() } label: { Image(systemName: "house") }

            TextField("domain.web3, website or search", text: $model.addressText)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .onSubmit {
                    Task { await model.load(model.addressText) }
                }

            if let lvl = model.securityLevel {
                Image(systemName: securityIcon(lvl))
                    .foregroundStyle(securityColor(lvl))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func securityIcon(_ l: Int) -> String {
        switch l {
        case 0: return "lock.fill"
        case 1: return "lock.open"
        case 2: return "exclamationmark.triangle"
        case 3: return "exclamationmark.triangle.fill"
        default: return "xmark.octagon.fill"
        }
    }
    private func securityColor(_ l: Int) -> Color {
        switch l {
        case 0: return Theme.statusGreen
        case 1: return .secondary
        case 2: return Theme.statusYellow
        default: return Theme.statusRed
        }
    }

    // MARK: start screen — port of the app catalog

    private struct CatalogApp: Identifiable {
        var name: String
        var icon: String
        var q: String
        var id: String { name }
    }
    /// the full ORDnet ecosystem (order of ordnet.io, browser omitted — you're in it),
    /// all linking to the .io addresses
    private let apps: [CatalogApp] = [
        .init(name: "ORD/domains", icon: "tag", q: "https://domains.ordnet.io"),
        .init(name: "ORD/app", icon: "icloud.and.arrow.up", q: "https://app.ordnet.io"),
        .init(name: "ORD/mail", icon: "envelope", q: "https://mail.ordnet.io"),
        .init(name: "ORD/search", icon: "magnifyingglass", q: "https://search.ordnet.io"),
        .init(name: "ORD/whois", icon: "person.text.rectangle", q: "https://whois.ordnet.io"),
        .init(name: "ORD/templates", icon: "square.grid.2x2", q: "https://templates.ordnet.io"),
        .init(name: "ORD/nodes", icon: "point.3.connected.trianglepath.dotted", q: "https://nodes.ordnet.io"),
        .init(name: "ORD/api", icon: "curlybraces", q: "https://api.ordnet.io"),
        // ORD/swap bewust NIET in de iOS-catalogus: crypto-exchange-links vallen onder App Review 3.1.5(b)/MiCA
        .init(name: "ORD/clawd", icon: "fossil.shell", q: "https://clawdbot.ordnet.io"),
        .init(name: "ORD/mcp", icon: "server.rack", q: "https://mcp.ordnet.io")
    ]

    private var startScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 10) {
                    OrdplugLogo(size: 56)
                    Text("Browse web3 and the regular web")
                        .font(.headline)
                    Text("Enter a .web3 domain or TXID for on-chain content, a normal website (e.g. ordnet.io), or just search.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)

                Text("ORDnet")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(apps) { app in
                        Button {
                            model.addressText = app.q
                            Task { await model.load(app.q) }
                        } label: {
                            catalogCard(app)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
    }
}
