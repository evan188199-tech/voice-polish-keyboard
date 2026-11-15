import Foundation

actor BridgeTranslationService: TextTranslating {
    private func send(_ payload: TranslationBridgePayload) async throws -> TranslationBridgeReply {
        // Each request has its own serialized connection so a slow translation
        // cannot block cancellation or a later request on the client side.
        let bridge = BridgeClient()
        do {
            let response = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await bridge.send(.translation, translationPayload: payload, timeoutSeconds: 20)
            } onCancel: {
                Task { await bridge.disconnect() }
            }
            await bridge.disconnect()
            guard response.response.outcome == .text, let text = response.response.text,
                  let data = text.data(using: .utf8), let reply = try? JSONDecoder().decode(TranslationBridgeReply.self, from: data)
            else { throw TranslationFailure.unavailable }
            return reply
        } catch {
            await bridge.disconnect()
            throw error
        }
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
