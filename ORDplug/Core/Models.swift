import Foundation

// MARK: - Feature flags

/// App Review kill-switch (guideline 3.1.1): set `marketplaceEnabled = false`
/// to hide every buy/sell flow (list, delist, bulk, buyOrdinal, domain
/// marketplace) in one place — wallet, send/receive, inscribe and browsing
/// stay fully functional.
enum FeatureFlags {
    static let marketplaceEnabled = true
}

// MARK: - Accounts

struct Account: Codable, Identifiable, Equatable {
    var name: String
    var wif: String
    var origin: String      // bip44 | legacy | wif | random
    var path: String?
    var address: String

    var id: String { address }

    var originLabel: String {
        switch origin {
        case "bip44":  return "BIP44"
        case "legacy": return "legacy"
        case "wif":    return "WIF"
        case "random": return "generated"
        default:       return origin
        }
    }
}

/// The encrypted vault payload — same shape as the extension's V11 vault.
struct VaultPayload: Codable {
    struct StoredAccount: Codable {
        var name: String
        var wif: String
        var origin: String?
        var path: String?
    }
    var accounts: [StoredAccount]
    var active: Int
}

// MARK: - Balance / history

struct Balance {
    var confirmed: Int
    var unconfirmed: Int
    var total: Int { confirmed + unconfirmed }
}

struct HistoryTx: Identifiable {
    var txHash: String
    var height: Int
    var id: String { txHash }
    var isPending: Bool { height <= 0 }
}

// MARK: - Holdings (SNS names + BSVmaps from the ORDnet V30 indexer,
// OpNS names from the OpNS index at search.ordnet.io)

enum HoldingKind: String, Codable {
    case sns, bsvmap, opns
    /// v2.3 — generic inscribed file (ORD/ner): sendable as 1-sat ordinal,
    /// never listable, never shown in the Home holdings tabs
    case inscription
}

struct Holding: Identifiable, Equatable {
    var kind: HoldingKind
    var name: String
    var district: Int?
    var claimHeight: Int
    var status: String            // held | listed | contract | ...
    var currentTxid: String
    var currentVout: Int
    var priceSat: Int?
    /// v2.6.1 — listed on the ORDnet v2 DOMAIN registry (USD marketplace,
    /// Domains tab). A SEPARATE marketplace from the bsvmap.io ordinal
    /// listings (isListed/priceSat): merged in for display so the wallet
    /// and the Domains tab tell the same story. Managed via Domains.
    var domainListedUsd: Double? = nil

    var id: String { "\(kind.rawValue):\(name):\(currentTxid)_\(currentVout)" }
    var isListed: Bool { status == "listed" }

    /// full type label ("Item / Type" rows) — one place for all categories
    var kindLabel: String {
        switch kind {
        case .sns:         return "SNS name (1Sat Ordinal)"
        case .bsvmap:      return "BSVmap district (1Sat Ordinal)"
        case .opns:        return "OpNS name (1Sat Ordinal)"
        case .inscription: return "Inscribed file (1Sat Ordinal)"
        }
    }
    /// short label for button/title text ("Send …")
    var shortKindLabel: String {
        switch kind {
        case .sns:         return "SNS name"
        case .bsvmap:      return "BSVmap"
        case .opns:        return "OpNS name"
        case .inscription: return "inscription"
        }
    }
    var utxoShort: String {
        guard currentTxid.count == 64 else { return currentTxid }
        return "\(currentTxid.prefix(10))…\(currentTxid.suffix(6))_\(currentVout)"
    }

    /// tolerant to indexer field naming — port of listedPriceSats()
    static func priceSats(from dict: [String: Any]) -> Int? {
        for key in ["priceSat", "priceSats", "listPriceSat", "listPrice", "price"] {
            if let v = dict[key] {
                if let n = v as? Int, n > 0 { return n }
                if let d = v as? Double, d > 0 { return Int(d) }
                if let s = v as? String, let n = Int(s), n > 0 { return n }
            }
        }
        return nil
    }

    /// map one record of the OpNS index (GET /api/opns/owner/<address>) — the
    /// field names are the OpNS API's own (owner_address, current_txid, …).
    /// No claim height exists in OpNS responses; claimHeight stays 0 and the
    /// row shows just "OpNS".
    static func fromOpns(_ dict: [String: Any]) -> Holding? {
        guard let name = dict["name"] as? String,
              let txid = dict["current_txid"] as? String else { return nil }
        return Holding(
            kind: .opns,
            name: name,
            district: nil,
            claimHeight: 0,
            status: "held",
            currentTxid: txid,
            currentVout: (dict["current_vout"] as? Int) ?? 0,
            priceSat: nil
        )
    }

