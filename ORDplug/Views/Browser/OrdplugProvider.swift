import Foundation
import SwiftUI

/// The window.ordplug provider — same method set as the extension's inpage.js:
/// connect, getAddress, getPublicKey, getBalance, pay, inscribe, signMessage,
/// purchase, listOrdinal, buyOrdinal, sendTx. Every call returns a Promise;
/// approvals happen in a native sheet instead of the extension popup.
enum OrdplugProvider {

    /// per-request delivery callbacks, keyed by request id
    static var pendingDelivery: [String: (Bool, [String: Any]?, String?) -> Void] = [:]

    static let script = """
    (function(){
      if (window.ordplug) return;
      var _id = 0;
      var _pending = {};
      function request(method, params){
        return new Promise(function(resolve, reject){
          var id = 'op_' + (++_id) + '_' + Date.now();
          _pending[id] = { resolve: resolve, reject: reject };
          try {
            window.webkit.messageHandlers.ordplug.postMessage({ id: id, method: method, params: params || {} });
          } catch(e) { delete _pending[id]; reject(new Error('ORD/net bridge unavailable')); return; }
          setTimeout(function(){
            if(_pending[id]){ _pending[id].reject(new Error('ORD/net request timed out')); delete _pending[id]; }
          }, 5 * 60 * 1000);
        });
      }
      window.__ordplugDeliver = function(msg){
        var p = _pending[msg.id];
        if (!p) return;
        delete _pending[msg.id];
        if (msg.ok) p.resolve(msg.result);
        else p.reject(new Error(msg.error || 'Request failed'));
      };
      window.ordplug = {
        isOrdPlug: true,
        version: '1.0.0',
        platform: 'ios',
        connect:      function(){ return request('connect'); },
        getAddress:   function(){ return request('getAddress'); },
        getPublicKey: function(){ return request('getPublicKey'); },
        getBalance:   function(){ return request('getBalance'); },
        pay:          function(params){ return request('pay', params); },
        inscribe:     function(params){ return request('inscribe', params); },
        signMessage:  function(params){ return request('signMessage', typeof params === 'string' ? { message: params } : params); },
        purchase:     function(params){ return request('purchase', params); },
        listOrdinal:  function(params){ return request('listOrdinal', params); },
        buyOrdinal:   function(params){ return request('buyOrdinal', params); },
        sendTx:       function(params){ return request('sendTx', params); },
        request:      request
      };
      window.dispatchEvent(new Event('ordplug#initialized'));
    })();
    """

    /// read-only methods (auto-resolved when the origin is already connected)
    @MainActor
    static func performRead(method: String, store: WalletStore) async throws -> [String: Any] {
        switch method {
        case "getAddress", "connect":
            return ["address": store.address]
        case "getPublicKey":
            return ["pubkey": try store.engine.wifToPubKey(store.wif), "address": store.address]
        case "getBalance":
            let b = try await Api.balance(address: store.address)
            return ["confirmed": b.confirmed, "unconfirmed": b.unconfirmed]
        default:
            throw WalletEngine.EngineError.callFailed("Not a read method")
        }
    }

    /// sats as a safe integer — port of satNum/purchaseSats
    static func satNum(_ v: Any?) -> Int {
        if let n = v as? Int { return max(0, n) }
        if let d = v as? Double { return max(0, Int(d.rounded())) }
        if let s = v as? String, let d = Double(s) { return max(0, Int(d.rounded())) }
        return 0
    }
    static func purchaseSats(_ p: [String: Any]) -> Int {
        if let a = p["amountSat"] { return satNum(a) }
        if let a = p["amount"] as? Double { return Int((a * 1e8).rounded()) }
        if let a = p["amount"] as? Int { return Int((Double(a) * 1e8).rounded()) }
        return 0
    }

