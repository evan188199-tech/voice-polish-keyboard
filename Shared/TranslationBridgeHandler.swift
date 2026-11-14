import Foundation

/// Uses only an explicitly supplied service. Production remains disabled by default.
struct TranslationBridgeHandler: Sendable {
    let service: any TextTranslating
    func handle(_ payload: TranslationBridgePayload, targets: [TranslationTarget]) async -> TranslationBridgeReply {
        switch payload.operation {
        case .capabilities:
            let capability = await service.capability
            let ordered = targets.filter { $0.isValid }
            return TranslationBridgeReply(capability: TranslationCapability(serviceID: capability.serviceID,
                serviceLabel: capability.serviceLabel, isAvailable: capability.isAvailable,
                supportedTargets: capability.supportedTargets, orderedTargets: ordered, failure: capability.failure), event: nil, failure: nil)
        case .translateText:
            guard let request = payload.request else { return TranslationBridgeReply(capability: nil, event: nil, failure: .invalidResult) }
            do {
                let event = try await service.translate(request)
                guard event.context == request.context, event.source == request.source else { throw TranslationFailure.invalidResult }
                return TranslationBridgeReply(capability: nil, event: event, failure: nil)
            } catch {
                return TranslationBridgeReply(capability: nil, event: nil, failure: (error as? TranslationFailure) ?? .unavailable)
            }
        case .cancel:
            if let id = payload.requestID { await service.cancel(id) }
            return TranslationBridgeReply(capability: nil, event: nil, failure: nil)
        }
    }
}