    static func from(_ dict: [String: Any], kind: HoldingKind) -> Holding? {
        guard let name = dict["name"] as? String ?? (dict["district"].map { "bsvmap \($0)" }),
              let txid = dict["currentTxid"] as? String else { return nil }
        let district = (dict["district"] as? Int) ?? Int(dict["district"] as? String ?? "")
        return Holding(
            kind: kind,
            name: name,
            district: district,
            claimHeight: (dict["claimHeight"] as? Int) ?? 0,
            status: (dict["status"] as? String) ?? "held",
            currentTxid: txid,
            currentVout: (dict["currentVout"] as? Int) ?? 0,
            priceSat: priceSats(from: dict)
        )
    }
}

// MARK: - ORD/ner (v2.3 — on-chain file browser, 1Sat index)

/// one file in ORD/ner: an inscription outpoint the address currently holds.
/// `origin*` locates the CONTENT (preview / open in browser); `current*` is
/// the outpoint a Send must spend (sat-following).
struct OrdnerFile: Identifiable, Equatable {
    var originTxid: String
    var originVout: Int
    var currentTxid: String
    var currentVout: Int
    var contentType: String
    var size: Int
    var height: Int?            // nil = unconfirmed
    var name: String?           // filename from the app's inscription log, if known
    var sentLabel: Bool = false // log-only item the address no longer holds

    var id: String { "\(currentTxid)_\(currentVout)" }
    var displayName: String {
        name ?? "\(originTxid.prefix(12))…\(originTxid.suffix(6))"
    }
    var typeLabel: String {
        let ct = contentType.split(separator: ";").first.map(String.init) ?? contentType
        if ct.hasPrefix("image/") { return "Image" }
        if ct.hasPrefix("video/") { return "Video" }
        if ct.hasPrefix("audio/") { return "Audio" }
        if ct.hasPrefix("text/html") { return "HTML" }
        if ct.hasPrefix("text/plain") { return "Text" }
        if ct.contains("json") { return "JSON" }
        return ct.split(separator: "/").last.map(String.init) ?? "File"
    }
    var icon: String {
        let ct = contentType
        if ct.hasPrefix("image/") { return "photo" }
        if ct.hasPrefix("video/") { return "film" }
        if ct.hasPrefix("audio/") { return "music.note" }
        if ct.hasPrefix("text/html") { return "globe" }
        if ct.hasPrefix("text/") { return "doc.text" }
        if ct.contains("json") { return "curlybraces" }
        return "doc"
    }
    var sizeLabel: String {
        if size <= 0 { return "—" }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
        return String(format: "%.1f MB", Double(size) / 1024 / 1024)
    }
}

// MARK: - OpNS (bare names, tree 0 — index at search.ordnet.io/api/opns)

/// one record as returned by the OpNS index (verified live 03-08-2026:
/// name, origin_txid/origin_vout, owner_address, current_txid/current_vout,
/// ambiguous, lineage_verified — NO block height field)
struct OpnsRecord {
    var name: String
    var ownerAddress: String
    var currentTxid: String
    var currentVout: Int
    var ambiguous: Bool
    var lineageVerified: Bool

    static func from(_ dict: [String: Any]) -> OpnsRecord? {
        guard let name = dict["name"] as? String,
              let owner = dict["owner_address"] as? String,
              let txid = dict["current_txid"] as? String else { return nil }
        return OpnsRecord(
            name: name,
            ownerAddress: owner,
            currentTxid: txid,
            currentVout: (dict["current_vout"] as? Int) ?? 0,
            ambiguous: (dict["ambiguous"] as? Bool) ?? false,
            lineageVerified: (dict["lineage_verified"] as? Bool) ?? false
        )
    }
}

/// verified payment target for an OpNS name: the holder address has been
/// recomputed from the chain (locking script of the current outpoint) and the
/// outpoint checked unspent — never pay a cached or unverified address.
struct OpnsPayTarget: Equatable {
    var name: String
    var holderAddress: String
    var currentTxid: String
    var currentVout: Int
}

// MARK: - SNS resolver (sns.ordnet.io — signed answers)

/// verified SNS payment target: signature checked against the pinned resolver
/// key, holder address derived from the SIGNED holder_script (never the
/// unsigned holder_address field), outpoint checked unspent right before pay.
struct SnsPayTarget: Equatable {
    var name: String            // resolved name, e.g. "ordnet.web3"
    var mailbox: String         // "" for a bare name
    var fallback: Bool          // true = mailbox unknown, paid to the name's holder
    var holderAddress: String   // derived from the signed script
    var currentTxid: String
    var currentVout: Int
    var expires: Int
    var warning: String         // inline notices (address_mismatch, key rotation)
}

