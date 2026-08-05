import Foundation
import AppKit

/// Thin bridge client + companion auto-launch for the input method.
actor BridgeSessionClient {
    static let companionBundleID = "com.voicepolish.mac"

    private let client = BridgeClient()
    private var launching = false

    func ensureConnected(launchCompanionIfNeeded: Bool = true) async -> Bool {
        if await client.connect() { return true }
        guard launchCompanionIfNeeded else { return false }
        await launchCompanion()
        // Retry a few times while the companion boots.
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if await client.connect() { return true }
        }
        return false
    }

    func send(
        _ command: BridgeCommand,
        polishEnabled: Bool? = nil,
        polishMode: String? = nil,
        chineseScript: String? = nil,
        jobID: UUID? = nil
    ) async throws -> WireResponse {
        try await client.send(
            command,
            polishEnabled: polishEnabled,
            polishMode: polishMode,
            chineseScript: chineseScript,
            jobID: jobID
        )
    }

    func disconnect() async {
        await client.disconnect()
    }

    private func launchCompanion() async {
        if launching { return }
        launching = true
        defer { launching = false }

        await MainActor.run {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.companionBundleID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
                return
            }
            // Fallback: ~/Applications/VoicePolishMac.app
            let home = FileManager.default.homeDirectoryForCurrentUser
            let fallback = home.appendingPathComponent("Applications/VoicePolishMac.app")
            if FileManager.default.fileExists(atPath: fallback.path) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: fallback, configuration: config) { _, _ in }
            }
        }
    }
}
