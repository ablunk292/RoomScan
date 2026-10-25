import SwiftUI

@main
struct RoomScanApp: App {
    @StateObject private var store = RoomStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
        }
    }
}
