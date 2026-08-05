import AppKit
import ApplicationServices

/// Boots companion services as soon as the process launches (menu-bar apps may never open the main window).
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    private let services = AppServices.shared
    private var didBootstrap = false
    private var hotkeyObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        bootstrapIfNeeded()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        bootstrapIfNeeded()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotkeyObserver {
            NotificationCenter.default.removeObserver(hotkeyObserver)
        }
        RightOptionHotkeyService.shared.stop()
        services.coordinator.deactivate()
    }

    private func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true

        services.coordinator.setup(settings: services.settings)
        services.menuModel.bind(coordinator: services.coordinator)

        if services.settings.launchAtLogin {
            LaunchAtLoginHelper.setEnabled(true)
        }

        // Primary self-use path on macOS 27 beta when InputMethodKit is not listed by TIS.
        RightOptionHotkeyService.shared.bind(coordinator: services.coordinator)
        applyRightOptionHotkey(enabled: services.settings.rightOptionHotkeyEnabled)

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .voicePolishRightOptionHotkeyEnabledDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let enabled = (note.userInfo?["enabled"] as? Bool)
                ?? self?.services.settings.rightOptionHotkeyEnabled
                ?? true
            Task { @MainActor in
                self?.applyRightOptionHotkey(enabled: enabled)
            }
        }

        Task {
            await MacModelSeeder.seedIfNeeded()
            await services.coordinator.refreshModelPresence()
            await services.coordinator.activate()
        }
    }

    private func applyRightOptionHotkey(enabled: Bool) {
        if enabled {
            RightOptionHotkeyService.shared.start()
            RightOptionHotkeyService.shared.ensureAccessibilityPrompt()
        } else {
            // Turning off listening should also release a stuck hold-to-talk.
            if services.coordinator.state == .recording {
                services.coordinator.cancelRecording()
            }
            RightOptionHotkeyService.shared.stop()
        }
    }
}
