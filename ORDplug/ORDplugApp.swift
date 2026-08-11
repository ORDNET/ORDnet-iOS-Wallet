import SwiftUI

@main
struct ORDplugApp: App {
    @StateObject private var store = WalletStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background, .inactive:
                store.sceneBackgrounded()
            case .active:
                store.sceneActivated()
            @unknown default:
                break
            }
        }
    }
}
