import Foundation

/// Thin async wrapper around the shared loopback bridge client.
actor KeyboardBridgeClient {
    private let client = BridgeClient()

    func connect() async -> Bool {
        await client.connect()
    }

    func disconnect() async {
        await client.disconnect()
    }

    func send(
        _ command: BridgeCommand,
        polishEnabled: Bool? = nil,
        polishMode: String? = nil,
        chineseScript: String? = nil,
        jobID: UUID? = nil,
        clipboardEntries: [ClipboardEntry]? = nil
    ) async throws -> WireResponse {
        try await client.send(
            command,
            polishEnabled: polishEnabled,
            polishMode: polishMode,
            chineseScript: chineseScript,
            jobID: jobID,
            clipboardEntries: clipboardEntries
        )
    }
}
