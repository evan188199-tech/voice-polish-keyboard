import SwiftUI

@main
struct VoicePolishApp: App {
    @ObservedObject private var coordinator = AppServices.shared.coordinator
    @ObservedObject private var settings = AppServices.shared.settings
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator, settings: settings)
                .onAppear {
                    coordinator.setup(settings: settings)
                }
                .onOpenURL { url in
                    guard url.scheme == "voicepolish" else { return }
                    if url.host == "review-ask" {
                        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                            .first(where: { $0.name == "job" })?.value
                        if let value, let id = UUID(uuidString: value), coordinator.askReview?.jobID == id {
                            coordinator.askEditorRequested = true
                        }
                        return
                    }
                    guard url.host == "activate-session" else { return }
                    let hostBundleID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?
                        .first(where: { $0.name == "hostBundleID" })?
                        .value
                    AppServices.shared.activateFromKeyboardAndReturn(to: hostBundleID)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        AppServices.shared.handleSceneBecameActive()
                    case .inactive, .background:
                        // Best-effort: once we leave the foreground, remember who took over.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            AppServices.shared.noteForeignFrontmostIfPossible()
                        }
                    @unknown default:
                        break
                    }
                }
        }
    }
}
