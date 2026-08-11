import Foundation
import WebKit

/// Native port of the extension's viewer engine + service-worker blockchain
/// router (sw.js). Instead of a service worker, a WKURLSchemeHandler serves
/// `ordweb3://ord/<domain>.<tld>[/subpath]` and `ordweb3://ord/<txid>_<vout>`
/// straight from the chain (domains.ordnet.io + WhatsOnChain), with an in-memory
/// cache — so internal links between .web3 pages work exactly like in Chrome.
enum Web3 {
    static let scheme = "ordweb3"
    static let supportedTLDs = ["web3","bitcoin","bsv","ordinal","sat","crypto","nft","x","sats","ord"]

    static func isValidTxid(_ s: String) -> Bool {
        s.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil
    }
    /// true only when the host's LAST label is a web3 TLD. A contains-check
    /// would misfire: "api.ordnet.io" contains ".ord" but is a normal website.
    static func hasWeb3TLD(_ s: String) -> Bool {
        var host = s.lowercased()
        if let r = host.range(of: "://") { host = String(host[r.upperBound...]) }
        host = host.split(separator: "/").first.map(String.init) ?? host
        host = host.split(separator: "?").first.map(String.init) ?? host
        host = host.split(separator: "#").first.map(String.init) ?? host
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last else { return false }
        return supportedTLDs.contains(String(tld))
    }

    struct Content {
        var contentType: String
        var data: Data
        var isHTML: Bool { contentType.hasPrefix("text/html") }
    }

    /// resolve + fetch + parse — port of loadContent()
    static func load(input: String) async throws -> (txid: String, content: Content) {
        var txid = input.trimmingCharacters(in: .whitespaces)
        if !isValidTxid(txid) {
            guard hasWeb3TLD(txid) else {
                throw Api.ApiError.http(0, "Enter a valid .web3 domain or 64-character TXID")
            }
            txid = try await Api.resolve(name: txid.lowercased())
        }
        let hex = try await Api.txHex(txid)
        guard let ord = try WalletEngine.shared.call("extractOrd", ["rawTxHex": hex]) as? [String: Any],
              let ct = ord["ct"] as? String,
              let b64 = ord["dataB64"] as? String,
              let data = Data(base64Encoded: b64) else {
            throw Api.ApiError.http(0, "No 1SatOrdinals inscription found")
        }
        return (txid, Content(contentType: ct, data: data))
    }

    /// fetch a specific output — used by the scheme handler for /txid_N
    static func loadOutput(txid: String, vout: Int) async throws -> Content {
        let hex = try await Api.txHex(txid)
        guard let ord = try WalletEngine.shared.call("extractOrd", ["rawTxHex": hex, "vout": vout]) as? [String: Any],
              let ct = ord["ct"] as? String,
              let b64 = ord["dataB64"] as? String,
              let data = Data(base64Encoded: b64) else {
            throw Api.ApiError.http(0, "no inscription")
        }
        return Content(contentType: ct, data: data)
    }

    /// HTML preprocessor — port of preprocessHtml(): rewrites protocol-relative
    /// web3 links so they resolve through the scheme handler.
    static func preprocess(html: String) -> String {
        let tlds = supportedTLDs.joined(separator: "|")
        let pattern = "(href|src)=([\"'])//(([a-z0-9][a-z0-9-]*\\.)+(\(tlds))([\\/\\?][^\"']*)?)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return html }
        let range = NSRange(html.startIndex..., in: html)
        return re.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "$1=$2/$3")
    }

    /// click-interceptor injected into every rendered page (port of the inline
    /// script that viewer.js appended) — full-page web3/txid navigations are
    /// forwarded to the native browser via a script message.
    static var interceptorScript: String {
        let tlds = supportedTLDs.joined(separator: "|")
        return """
        (function(){
          var tldPattern=new RegExp("^/?(([a-z0-9][a-z0-9-]*\\\\.)+(\(tlds)))(/[^?#]*)?(\\\\?[^#]*)?(#.*)?$","i");
          var txidPattern=/^\\/?([a-f0-9]{64})(?:_(\\d+))?(#.*)?$/i;
          var fragmentPattern=/^\\/?(#.+)$/;
          function scrollToFragment(frag){
            try{
              var id=decodeURIComponent(frag.substring(1));
              var el=document.getElementById(id)||document.querySelector('[name="'+id+'"]');
              if(el){el.scrollIntoView({behavior:"smooth",block:"start"});}
            }catch(err){}
          }
          document.addEventListener("click",function(e){
            var link=e.target.closest("a[href]");
            if(!link)return;
            var href=link.getAttribute("href");
            if(!href)return;
            var fragOnly=href.match(fragmentPattern);
            if(fragOnly){ e.preventDefault(); e.stopPropagation(); scrollToFragment(fragOnly[1]); return; }
            var domainMatch=href.match(tldPattern);
            var txidMatch=href.match(txidPattern);
            if(domainMatch||txidMatch){
              e.preventDefault(); e.stopPropagation();
              var target,frag;
              if(domainMatch){ target=domainMatch[1]+(domainMatch[4]||""); frag=domainMatch[6]||""; }
              else { target=txidMatch[1]; frag=txidMatch[3]||""; }
              window.webkit.messageHandlers.ordnetNavigate.postMessage({target:target,fragment:frag});
            }
          },true);
        })();
        """
    }
}

