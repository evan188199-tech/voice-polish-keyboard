import Foundation

/// One app-owned bridge service. It starts disabled and never loads credentials.
/// A caller must supply an explicitly constructed transport and approved config.
actor TranslationServiceRegistry: TextTranslating {
    private var service: any TextTranslating = DisabledTranslationService()
    private var generation: UInt64 = 0

    func currentGeneration() -> UInt64 { generation }

    /// Linearize the final send with configuration changes and revocation.
    /// The closure must only enqueue the response and must not suspend.
    func publishIfCurrent(_ expected: UInt64, _ publish: @Sendable () -> Void) -> Bool {
        guard generation == expected else { return false }
        publish()
        return true
    }

    /// Bind each bridge request to the service selected at its captured generation.
    func handle(_ payload: TranslationBridgePayload, targets: [TranslationTarget], generation expected: UInt64) async -> TranslationBridgeReply {
        guard generation == expected else {
            return TranslationBridgeReply(capability: nil, event: nil, failure: .serviceChanged)
        }
        let current = service
        let reply = await TranslationBridgeHandler(service: current).handle(payload, targets: targets)
        guard generation == expected else {
            return TranslationBridgeReply(capability: nil, event: nil, failure: .serviceChanged)
        }
        return reply
    }

    func configure(_ configuration: TranslationFactoryConfiguration,
                   transport: any TranslationHTTPTransport) async {
        generation &+= 1
        let expected = generation
        let old = service
        service = DisabledTranslationService()
        if let managed = old as? ManagedTranslationService { await managed.revoke() }
        guard generation == expected else { return }
        service = TranslationServiceFactory.make(configuration: configuration, transport: transport)
    }

    func revoke() async {
        generation &+= 1
        let old = service
        service = DisabledTranslationService()
        if let managed = old as? ManagedTranslationService { await managed.revoke() }
    }

    var capability: TranslationCapability { get async {
        let expected = generation
        let current = service
        let value = await current.capability
        return expected == generation ? value : .unavailable
    } }

    func translate(_ request: TranslationRequest) async throws -> TranslationEvent {
        let expected = generation
        let current = service
        let event = try await current.translate(request)
        guard generation == expected else { throw TranslationFailure.serviceChanged }
        return event
    }

    func cancel(_ requestID: UUID) async { await service.cancel(requestID) }
}
