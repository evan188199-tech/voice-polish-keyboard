import Foundation

actor BridgeTranslationService: TextTranslating {
    private let bridge = BridgeClient()
    private func send(_ payload: TranslationBridgePayload) async throws -> TranslationBridgeReply {
        let response = try await bridge.send(.translation, translationPayload: payload, timeoutSeconds: 20)
        guard response.response.outcome == .text, let text = response.response.text,
              let data = text.data(using: .utf8), let reply = try? JSONDecoder().decode(TranslationBridgeReply.self, from: data)
        else { throw TranslationFailure.unavailable }
        return reply
    }
    var capability: TranslationCapability {
        get async { (try? await send(TranslationBridgePayload(operation: .capabilities)).capability) ?? .unavailable }
    }
    func translate(_ request: TranslationRequest) async throws -> TranslationEvent {
        let reply = try await send(TranslationBridgePayload(operation: .translateText, request: request))
        if let failure = reply.failure { throw failure }
        guard let event = reply.event else { throw TranslationFailure.invalidResult }
        return event
    }
    func cancel(_ requestID: UUID) async {
        _ = try? await send(TranslationBridgePayload(operation: .cancel, requestID: requestID))
    }
}
