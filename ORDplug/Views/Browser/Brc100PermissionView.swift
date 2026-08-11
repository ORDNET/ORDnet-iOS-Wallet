import SwiftUI
import LocalAuthentication

/// BRC-100 permission sheet (v2.5) — NATIVE, deliberately outside the page's
/// reach (an HTML dialog could be faked by the requesting app). Allow runs
/// Face ID first; the grant is then persisted per app + protocol (BRC-43),
/// so the same app never re-prompts for the same protocol. Deny returns a
/// standards-shaped WERR_PERMISSION_DENIED rejection to the app.
struct Brc100PermissionView: View {
    @EnvironmentObject private var store: WalletStore
    let request: Brc100PermissionRequest

    @State private var error = ""
    @State private var busy = false
    @State private var resolved = false

    var body: some View {
        NavigationStack {
            Form {
                Section("App") {
                    KVRow(k: "Origin", v: request.origin, mono: true)
                    KVRow(k: "Request", v: request.title)
                }
                Section {
                    Text(request.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Allowing stores this permission for this app and protocol — it will not ask again. You approve with Face ID.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    InlineAlert(kind: .error, text: error)
                    Button {
                        allow()
                    } label: {
                        if busy { ProgressView().frame(maxWidth: .infinity) }
                        else { Label("Allow", systemImage: "faceid").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    Button("Deny", role: .cancel) { finish(false) }
                        .frame(maxWidth: .infinity)
                        .disabled(busy)
                }
            }
            .ordnetBackground()
            .navigationTitle("Permission")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(true)   // only the two buttons decide
        .onDisappear { finish(false) }      // safety net: never leak the continuation
    }

    private func allow() {
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
                           localizedReason: "Allow \(request.origin): \(request.title)") { ok, evalError in
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
        store.pendingBrc100Permission = nil
    }
}
