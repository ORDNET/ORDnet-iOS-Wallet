import SwiftUI

/// BRC-100 grants manager (v2.6) — the persistent BRC-43 permissions from
/// fase 2 (per app, per protocol, plus the per-app identity-key grant),
/// grouped per app-origin, each revocable. Revoking means the app simply
/// asks again (native Face ID sheet) on next use — nothing breaks.
/// NOTE: money is deliberately absent here — transactions are confirmed
/// per transaction and never stored as a permission (fase-3 rule 2).
struct Brc100GrantsView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var grants: [Brc100GrantInfo] = []
    @State private var note = ""

    private var byOrigin: [(origin: String, items: [Brc100GrantInfo])] {
        Dictionary(grouping: grants, by: { $0.origin })
            .map { (origin: $0.key, items: $0.value) }
            .sorted { $0.origin < $1.origin }
    }

    var body: some View {
        List {
            Section {
                InlineAlert(kind: .success, text: note)
                if grants.isEmpty {
                    Text("No BRC-100 permissions granted on this account yet. When an app first asks for keys or crypto, a native Face ID sheet appears — grants you allow show up here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Money is never a stored permission: every transaction is confirmed separately with Face ID.")
            }

            ForEach(byOrigin, id: \.origin) { group in
                Section(group.origin) {
                    ForEach(group.items) { g in
                        HStack {
                            Text(g.detail).font(.callout)
                            Spacer()
                            Button(role: .destructive) {
                                store.brc100RevokeGrant(g.key)
                                note = "Permission revoked — the app will ask again on next use."
                                reload()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Revoke all for this app", role: .destructive) {
                        store.brc100RevokeAllGrants(origin: group.origin)
                        note = "All permissions for \(group.origin) revoked."
                        reload()
                    }
                    .font(.callout)
                }
            }
        }
        .ordnetBackground()
        .navigationTitle("BRC-100 permissions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
    }

    private func reload() {
        grants = store.brc100GrantsList()
    }
}
