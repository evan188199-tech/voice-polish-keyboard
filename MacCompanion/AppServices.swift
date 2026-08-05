import Foundation
import Combine

/// Process-wide services so SwiftUI App does not need @StateObject (sandbox-friendly swiftc).
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    let coordinator = VoiceSessionCoordinator()
    let settings = AppSettings()
    let menuModel = MenuBarModel()
    let settingsDraft = SettingsDraftModel()
    let mainUI = MainUIState()

    private init() {}
}

@MainActor
final class SettingsDraftModel: ObservableObject {
    @Published var draftName = ""
    @Published var draftBaseURL = ""
    @Published var draftModelName = ""
    @Published var draftAPIKey = ""
    @Published var saveBanner: String?
    @Published var testMessage: String?
    @Published var testSucceeded: Bool?
    @Published var isTesting = false
}

@MainActor
final class MainUIState: ObservableObject {
    @Published var modelReady = false
    @Published var activating = false
}
