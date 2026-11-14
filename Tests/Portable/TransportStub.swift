import Foundation
// The production adapter is compiled, but every test injects MockKeyboardBridge.
// Any accidental network use fails, without opening a socket or making API calls.
actor BridgeClient {
    func connect() async -> Bool { false }
    func disconnect() async {}
    func send(_ command: BridgeCommand, polishEnabled: Bool?, polishMode: String?,
              chineseScript: String?, jobID: UUID?, clipboardEntries: [ClipboardEntry]?) async throws -> WireResponse {
        fatalError("Tests must inject a mock bridge")
    }
}
