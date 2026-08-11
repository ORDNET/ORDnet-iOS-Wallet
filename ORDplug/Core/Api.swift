import Foundation

/// Network layer — the same three services the extension talks to:
/// WhatsOnChain (chain data + broadcast), bsvmap.io (ORDnet V30 indexer +
/// marketplace) and domains.ordnet.io (the ORDnet v2 domain registry).
enum Api {
    static let wocBase = "https://api.whatsonchain.com/v1/bsv/main"
    static let holdingsBase = "https://bsvmap.io/api"
    // v2.0 — domain management + resolver on the ORDnet v2 platform,
    // main domain since the cutover (one constant, one switch)
    static let namesBase = "https://domains.ordnet.io"
    // v2.1 — OpNS index (bare names, tree 0). Endpoints verified against the
    // live API on 03-08-2026: /names?q= (search, default match=exact,
    // fallback:true = prefix fallback), /name/<name>, /owner/<address>.
    static let opnsBase = "https://search.ordnet.io/api/opns"
    // v2.2 — SNS resolver (signed answers, resolver v1.3). Endpoints verified
    // live on 03-08-2026: /resolve/<name|mailbox@name>, /pubkey, /health.
    static let snsBase = "https://sns.ordnet.io"
    // v2.3 — ORD/ner file index (1Sat/GorillaPool, same source as ord-app v42).
    // Endpoint verified live 03-08-2026: /api/txos/address/<addr>/unspent
    static let ordnerBase = "https://ordinals.gorillapool.io/api"

