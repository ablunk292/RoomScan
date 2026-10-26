import SwiftUI

@main
struct RoomScanApp: App {
    @StateObject private var store = PropertyStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .onAppear { CloudSync.shared.attach(store) }
        }
        .onChange(of: scenePhase) {
            // Pick up changes made on the web when the app comes back, and send ours when it leaves.
            if scenePhase == .active || scenePhase == .background {
                Task { await CloudSync.shared.sync() }
            }
        }
    }
}
