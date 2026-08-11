import Foundation
import JavaScriptCore
import Security

/// The ORD/plug crypto engine: runs the battle-tested bsv.min.js + wallet-core.js
/// inside JavaScriptCore (a pure JS VM — no WebView, no DOM, no network).
/// Every byte of transaction-building logic is identical to the Chrome extension.
final class WalletEngine {
    static let shared = WalletEngine()

    private let context: JSContext
    private let queue = DispatchQueue(label: "io.ordnet.browser.engine")

    enum EngineError: LocalizedError {
        case scriptMissing(String)
        case jsException(String)
        case callFailed(String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .scriptMissing(let n): return "Engine resource missing: \(n)"
            case .jsException(let m):   return m
            case .callFailed(let m):    return m
            case .badResponse:          return "Engine returned an unreadable response."
            }
        }
    }

    private init() {
        let vm = JSVirtualMachine()
        context = JSContext(virtualMachine: vm)!
        context.name = "ORDplug WalletCore"

        var bootException: String?
        context.exceptionHandler = { _, exception in
            bootException = exception?.toString() ?? "unknown JS exception"
        }

        // ---- polyfills (bsv.min.js is a browser bundle) ----
        // window/self -> global object
        context.evaluateScript("var window = this; var self = this;")

        // secure randomness from the OS (SecRandomCopyBytes), bridged into JS
        let secureRandomHex: @convention(block) (Int) -> String = { count in
            var bytes = [UInt8](repeating: 0, count: max(0, count))
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        context.setObject(secureRandomHex, forKeyedSubscript: "_secureRandomHex" as NSString)
        context.evaluateScript("""
            var crypto = { getRandomValues: function(arr){
                var h = _secureRandomHex(arr.length);
                for (var i = 0; i < arr.length; i++) arr[i] = parseInt(h.substr(i*2, 2), 16);
                return arr;
            }};
            window.crypto = crypto; self.crypto = crypto;
            if (typeof globalThis !== 'undefined') globalThis.crypto = crypto;
            var console = { log: function(){}, warn: function(){}, error: function(){} };
        """)
        // v2.4 — TextEncoder/TextDecoder polyfill (UTF-8): required by the
        // bundled @bsv/sdk; JavaScriptCore does not provide these. Proven
        // against Apple's own jsc (BRC-100 proof kit, 4/4).
        context.evaluateScript("""
            if (typeof TextEncoder === 'undefined') {
                var TextEncoder = function(){};
                TextEncoder.prototype.encode = function(str){
                    str = String(str); var out = [];
                    for (var i = 0; i < str.length; i++) {
                        var c = str.codePointAt(i);
                        if (c > 0xFFFF) i++;
                        if (c < 0x80) out.push(c);
                        else if (c < 0x800) out.push(0xC0 | (c >> 6), 0x80 | (c & 63));
                        else if (c < 0x10000) out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
                        else out.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
                    }
                    return new Uint8Array(out);
                };
                window.TextEncoder = TextEncoder; self.TextEncoder = TextEncoder;
                if (typeof globalThis !== 'undefined') globalThis.TextEncoder = TextEncoder;
            }
            if (typeof TextDecoder === 'undefined') {
                var TextDecoder = function(){};
                TextDecoder.prototype.decode = function(u8){
                    var s = ''; var i = 0; u8 = new Uint8Array(u8);
                    while (i < u8.length) {
                        var b = u8[i++], c;
                        if (b < 0x80) c = b;
                        else if (b < 0xE0) c = ((b & 31) << 6) | (u8[i++] & 63);
                        else if (b < 0xF0) c = ((b & 15) << 12) | ((u8[i++] & 63) << 6) | (u8[i++] & 63);
                        else { c = ((b & 7) << 18) | ((u8[i++] & 63) << 12) | ((u8[i++] & 63) << 6) | (u8[i++] & 63); }
                        s += String.fromCodePoint(c);
                    }
                    return s;
                };
                window.TextDecoder = TextDecoder; self.TextDecoder = TextDecoder;
                if (typeof globalThis !== 'undefined') globalThis.TextDecoder = TextDecoder;
            }
        """)

        // ---- load engine scripts from the app bundle ----
        // v2.4: bsv-sdk-bundle.js = @bsv/sdk v2.2.18 as one IIFE (globalThis.
        // BSVSDK) — the BRC-100 crypto core (KeyDeriver/ProtoWallet), proven
        // in Apple's jsc before landing here. Keys never leave this engine.
        for name in ["bsv.min", "wallet-core", "bsv-sdk-bundle"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let src = try? String(contentsOf: url, encoding: .utf8) else {
                fatalError("ORD/net engine script \(name).js is missing from the app bundle")
            }
            context.evaluateScript(src, withSourceURL: URL(string: "app:///\(name).js"))
            if let ex = bootException { fatalError("Engine boot failed in \(name).js: \(ex)") }
        }
        context.exceptionHandler = nil
    }

    /// Call a wallet-core API function. Thread-safe (serialized on the engine queue).
    /// All wallet-core functions take one JSON object and return {ok, result|error}.
    func call(_ function: String, _ args: [String: Any] = [:]) throws -> Any {
        try queue.sync {
            let data = try JSONSerialization.data(withJSONObject: args, options: [])
            let json = String(data: data, encoding: .utf8) ?? "{}"

            var callException: String?
            context.exceptionHandler = { _, exception in
                callException = exception?.toString() ?? "unknown JS exception"
            }
            defer { context.exceptionHandler = nil }

            guard let core = context.objectForKeyedSubscript("OrdplugCore"),
                  let fn = core.objectForKeyedSubscript(function), !fn.isUndefined else {
                throw EngineError.callFailed("Unknown engine function: \(function)")
            }
            let result = fn.call(withArguments: [json])
            if let ex = callException { throw EngineError.jsException(ex) }
            guard let str = result?.toString(),
                  let rdata = str.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: rdata) as? [String: Any] else {
                throw EngineError.badResponse
            }
            if let ok = obj["ok"] as? Bool, ok {
                return obj["result"] ?? NSNull()
            }
            throw EngineError.callFailed(obj["error"] as? String ?? "Engine call failed.")
        }
    }

    // ---- typed conveniences ----

    func string(_ function: String, _ args: [String: Any] = [:]) throws -> String {
        guard let s = try call(function, args) as? String else { throw EngineError.badResponse }
        return s
    }
    func bool(_ function: String, _ args: [String: Any] = [:]) throws -> Bool {
        guard let b = try call(function, args) as? Bool else { throw EngineError.badResponse }
        return b
    }
    func dict(_ function: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        guard let d = try call(function, args) as? [String: Any] else { throw EngineError.badResponse }
        return d
    }
    func array(_ function: String, _ args: [String: Any] = [:]) throws -> [[String: Any]] {
        guard let a = try call(function, args) as? [[String: Any]] else { throw EngineError.badResponse }
        return a
    }
    func int(_ function: String, _ args: [String: Any] = [:]) throws -> Int {
        if let n = try call(function, args) as? Int { return n }
        if let n = try call(function, args) as? Double { return Int(n) }
        throw EngineError.badResponse
    }

    // ---- domain-specific helpers ----

    func generateMnemonic() throws -> String { try string("generateMnemonic") }
    func validateMnemonic(_ m: String) throws -> Bool { try bool("validateMnemonic", ["mnemonic": m]) }
    func wifToAddress(_ wif: String) throws -> String { try string("wifToAddress", ["wif": wif]) }
    func wifToPubKey(_ wif: String) throws -> String { try string("wifToPubKey", ["wif": wif]) }
    func randomWif() throws -> String { try string("randomWif") }
    func validateAddress(_ a: String) -> Bool { (try? bool("validateAddress", ["address": a])) ?? false }

    func wif(fromMnemonic m: String, mode: ImportMode, path: String? = nil, pin: String = "") throws -> String {
        switch mode {
        case .bip44:  return try string("mnemonicToWifBip44", ["mnemonic": m])
        case .legacy: return try string("mnemonicToWifLegacy", ["mnemonic": m])
        case .path:   return try string("mnemonicToWifPath", ["mnemonic": m, "path": path ?? Fees.bip44Path, "passphrase": pin])
        case .wif:    throw EngineError.callFailed("Not a mnemonic mode")
        }
    }

    func fees(inscribeBytes: Int = 0) throws -> Fees {
        let d = try dict("fees", ["bytes": inscribeBytes])
        return Fees(
            sendMinerFee: d["sendMinerFee"] as? Int ?? 97,
            inscribeMinerFee: d["inscribeMinerFee"] as? Int ?? 105,
            ordinalMinerFee: d["ordinalMinerFee"] as? Int ?? 117,
            totalServiceFees: d["totalServiceFees"] as? Int ?? 3996
        )
    }

    /// BRC-100 fase 2 (v2.5): run one ProtoWallet method in the engine.
    /// ProtoWallet is async on the microtask queue; JSC drains that queue when
    /// each synchronous call returns, so start → poll resolves immediately in
    /// practice (the loop is a safety margin, never a busy-wait).
    func callBrc100(method: String, argsJson: String, wif: String) async throws -> [String: Any] {
        _ = try call("brc100Init", ["wif": wif])
        let callId = "b\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 0..<100000))"
        _ = try call("brc100Start", ["callId": callId, "method": method, "argsJson": argsJson])
        for _ in 0..<200 {
            if let r = try call("brc100Poll", ["callId": callId]) as? [String: Any],
               (r["done"] as? Bool) == true {
                if (r["ok"] as? Bool) == true {
                    return r["result"] as? [String: Any] ?? [:]
                }
                let e = r["error"] as? [String: Any]
                throw Brc100.Err(name: e?["name"] as? String ?? "WERR_UNKNOWN",
                                 code: e?["code"] as? Int ?? 1,
                                 message: e?["message"] as? String ?? "Unknown engine error.")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw Brc100.Err(name: "WERR_UNKNOWN", code: 1, message: "The BRC-100 engine call timed out.")
    }

    /// wipe BRC-100 key material from the engine (called on wallet lock)
    func brc100Reset() {
        _ = try? call("brc100Reset")
    }

    func signMessage(wif: String, message: String) throws -> (signature: String, pubkey: String) {
        let d = try dict("signMessage", ["wif": wif, "message": message])
        guard let s = d["signature"] as? String, let p = d["pubkey"] as? String else { throw EngineError.badResponse }
        return (s, p)
    }
}

enum ImportMode: String {
    case bip44, legacy, wif, path
}

struct Fees {
    static let bip44Path = "m/44'/236'/0'/0/0"
    let sendMinerFee: Int
    let inscribeMinerFee: Int
    let ordinalMinerFee: Int
    let totalServiceFees: Int
}
