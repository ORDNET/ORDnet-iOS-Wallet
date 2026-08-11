import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: WalletStore

    var body: some View {
        switch store.phase {
        case .loading:
            ProgressView()
        case .setup:
            SetupView()
        case .locked:
            UnlockView()
        case .unlocked:
            MainTabView()
        }
    }
}

// v2.3.2 — the UNTOUCHED native Apple tab bar is back, with exactly five
// tabs (the user's layout): Wallet · Browser · Domains · Upload · ORD/ner.
// Settings and the UTXO tools moved to the top bar of the Wallet screen,
// on the lock button's line (see HomeView's toolbar).
enum AppTab: String {
    case wallet, browser, domains, upload, ordner
}

struct MainTabView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var tab: AppTab = .wallet

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { HomeView() }
                .tabItem { Label("Wallet", systemImage: "wallet.bifold") }
                .tag(AppTab.wallet)
            NavigationStack { BrowserView() }
                .tabItem { Label("Browser", systemImage: "safari") }
                .tag(AppTab.browser)
            NavigationStack { DomainsView() }
                .tabItem { Label("Domains", systemImage: "tag") }
                .tag(AppTab.domains)
            NavigationStack { UploadView() }
                .tabItem { Label("Upload", systemImage: "square.and.arrow.up") }
                .tag(AppTab.upload)
            NavigationStack { OrdnerView() }
                .tabItem { Label("ORD/ner", systemImage: "folder") }
                .tag(AppTab.ordner)
        }
        // dApp approval requests (from the .web3 browser) surface as a sheet
        .sheet(item: Binding(
            get: { store.pendingProviderRequest },
            set: { store.pendingProviderRequest = $0 }
        )) { req in
            ApprovalView(request: req)
        }
        // v2.5 — BRC-100 permission prompt: native sheet + Face ID, outside
        // the page's reach (per-app/per-protocol grants, BRC-43)
        .sheet(item: Binding(
            get: { store.pendingBrc100Permission },
            set: { store.pendingBrc100Permission = $0 }
        )) { req in
            Brc100PermissionView(request: req)
        }
        // v2.6 — BRC-100 fase 3: per-transactie bevestiging (geld ≠ grant,
        // nooit persistent, altijd Face ID)
        .sheet(item: Binding(
            get: { store.pendingBrc100TxConfirm },
            set: { store.pendingBrc100TxConfirm = $0 }
        )) { req in
            Brc100TxConfirmView(request: req)
        }
        // ORD/ner "Open in Browser" → switch to the Browser tab (which loads it)
        .onChange(of: store.browserOpenRequest) { _, v in
            if v != nil { tab = .browser }
        }
    }
}

// MARK: - Unlock

struct UnlockView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var error = ""
    @State private var busy = false
    @State private var confirmRemove = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            OrdplugLogo(size: 72)
            Text("ORD/net Wallet").font(.title2.weight(.bold))
            Text("Unlock with Face ID — or your device passcode as fallback")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            InlineAlert(kind: .error, text: error)
                .padding(.horizontal)

            Button {
                unlock()
            } label: {
                if busy {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label("Unlock", systemImage: "faceid").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .disabled(busy)

            Spacer()

            if confirmRemove {
                VStack(spacing: 10) {
                    Text("Removing the wallet deletes the keys from this device. Coins are only recoverable with your recovery phrase or WIF backup.")
                        .font(.footnote)
                        .foregroundStyle(Theme.statusRed)
                        .multilineTextAlignment(.center)
                    HStack {
                        Button("Keep wallet") { confirmRemove = false }
                            .buttonStyle(.ordnetOutline)
                        Button("Remove wallet", role: .destructive) { store.removeWallet() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            } else {
                Button("Can't unlock? Remove wallet…") { confirmRemove = true }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ordnetBackground()
        .task { unlock() }   // prompt Face ID immediately on appear
    }

    private func unlock() {
        guard !busy else { return }
        busy = true
        error = ""
        Task {
            do {
                try await store.unlock()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
