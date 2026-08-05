import SwiftUI

@main
struct VoicePolishApp: App {
    @StateObject private var coordinator = VoiceSessionCoordinator()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator, settings: settings)
                .onAppear {
                    coordinator.setup(settings: settings)
                }
        }
    }
}