    /// execute an APPROVED request — mirror of the extension's approveRequest()
    @MainActor
    static func perform(_ req: ProviderRequest, store: WalletStore) async throws -> [String: Any] {
        let p = req.params
        switch req.method {
        case "connect", "getAddress", "getPublicKey", "getBalance":
            store.connectSite(req.origin)
            return try await performRead(method: req.method, store: store)

        case "pay":
            let to = String(describing: p["to"] ?? "")
            let amount = satNum(p["amount"])
            let data: String? = p["data"].flatMap { $0 is NSNull ? nil : String(describing: $0) }
            let fee = (p["fee"] as? Int) ?? 0
            let txid = try await store.sendBSV(to: to, amountSat: amount, dataStr: data, feeSat: fee)
            return ["txid": txid]

        case "inscribe":
            let dataStr = String(describing: p["data"] ?? "")
            let b64 = Data(dataStr.utf8).base64EncodedString()
            let ct = (p["contentType"] as? String) ?? "text/plain"
            let fee = (p["fee"] as? Int) ?? 0
            let txid = try await store.inscribe(contentType: ct, dataB64: b64, feeSat: fee)
            return ["txid": txid, "address": store.address]

        case "signMessage":
            let msg = String(describing: p["message"] ?? "")
            let sig = try store.engine.signMessage(wif: store.wif, message: msg)
            return ["signature": sig.signature, "pubkey": sig.pubkey, "address": store.address]

        case "purchase":
            let sats = purchaseSats(p)
            guard sats >= 1 else { throw WalletEngine.EngineError.callFailed("Invalid amount.") }
            let to = String(describing: p["to"] ?? "")
            guard store.engine.validateAddress(to) else { throw WalletEngine.EngineError.callFailed("Invalid seller address.") }
            let msg = try store.engine.string("purchaseMessage", [
                "shop": p["shop"] as? String ?? "", "itemTitle": p["itemTitle"] as? String ?? "",
                "orderId": p["orderId"] as? String ?? "", "amountSat": sats, "to": to
            ])
            let sig = try store.engine.signMessage(wif: store.wif, message: msg)
            var opret = String(describing: p["reference"] ?? p["opReturn"] ?? msg) + " | sig:" + sig.signature
            if opret.count > 900 { opret = String(opret.prefix(900)) }
            let feeSat = try store.engine.int("purchaseFee", ["opReturnByteLength": opret.utf8.count])
            let txid = try await store.sendBSV(to: to, amountSat: sats, dataStr: opret, feeSat: feeSat)
            return ["txid": txid, "address": store.address, "signature": sig.signature, "pubkey": sig.pubkey, "message": msg]

        case "listOrdinal":
            guard FeatureFlags.marketplaceEnabled else { throw WalletEngine.EngineError.callFailed("Marketplace is disabled in this build.") }
            let price = satNum(p["priceSat"])
            guard price >= 1 else { throw WalletEngine.EngineError.callFailed("Invalid price.") }
            let ordTxid = String(describing: p["ordinalTxid"] ?? "")
            let ordVout = (p["ordinalVout"] as? Int) ?? 0
            let ordHex = try await Api.txHex(ordTxid)
            let ordScriptHex = try store.engine.string("outputScriptHex", ["rawTxHex": ordHex, "vout": ordVout])
            let r = try store.engine.dict("buildListingPartial", [
                "wif": store.wif, "ordTxid": ordTxid, "ordVout": ordVout,
                "ordScriptHex": ordScriptHex, "priceSat": price
            ])
            return ["partialTx": r["partialTx"] ?? "", "payScriptHex": r["payScriptHex"] ?? "",
                    "sellerAddress": store.address, "priceSat": price]

        case "buyOrdinal":
            guard FeatureFlags.marketplaceEnabled else { throw WalletEngine.EngineError.callFailed("Marketplace is disabled in this build.") }
            let txid = try await store.buyOrdinal(
                partialTx: String(describing: p["partialTx"] ?? ""),
                priceSat: satNum(p["priceSat"]),
                sellerAddress: String(describing: p["sellerAddress"] ?? ""),
                payScriptHex: String(describing: p["payScriptHex"] ?? "")
            )
            return ["txid": txid, "address": store.address]

        case "sendTx":
            let (txid, rawtx) = try await store.sendComposedTx(params: p)
            var out: [String: Any] = ["rawtx": rawtx, "address": store.address]
            out["txid"] = txid ?? NSNull()
            return out

        default:
            throw WalletEngine.EngineError.callFailed("Unknown method: \(req.method)")
        }
    }
}

// MARK: - Approval sheet (native counterpart of the extension approval popup)

