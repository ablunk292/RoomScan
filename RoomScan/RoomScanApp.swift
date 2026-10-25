import SwiftUI

@main
struct RoomScanApp: App {
    @StateObject private var store = PropertyStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
        }
    }
}