    enum ApiError: LocalizedError {
        case http(Int, String)
        case unreachable(String)
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .http(let code, let body):
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "HTTP \(code)" : trimmed
            case .unreachable(let what): return "\(what) is unreachable — check your connection."
            case .rateLimited: return "Rate-limited by WhatsOnChain (429) — wait a few seconds and try again."
            }
        }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    // MARK: - primitives

    static func get(_ url: String) async throws -> (Int, Data) {
        guard let u = URL(string: url) else { throw ApiError.http(0, "Bad URL") }
        let (data, resp) = try await session.data(from: u)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (code, data)
    }

    static func postJSON(_ url: String, body: [String: Any]) async throws -> (Int, Data) {
        guard let u = URL(string: url) else { throw ApiError.http(0, "Bad URL") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (code, data)
    }

    static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func jsonArray(_ data: Data) -> [[String: Any]]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    // MARK: - WhatsOnChain

    /// port of fetchUnspent(): confirmed endpoint first, plain unspent fallback
    static func rawUnspent(address: String) async throws -> [[String: Any]] {
        for path in ["/address/\(address)/confirmed/unspent", "/address/\(address)/unspent"] {
            if let (code, data) = try? await get(wocBase + path), code == 200 {
                var list: [[String: Any]] = jsonArray(data) ?? []
                if list.isEmpty, let obj = json(data), let inner = obj["result"] as? [[String: Any]] {
                    list = inner
                }
                list = list.filter { ($0["tx_hash"] as? String) != nil && !(($0["isSpentInMempoolTx"] as? Bool) ?? false) }
                if !list.isEmpty { return list }
            }
        }
        return []
    }

    static func balance(address: String) async throws -> Balance {
        let (code, data) = try await get(wocBase + "/address/\(address)/balance")
        guard code == 200, let j = json(data) else { throw ApiError.unreachable("WhatsOnChain") }
        return Balance(confirmed: j["confirmed"] as? Int ?? 0, unconfirmed: j["unconfirmed"] as? Int ?? 0)
    }

    static func history(address: String) async throws -> [HistoryTx] {
        let (code, data) = try await get(wocBase + "/address/\(address)/history")
        guard code == 200, let arr = jsonArray(data) else { throw ApiError.unreachable("WhatsOnChain") }
        var txs = arr.compactMap { d -> HistoryTx? in
            guard let h = d["tx_hash"] as? String else { return nil }
            return HistoryTx(txHash: h, height: d["height"] as? Int ?? 0)
        }
        // newest first; pending (height<=0) on top
        txs.sort { a, b in
            let ha = a.height > 0 ? a.height : Int(1e12), hb = b.height > 0 ? b.height : Int(1e12)
            return hb < ha
        }
        return txs
    }

    /// Raw tx-hex with in-memory cache + 429 retry/backoff (500ms → 1s → 2s → 4s),
    /// exactly like the extension's fetchTxHexRetry().
    private static var txHexCache: [String: String] = [:]
    private static var txHexOrder: [String] = []          // FIFO eviction
    private static var txHexBytes = 0
    private static let txHexMaxBytes = 64 * 1024 * 1024   // 64MB total
    private static let txHexMaxEntry = 16 * 1024 * 1024   // skip caching single txs > 16MB
    private static let cacheLock = NSLock()

    /// synchronous cache accessors — NSLock.lock()/unlock() may not be called
    /// directly from async contexts, withLock inside a sync helper is fine
    private static func cachedTxHex(_ txid: String) -> String? {
        cacheLock.withLock { txHexCache[txid] }
    }
    private static func storeTxHex(_ txid: String, _ hex: String) {
        cacheLock.withLock {
            guard hex.utf8.count <= txHexMaxEntry, txHexCache[txid] == nil else { return }
            txHexCache[txid] = hex
            txHexOrder.append(txid)
            txHexBytes += hex.utf8.count
            while txHexBytes > txHexMaxBytes, let oldest = txHexOrder.first {
                txHexOrder.removeFirst()
                if let evicted = txHexCache.removeValue(forKey: oldest) {
                    txHexBytes -= evicted.utf8.count
                }
            }
        }
    }

    static func txHex(_ txid: String) async throws -> String {
        if let hex = cachedTxHex(txid) { return hex }

        var delay: UInt64 = 500_000_000
        for _ in 0..<5 {
            let (code, data) = try await get(wocBase + "/tx/\(txid)/hex")
            if code == 200, let hex = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                storeTxHex(txid, hex)
                return hex
            }
            if code != 429 { throw ApiError.http(code, "Could not fetch the transaction. (HTTP \(code))") }
            try await Task.sleep(nanoseconds: delay)
            delay *= 2
        }
        throw ApiError.rateLimited
    }

    static func broadcast(rawtx: String) async throws -> String {
        let (code, data) = try await postJSON(wocBase + "/tx/raw", body: ["txhex": rawtx])
        let text = String(data: data, encoding: .utf8) ?? ""
        guard code == 200 else { throw ApiError.http(code, text) }
        return text.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func exchangeRate() async -> Double? {
        guard let (code, data) = try? await get(wocBase + "/exchangerate"), code == 200,
              let j = json(data) else { return nil }
        if let r = j["rate"] as? Double { return r }
        if let s = j["rate"] as? String { return Double(s) }
        return nil
    }

    // MARK: - bsvmap.io (holdings indexer + marketplace)

    static func holdings(address: String) async throws -> [Holding] {
        let (code, data) = try await get(holdingsBase + "/address/\(address)/holdings")
        guard code == 200, let j = json(data) else { throw ApiError.unreachable("the ORDnet indexer at bsvmap.io") }
        var out: [Holding] = []
        for d in (j["sns"] as? [[String: Any]] ?? []) {
            if let h = Holding.from(d, kind: .sns) { out.append(h) }
        }
        for d in (j["bsvmaps"] as? [[String: Any]] ?? []) {
            if let h = Holding.from(d, kind: .bsvmap) { out.append(h) }
        }
        return out
    }

    /// global listings registry — merged into holdings like mergeListings()
    static func listings() async -> [[String: Any]] {
        guard let (code, data) = try? await get(holdingsBase + "/listings"), code == 200,
              let j = json(data) else { return [] }
        return j["listings"] as? [[String: Any]] ?? []
    }

    static func districtState(_ district: Int) async -> [String: Any]? {
        guard let (code, data) = try? await get(holdingsBase + "/map/\(district)"), code == 200 else { return nil }
        return json(data)
    }

    static func postList(district: Int, body: [String: Any]) async throws {
        let (code, data) = try await postJSON(holdingsBase + "/map/\(district)/list", body: body)
        let j = json(data)
        guard code == 200 else { throw ApiError.http(code, j?["error"] as? String ?? "listing failed") }
    }

    static func postDelist(district: Int, body: [String: Any]) async throws {
        let (code, data) = try await postJSON(holdingsBase + "/map/\(district)/delist", body: body)
        guard code == 200, json(data) != nil else {
            throw ApiError.http(code, json(data)?["error"] as? String ?? "delist endpoint unavailable (\(code))")
        }
    }

    // MARK: - chain info (BRC-100 fase 1)

    /// current block height — GET /chain/info, field "blocks"
    /// (endpoint + field verified against the WhatsOnChain docs 04-08-2026)
    static func chainHeight() async throws -> Int {
        let (code, data) = try await get(wocBase + "/chain/info")
        guard code == 200, let j = json(data), let h = j["blocks"] as? Int else {
            throw ApiError.unreachable("WhatsOnChain")
        }
        return h
    }

    // MARK: - OpNS index (search.ordnet.io/api/opns)

    /// all OpNS names on an address — portfolio view, third holdings category.
    /// Throws on failure so the caller can degrade WITHOUT touching SNS/BSVmaps.
    static func opnsHoldings(address: String) async throws -> [Holding] {
        let (code, data) = try await get(opnsBase + "/owner/\(address)")
        guard code == 200, let j = json(data), (j["ok"] as? Bool) == true else {
            throw ApiError.unreachable("the OpNS index at search.ordnet.io")
        }
        return (j["results"] as? [[String: Any]] ?? []).compactMap { Holding.fromOpns($0) }
    }

    /// name lookup via /names?q= — the API defaults to match=exact and falls
    /// back to prefix with `fallback: true`. The fallback flag is passed
    /// through UNTOUCHED: a fallback answer is a DIFFERENT name than the user
    /// typed and must never be paid silently.
    static func opnsLookup(name: String) async throws -> (fallback: Bool, records: [OpnsRecord]) {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let (code, data) = try await get(opnsBase + "/names?q=\(enc)")
        guard code == 200, let j = json(data), (j["ok"] as? Bool) == true else {
            throw ApiError.unreachable("the OpNS index at search.ordnet.io")
        }
        let fallback = (j["fallback"] as? Bool) ?? ((j["match"] as? String) != "exact")
        let records = (j["results"] as? [[String: Any]] ?? []).compactMap { OpnsRecord.from($0) }
        return (fallback, records)
    }

    /// direct spent-status of ONE outpoint — verified live 03-08-2026:
    ///   GET /tx/<txid>/<vout>/spent → 200 (+ spending txid) = SPENT,
    ///   404 = UNSPENT, timeout/5xx/network = UNKNOWN (nil).
    /// UNKNOWN is never reported as "spent". (v2.2.3: replaces the old
    /// address-unspent-list check, which silently truncated for busy
    /// addresses — e.g. fee addresses — and produced FALSE stale_outpoint.)
    static func outpointSpent(txid: String, vout: Int) async -> Bool? {
        var delay: UInt64 = 400_000_000
        for _ in 0..<3 {
            guard let (code, _) = try? await get(wocBase + "/tx/\(txid)/\(vout)/spent") else { break }
            if code == 200 { return true }
            if code == 404 { return false }
            if code != 429 { break }              // 5xx etc. → unknown
            try? await Task.sleep(nanoseconds: delay)
            delay *= 2
        }
        return nil
    }

    // MARK: - ORD/ner (1Sat index — inscriptions an address currently holds)

    /// all unspent inscription outpoints on an address, paged (100 per call,
    /// max 500 like a sane cap). Same filter as ord-app v42: only items with
    /// origin.data.insc. Throws on failure so ORD/ner can degrade inline.
    static func ordnerFiles(address: String) async throws -> [OrdnerFile] {
        var out: [OrdnerFile] = []
        var offset = 0
        for _ in 0..<5 {
            let (code, data) = try await get(ordnerBase + "/txos/address/\(address)/unspent?limit=100&offset=\(offset)")
            guard code == 200, let arr = jsonArray(data) else {
                throw ApiError.unreachable("the 1Sat index at ordinals.gorillapool.io")
            }
            for item in arr {
                guard let origin = item["origin"] as? [String: Any],
                      let odata = origin["data"] as? [String: Any],
                      let insc = odata["insc"] as? [String: Any] else { continue }
                let oOut = (origin["outpoint"] as? String ?? "").split(separator: "_")
                let cOut = (item["outpoint"] as? String ?? "").split(separator: "_")
                guard oOut.count >= 1, cOut.count >= 1 else { continue }
                let file = insc["file"] as? [String: Any]
                out.append(OrdnerFile(
                    originTxid: String(oOut[0]),
                    originVout: oOut.count > 1 ? (Int(oOut[1]) ?? 0) : 0,
                    currentTxid: String(cOut[0]),
                    currentVout: cOut.count > 1 ? (Int(cOut[1]) ?? 0) : 0,
                    contentType: (file?["type"] as? String) ?? "unknown",
                    size: (file?["size"] as? Int) ?? 0,
                    height: item["height"] as? Int
                ))
            }
            if arr.count < 100 { break }
            offset += 100
        }
        return out
    }

    // MARK: - SNS resolver (sns.ordnet.io)

    /// raw resolver answer — the BODY STRING goes to the JS engine untouched
    /// so the signature is verified over exactly what the server sent.
    /// Error answers (not_verified, no_holder, …) also arrive as JSON here.
    static func snsResolveRaw(_ input: String) async throws -> (code: Int, body: String) {
        let enc = input.addingPercentEncoding(withAllowedCharacters: .urlPathAllowedCharacters) ?? input
        let (code, data) = try await get(snsBase + "/resolve/\(enc)")
        guard let body = String(data: data, encoding: .utf8), !body.isEmpty else {
            throw ApiError.unreachable("the SNS resolver at sns.ordnet.io")
        }
        return (code, body)
    }

    /// current key + chain of succession deeds (GET /pubkey) — used ONLY when
    /// an answer carries an unknown signer; the engine proves the chain.
    static func snsPubkeyInfo() async throws -> [String: Any] {
        let (code, data) = try await get(snsBase + "/pubkey")
        guard code == 200, let j = json(data) else {
            throw ApiError.unreachable("the SNS resolver at sns.ordnet.io")
        }
        return j
    }

    // MARK: - domains.ordnet.io (ORDnet v2 registry)

    static func resolve(name: String) async throws -> String {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let (code, data) = try await get(namesBase + "/resolve?name=\(enc)")
        guard code == 200, let j = json(data), let txid = j["txid"] as? String, !txid.isEmpty else {
            throw ApiError.http(code, "Domain not found: \(name)")
        }
        return txid.lowercased()
    }

    static func myDomains(address: String) async throws -> [MyDomain] {
        let (code, data) = try await get(namesBase + "/api/owner/\(address)")
        guard code == 200, let j = json(data) else { throw ApiError.unreachable("the ORDnet registry") }
        return (j["domains"] as? [[String: Any]] ?? []).compactMap { d in
            guard let n = d["name"] as? String else { return nil }
            return MyDomain(
                name: n,
                status: d["status"] as? String ?? "claimed",
                listingStatus: d["listing_status"] as? String,
                listingPrice: (d["listing_price"] as? Double) ?? Double(d["listing_price"] as? String ?? "")
            )
        }
    }

    static func whois(name: String) async throws -> DomainWhois {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowedCharacters) ?? name
        let (code, data) = try await get(namesBase + "/whois/\(enc)")
        guard code == 200, let j = json(data) else { throw ApiError.http(code, "Could not load domain details.") }
        var txid: String?; var vout: Int?
        if let t = j["target"] as? [String: Any] {
            txid = t["txid"] as? String
            vout = t["vout"] as? Int
        } else if let t = j["target"] as? String, !t.isEmpty {
            txid = t
        }
        return DomainWhois(
            status: j["status"] as? String ?? "—",
            owner: j["owner"] as? String ?? "—",
            targetTxid: txid,
            targetVout: vout,
            registeredAt: (j["registered_at"] as? String).map { String($0.prefix(10)) }
        )
    }

    static func domainRecords(name: String) async throws -> (subs: [DomainRecord], routes: [DomainRecord], listing: DomainListing?) {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowedCharacters) ?? name
        let (code, data) = try await get(namesBase + "/api/domain/\(enc)/records")
        guard code == 200, let j = json(data) else { throw ApiError.http(code, "Could not load records.") }
        let subs = (j["subdomains"] as? [[String: Any]] ?? []).compactMap { d -> DomainRecord? in
            guard let s = d["subdomain"] as? String else { return nil }
            return DomainRecord(subdomain: s, path: nil, txid: d["txid"] as? String ?? "")
        }
        let routes = (j["routes"] as? [[String: Any]] ?? []).compactMap { d -> DomainRecord? in
            guard let p = d["path"] as? String else { return nil }
            return DomainRecord(subdomain: d["subdomain"] as? String, path: p, txid: d["txid"] as? String ?? "")
        }
        var listing: DomainListing?
        if let l = j["listing"] as? [String: Any] {
            let price = (l["price_usd"] as? Double) ?? Double(l["price_usd"] as? String ?? "") ?? 0
            listing = DomainListing(priceUsd: price)
        }
        return (subs, routes, listing)
    }

    /// port of walletPost(): signed registry action. `auth` comes from the engine's
    /// signAction and already contains ts/address/signature/pubkey.
    static func walletPost(_ pathname: String, body: [String: Any], auth: [String: Any]) async throws -> [String: Any] {
        var merged = body
        merged["ts"] = auth["ts"]
        merged["address"] = auth["address"]
        merged["signature"] = auth["signature"]
        merged["pubkey"] = auth["pubkey"]
        let (code, data) = try await postJSON(namesBase + pathname, body: merged)
        let j = json(data) ?? [:]
        if code != 200 || j["error"] != nil {
            throw ApiError.http(code, j["error"] as? String ?? "HTTP \(code)")
        }
        return j
    }
}

private extension CharacterSet {
    static let urlPathAllowedCharacters = CharacterSet.urlPathAllowed
}