/// The blockchain router: serves web3 content to the WKWebView for subresource
/// requests and iframe navigations, replacing sw.js one-to-one (incl. cache
/// semantics — tx content is immutable).
final class Web3SchemeHandler: NSObject, WKURLSchemeHandler {
    private var cache: [String: (String, Data)] = [:]
    private var cacheOrder: [String] = []          // FIFO eviction
    private var cacheBytes = 0
    private static let cacheMaxBytes = 64 * 1024 * 1024   // 64MB total
    private static let cacheMaxEntry = 16 * 1024 * 1024   // don't cache single items > 16MB

    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// tasks WebKit has stopped — responding to these throws an ObjC exception
    /// past that point, so every respond call is guarded against this set
    private var stoppedTasks: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        let url = urlSchemeTask.request.url
        stoppedTasks.remove(id)
        tasks[id] = Task { [weak self] in
            await self?.handle(urlSchemeTask, url: url, id: id)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        stoppedTasks.insert(id)
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    @MainActor
    private func handle(_ task: WKURLSchemeTask, url: URL?, id: ObjectIdentifier) async {
        defer {
            tasks[id] = nil
            stoppedTasks.remove(id)
        }
        guard let url else { return fail(task, "bad url") }
        let path = url.path

        // /<txid>_<vout>
        if let m = path.range(of: "/([a-f0-9]{64})_(\\d+)$", options: [.regularExpression, .caseInsensitive]) {
            let comp = String(path[m]).dropFirst().split(separator: "_")
            let txid = String(comp[0]).lowercased()
            let vout = Int(comp[1]) ?? 0
            return await serve(task, key: "\(txid)_\(vout)") {
                let c = try await Web3.loadOutput(txid: txid, vout: vout)
                return (c.contentType, c.data)
            }
        }

        // /<domain>.<tld>[/subpath]
        let tlds = Web3.supportedTLDs.joined(separator: "|")
        if let m = path.range(of: "^/([a-z0-9][a-z0-9.-]*\\.(\(tlds)))(/[^?]*)?", options: [.regularExpression, .caseInsensitive]) {
            let matched = String(path[m]).dropFirst()   // domain[/subpath]
            return await serve(task, key: "d_\(matched)") {
                let txid = try await Api.resolve(name: String(matched))
                let hex = try await Api.txHex(txid)
                guard let ord = try WalletEngine.shared.call("extractOrd", ["rawTxHex": hex]) as? [String: Any],
                      let ct = ord["ct"] as? String,
                      let b64 = ord["dataB64"] as? String,
                      let data = Data(base64Encoded: b64) else {
                    throw Api.ApiError.http(404, "no inscription")
                }
                return (ct, data)
            }
        }

        fail(task, "not a web3 path")
    }

    @MainActor
    private func serve(_ task: WKURLSchemeTask, key: String,
                       fetch: () async throws -> (String, Data)) async {
        if let (ct, data) = cache[key] {
            respond(task, contentType: ct, data: data)
            return
        }
        do {
            let (ct, data) = try await fetch()
            cachePut(key, ct, data)
            respond(task, contentType: ct, data: data)
        } catch {
            let msg = "Error: \(error.localizedDescription)"
            respond(task, contentType: "text/plain", data: Data(msg.utf8), status: 404)
        }
    }

    /// bounded cache: skip oversized items, evict oldest until under the cap
    @MainActor
    private func cachePut(_ key: String, _ ct: String, _ data: Data) {
        guard data.count <= Self.cacheMaxEntry, cache[key] == nil else { return }
        cache[key] = (ct, data)
        cacheOrder.append(key)
        cacheBytes += data.count
        while cacheBytes > Self.cacheMaxBytes, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            if let (_, evicted) = cache.removeValue(forKey: oldest) {
                cacheBytes -= evicted.count
            }
        }
    }

    @MainActor
    private func respond(_ task: WKURLSchemeTask, contentType: String, data: Data, status: Int = 200) {
        // never touch a task WebKit has stopped or whose fetch was cancelled —
        // didReceive/didFinish throw ObjC exceptions past that point
        let id = ObjectIdentifier(task)
        guard !stoppedTasks.contains(id), !Task.isCancelled else { return }
        guard let url = task.request.url else { return }
        let headers = ["Content-Type": contentType, "Cache-Control": "public,max-age=31536000"]
        guard let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    @MainActor
    private func fail(_ task: WKURLSchemeTask, _ message: String) {
        respond(task, contentType: "text/plain", data: Data("Error: \(message)".utf8), status: 404)
    }
}
