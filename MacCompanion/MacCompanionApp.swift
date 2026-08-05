import SwiftUI
import AppKit

@main
struct MacCompanionApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    private let services = AppServices.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                coordinator: services.coordinator,
                settings: services.settings,
                menuModel: services.menuModel
            )
        } label: {
            Label(services.menuModel.title, systemImage: services.menuModel.symbolName)
        }

        Settings {
            MacSettingsView(
                settings: services.settings,
                coordinator: services.coordinator,
                draft: services.settingsDraft
            )
            .frame(minWidth: 480, minHeight: 420)
        }

        Window("粤英语音", id: "main") {
            MacMainView(
                coordinator: services.coordinator,
                settings: services.settings,
                ui: services.mainUI
            )
            .frame(minWidth: 520, minHeight: 480)
        }
        .defaultSize(width: 560, height: 560)
    }
}
