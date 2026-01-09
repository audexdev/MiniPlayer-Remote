import SwiftUI

@main
struct MiniPlayerRemoteApp: App {
    @StateObject private var controller = MusicAgentController()
    @StateObject private var locationKeeper = LocationKeeper()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .environmentObject(locationKeeper)
        }
    }
}