// MARK: - .web3 domains (ORDnet registry)

struct MyDomain: Identifiable {
    var name: String
    var status: String
    var listingStatus: String?
    var listingPrice: Double?
    var id: String { name }
    var isForSale: Bool { listingStatus == "active" }
}

struct DomainWhois {
    var status: String
    var owner: String
    var targetTxid: String?
    var targetVout: Int?
    var registeredAt: String?
}

struct DomainRecord: Identifiable {
    var subdomain: String?
    var path: String?
    var txid: String
    var id: String { "\(subdomain ?? "")/\(path ?? "")/\(txid)" }
}

struct DomainListing {
    var priceUsd: Double
}

// MARK: - Inscriptions made via this app (Upload tab)

struct InscriptionRecord: Codable, Identifiable, Equatable {
    var txid: String
    var contentType: String
    var filename: String
    var bytes: Int
    var ts: Double            // ms since epoch

    var id: String { txid }
    var date: Date { Date(timeIntervalSince1970: ts / 1000) }
    var sizeLabel: String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.2f MB", Double(bytes) / 1024 / 1024)
    }
    var kindIcon: String {
        if contentType.hasPrefix("image/") { return "photo" }
        if contentType.hasPrefix("text/html") { return "chevron.left.forwardslash.chevron.right" }
        if contentType.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }
}

// MARK: - Address book

struct BookEntry: Codable, Identifiable, Equatable {
    var name: String
    var address: String
    var ts: Double
    var id: String { address }
}

// MARK: - BRC-100 permission prompt (v2.5)

/// one pending permission question for the native sheet; the continuation is
/// resumed exactly once (Allow after Face ID, or Deny)
struct Brc100PermissionRequest: Identifiable {
    let id = UUID()
    let origin: String
    let title: String
    let detail: String
    let continuation: CheckedContinuation<Bool, Never>
}

// MARK: - BRC-100 fase 3 (v2.6): geld

/// one output line on the native transaction-confirmation sheet
struct Brc100TxLine: Identifiable {
    let id = UUID()
    let dest: String            // P2PKH address, or a script description
    let sats: Int
    let note: String            // the app's outputDescription
}

/// per-transaction confirmation (money ≠ grant: NEVER persisted, every
/// transaction asks again with Face ID — hard rule 2 of fase 3)
struct Brc100TxConfirmRequest: Identifiable {
    let id = UUID()
    let origin: String
    let title: String           // "Approve payment" / "Accept incoming payment"
    let description: String     // the app's action description
    let lines: [Brc100TxLine]
    let minerFeeEstimate: Int
    let serviceFees: Int
    let totalSat: Int
    let incoming: Bool          // internalizeAction: money flows TO this wallet
    let continuation: CheckedContinuation<Bool, Never>
}

/// one entry in the local BRC-100 action log (per address, like the
/// inscription log) — feeds listActions; only actions made via this app
struct Brc100ActionRecord: Codable, Identifiable, Equatable {
    var txid: String
    var description: String
    var labels: [String]
    var satoshis: Int           // action outputs total (excl. fees)
    var origin: String
    var ts: Double              // ms since epoch
    var status: String          // "completed" — only fully-processed actions exist
    var isOutgoing: Bool
    var id: String { txid }
}

/// one granted BRC-100 permission, decoded from the stored grant key —
/// shown and revocable in Settings (v2.6 grants manager)
struct Brc100GrantInfo: Identifiable, Equatable {
    var key: String             // raw stored key (revoke handle)
    var origin: String
    var detail: String          // "identity key" / "level 1 · protocol …"
    var id: String { key }
}

// MARK: - dApp provider requests (window.ordplug)

struct ProviderRequest: Identifiable {
    var id: String
    var method: String
    var params: [String: Any]
    var origin: String
}

// MARK: - formatting

enum Fmt {
    /// port of bsvFmt(): trims trailing zeros of an 8-decimal BSV amount
    static func bsv(_ sats: Int) -> String {
        var s = String(format: "%.8f", Double(sats) / 1e8)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
    static func sats(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
    static func shortAddress(_ a: String) -> String {
        guard a.count > 16 else { return a }
        return "\(a.prefix(10))…\(a.suffix(6))"
    }
    static func shortTxid(_ t: String) -> String {
        guard t.count == 64 else { return t }
        return "\(t.prefix(10))…\(t.suffix(6))"
    }
}
