import Foundation
// The production adapter is compiled, but every test injects MockKeyboardBridge.
// Any accidental network use fails, without opening a socket or making API calls.
actor BridgeClient {
    func connect() async -> Bool { false }
    func disconnect() async {}
    func send(_ command: BridgeCommand, polishEnabled: Bool? = nil, polishMode: String? = nil,
              chineseScript: String? = nil, jobID: UUID? = nil, clipboardEntries: [ClipboardEntry]? = nil,
              translationPayload: TranslationBridgePayload? = nil, timeoutSeconds: Double = 4) async throws -> WireResponse {
        fatalError("Tests must inject a mock bridge")
    }
}
