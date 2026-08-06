import AppIntents
import UIKit

/// Starts the voice session, then returns to the previously active app (e.g. WeChat / Notes).
struct ActivateVoiceSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "启动语音会话"
    static let description = IntentDescription(
        "启动粤英语音键盘的语音会话，开启麦克风和桥接服务，然后回到刚才的应用。"
    )
    /// Keep previous app frontmost long enough to capture its bundle ID, then open ourselves.
    /// (`true` makes Action Button lose WeChat/Notes and often drop to Home on suspend.)
    static let openAppWhenRun: Bool = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let services = AppServices.shared

        // 1) Control Center briefly remains frontmost after the user taps the
        // shortcut. Wait for it to collapse, then capture WeChat / Notes below it.
        let capturedTarget = await AppSwitcher.waitForReturnTarget()
        services.rememberReturnTarget(capturedTarget)

        // 2) Bring host app up — mic / model load needs a reliable active session.
        _ = await services.bringHostAppToForeground()

        services.coordinator.setup(settings: services.settings)

        switch services.coordinator.state {
        case .inactive, .error:
            await services.coordinator.activate()
        case .ready, .recording, .transcribing, .polishing:
            break
        }

        switch services.coordinator.state {
        case .ready, .recording, .transcribing, .polishing:
            // Silent result — no "完成" sheet. Return runs after intent completes.
            services.scheduleReturnToPreviousApp()
            return .result()
        case .inactive, .error:
            services.cancelReturnToPreviousApp()
            // Keep the app open so the user can fix model / mic permission issues.
            throw ActivateVoiceSessionError.failed(
                services.coordinator.statusMessage
                    ?? "启动失败，请检查模型与麦克风权限"
            )
        }
    }
}

enum ActivateVoiceSessionError: Error, CustomLocalizedStringResourceConvertible {
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .failed(let message):
            LocalizedStringResource(stringLiteral: message)
        }
    }
}
