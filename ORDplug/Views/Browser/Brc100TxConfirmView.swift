import SwiftUI
import LocalAuthentication

/// BRC-100 transaction confirmation (v2.6, fase 3) — NATIVE and deliberately
/// outside the page's reach, like the permission sheet. Hard rule 2 of the
/// fase-3 briefing: money ≠ grant. NOTHING here is ever persisted — every
/// transaction shows this sheet again, approval always runs Face ID, and
/// Reject returns a standards-shaped WERR_PERMISSION_DENIED rejection.
struct Brc100TxConfirmView: View {
    @EnvironmentObject private var store: WalletStore
    let request: Brc100TxConfirmRequest

    @State private var error = ""
    @State private var busy = false
    @State private var resolved = false

    private func usd(_ sats: Int) -> String {
        guard let rate = store.usdRate else { return "" }
        return String(format: " · $%.2f", Double(sats) / 1e8 * rate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("App") {
                    KVRow(k: "Origin", v: request.origin, mono: true)
                    KVRow(k: "Action", v: request.description)
                }
                Section(request.incoming ? "Incoming outputs" : "Pays to") {
                    ForEach(request.lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(line.dest)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("\(Fmt.sats(line.sats)) sats")
                                    .font(.callout.weight(.semibold))
                            }
                            if !line.note.isEmpty {
                                Text(line.note).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Total") {
                    KVRow(k: request.incoming ? "You receive" : "Outputs total",
                          v: "\(Fmt.sats(request.totalSat)) sats (\(Fmt.bsv(request.totalSat)) BSV)\(usd(request.totalSat))")
                    if !request.incoming {
                        KVRow(k: "Miner fee (est.)", v: "\(Fmt.sats(request.minerFeeEstimate)) sats")
                        KVRow(k: "Service fees", v: "\(Fmt.sats(request.serviceFees)) sats")
                    }
                }
                Section {
                    Text(request.incoming
                         ? "This accepts an incoming payment into your wallet. Nothing leaves your wallet."
                         : "This signs and broadcasts a transaction from your wallet. You approve every transaction separately with Face ID — this is never stored as a permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    InlineAlert(kind: .error, text: error)
                    Button {
                        approve()
                    } label: {
                        if busy { ProgressView().frame(maxWidth: .infinity) }
                        else { Label(request.incoming ? "Accept" : "Approve & sign", systemImage: "faceid").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    Button("Reject", role: .cancel) { finish(false) }
                        .frame(maxWidth: .infinity)
                        .disabled(busy)
                }
            }
            .ordnetBackground()
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(true)   // only the two buttons decide
        .onDisappear { finish(false) }      // safety net: never leak the continuation
    }

    private func approve() {
        error = ""
        busy = true
        let ctx = LAContext()
        var authError: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            error = "Face ID / passcode is unavailable: \(authError?.localizedDescription ?? "unknown")"
            busy = false
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "\(request.title): \(Fmt.sats(request.totalSat)) sats — \(request.origin)") { ok, evalError in
            DispatchQueue.main.async {
                busy = false
                if ok {
                    finish(true)
                } else {
                    error = evalError?.localizedDescription ?? "Authentication failed."
                }
            }
        }
    }

    private func finish(_ approved: Bool) {
        guard !resolved else { return }
        resolved = true
        request.continuation.resume(returning: approved)
        store.pendingBrc100TxConfirm = nil
    }
}
