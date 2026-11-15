import Foundation

protocol KeyboardBridgeServing: Sendable {
    func connect() async -> Bool
    func disconnect() async
    func request(_ command: BridgeCommand, polishEnabled: Bool?, polishMode: String?,
                 chineseScript: String?, jobID: UUID?, clipboardEntries: [ClipboardEntry]?) async throws -> WireResponse
}

extension KeyboardBridgeServing {
    func send(_ command: BridgeCommand, polishEnabled: Bool? = nil, polishMode: String? = nil,
              chineseScript: String? = nil, jobID: UUID? = nil,
              clipboardEntries: [ClipboardEntry]? = nil) async throws -> WireResponse {
        try await request(command, polishEnabled: polishEnabled, polishMode: polishMode,
                          chineseScript: chineseScript, jobID: jobID, clipboardEntries: clipboardEntries)
    }
}

/// Thin async wrapper around the shared loopback bridge client.
actor KeyboardBridgeClient: KeyboardBridgeServing {
    private let client = BridgeClient()

    func connect() async -> Bool {
        await client.connect()
    }

    func disconnect() async {
        await client.disconnect()
    }

    func request(
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