struct ApprovalView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    let request: ProviderRequest

    @State private var error = ""
    @State private var busy = false
    @State private var fees: Fees?

    private var titleAndIcon: (String, String) {
        switch request.method {
        case "connect", "getAddress", "getPublicKey", "getBalance": return ("Connect wallet", "link")
        case "pay": return ("Approve payment", "paperplane")
        case "inscribe": return ("Approve inscription", "pencil.and.outline")
        case "signMessage": return ("Sign message", "checkmark.seal")
        case "purchase": return ("Approve purchase", "cart")
        case "listOrdinal": return ("List for sale", "tag")
        case "buyOrdinal": return ("Buy ordinal", "bag")
        case "sendTx": return ((request.params["meta"] as? [String: Any])?["title"] as? String ?? "Approve transaction", "paperplane")
        default: return ("Wallet request", "questionmark")
        }
    }

    private var approveLabel: String {
        switch request.method {
        case "connect", "getAddress", "getPublicKey", "getBalance": return "Connect"
        case "pay": return "Approve & send"
        case "inscribe": return "Approve & inscribe"
        case "signMessage": return "Sign"
        case "purchase": return "Sign & pay"
        case "listOrdinal": return "Sign listing"
        case "buyOrdinal": return "Approve & buy"
        case "sendTx": return "Approve & send"
        default: return "Approve"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: titleAndIcon.1)
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(titleAndIcon.0).font(.headline)
                            Text("Source: \(request.origin)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Details") { details }
                Section {
                    InlineAlert(kind: .error, text: error)
                    Button {
                        approve()
                    } label: {
                        if busy { ProgressView().frame(maxWidth: .infinity) }
                        else { Text(approveLabel).frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    Button("Reject", role: .destructive) { reject() }
                        .disabled(busy)
                }
            }
            .ordnetBackground()
            .navigationTitle("Wallet request")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(busy)
            .onDisappear {
                // dismissed without action = rejected
                if OrdplugProvider.pendingDelivery[request.id] != nil { reject() }
            }
            .task { fees = try? store.engine.fees() }
        }
    }

    @ViewBuilder
    private var details: some View {
        let p = request.params
        let svc = fees?.totalServiceFees ?? 3996
        switch request.method {
        case "connect", "getAddress", "getPublicKey", "getBalance":
            Text("This page wants to see your wallet address.").font(.footnote)
            KVRow(k: "Account", v: store.activeAccount?.name ?? "Account")
            KVRow(k: "Address", v: store.address, mono: true)
        case "pay":
            KVRow(k: "From", v: store.activeAccount?.name ?? "Account")
            KVRow(k: "To", v: String(describing: p["to"] ?? ""), mono: true)
            KVRow(k: "Amount", v: "\(Fmt.bsv(OrdplugProvider.satNum(p["amount"]))) BSV (\(Fmt.sats(OrdplugProvider.satNum(p["amount"]))) sats)")
            if let d = p["data"] { KVRow(k: "OP_RETURN", v: String(String(describing: d).prefix(80))) }
            KVRow(k: "Miner fee", v: "\(Fmt.bsv((p["fee"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? fees?.sendMinerFee ?? 97)) BSV")
            KVRow(k: "Service fee", v: "\(Fmt.bsv(svc)) BSV")
        case "inscribe":
            let bytes = String(describing: p["data"] ?? "").utf8.count
            KVRow(k: "Content type", v: (p["contentType"] as? String) ?? "text/plain")
            if (p["contentType"] as? String) == "text/plain" && bytes < 64 {
                KVRow(k: "Data", v: String(describing: p["data"] ?? ""))
            }
            KVRow(k: "Size", v: "\(Fmt.sats(bytes)) bytes")
            KVRow(k: "Inscribe to", v: store.address, mono: true)
            KVRow(k: "Miner fee", v: "\(Fmt.bsv((try? store.engine.fees(inscribeBytes: bytes).inscribeMinerFee) ?? 0)) BSV")
            KVRow(k: "Service fee", v: "\(Fmt.bsv(svc)) BSV")
        case "signMessage":
            Text("Sign this message with your key. No coins move.").font(.footnote)
            KVRow(k: "Message", v: String(String(describing: p["message"] ?? "").prefix(200)))
        case "purchase":
            KVRow(k: "Item", v: (p["itemTitle"] as? String) ?? "Order")
            if let shop = p["shop"] as? String { KVRow(k: "Shop", v: shop) }
            KVRow(k: "Seller", v: String(describing: p["to"] ?? ""), mono: true)
            KVRow(k: "Amount", v: "\(Fmt.bsv(OrdplugProvider.purchaseSats(p))) BSV (\(Fmt.sats(OrdplugProvider.purchaseSats(p))) sats)")
            KVRow(k: "Miner fee", v: "\(Fmt.bsv(fees?.sendMinerFee ?? 97)) BSV")
            KVRow(k: "Service fee", v: "\(Fmt.bsv(svc)) BSV")
            Text("You sign the order and pay in one step. Your signature and the order reference are written on-chain.")
                .font(.caption).foregroundStyle(.secondary)
        case "listOrdinal":
            Text("Sign a one-sided atomic swap. The ordinal stays in your wallet until a buyer pays your price.").font(.footnote)
            KVRow(k: "Ordinal", v: "\(String(String(describing: p["ordinalTxid"] ?? "").prefix(10)))…_\(p["ordinalVout"] ?? 0)", mono: true)
            let price = OrdplugProvider.satNum(p["priceSat"])
            KVRow(k: "Price", v: "\(Fmt.bsv(price)) BSV (\(Fmt.sats(price)) sats)")
            KVRow(k: "Paid to", v: store.address, mono: true)
        case "buyOrdinal":
            Text("Complete the swap: pay the seller and receive the ordinal in one transaction.").font(.footnote)
            let price = OrdplugProvider.satNum(p["priceSat"])
            KVRow(k: "Price to seller", v: "\(Fmt.bsv(price)) BSV (\(Fmt.sats(price)) sats)")
            KVRow(k: "Seller", v: String(describing: p["sellerAddress"] ?? ""), mono: true)
            KVRow(k: "Miner fee", v: "\(Fmt.bsv(fees?.ordinalMinerFee ?? 117)) BSV")
            KVRow(k: "Service fee", v: "\(Fmt.bsv(svc)) BSV")
            KVRow(k: "Received to", v: store.address, mono: true)
        case "sendTx":
            let outs = (p["outputs"] as? [[String: Any]]) ?? []
            if let meta = p["meta"] as? [String: Any], let shop = meta["shop"] as? String {
                KVRow(k: "Shop", v: shop)
            }
            ForEach(Array(outs.enumerated()), id: \.offset) { i, o in
                let type = (o["type"] as? String) ?? "?"
                switch type {
                case "inscription":
                    KVRow(k: "#\(i) Inscription", v: "\(String(String(describing: o["data"] ?? "").prefix(40))) → \(max(1, OrdplugProvider.satNum(o["satoshis"]))) sat")
                case "p2pkh":
                    KVRow(k: "#\(i) Payment", v: "\(Fmt.sats(OrdplugProvider.satNum(o["satoshis"]))) sats → \(String(String(describing: o["address"] ?? "").prefix(16)))…")
                case "opreturn":
                    KVRow(k: "#\(i) OP_RETURN", v: String(((o["data"] as? [String]) ?? []).joined(separator: " ").prefix(60)))
                case "script":
                    KVRow(k: "#\(i) Script", v: "\(Fmt.sats(OrdplugProvider.satNum(o["satoshis"]))) sats")
                default:
                    KVRow(k: "#\(i)", v: type)
                }
            }
            let inclSvc = (p["includeServiceFees"] as? Bool) != false
            KVRow(k: "Service fee", v: "\(Fmt.bsv(inclSvc ? svc : 0)) BSV")
            Text("Review every output above — you sign and broadcast in one step.")
                .font(.caption).foregroundStyle(.secondary)
        default:
            Text("Unknown request.").font(.footnote)
        }
    }

    private func approve() {
        busy = true
        error = ""
        Task {
            do {
                let result = try await OrdplugProvider.perform(request, store: store)
                OrdplugProvider.pendingDelivery.removeValue(forKey: request.id)?(true, result, nil)
                store.pendingProviderRequest = nil
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func reject() {
        OrdplugProvider.pendingDelivery.removeValue(forKey: request.id)?(false, nil, "User rejected the request")
        store.pendingProviderRequest = nil
        dismiss()
    }
}
