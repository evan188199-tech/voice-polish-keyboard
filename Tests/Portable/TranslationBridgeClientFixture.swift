import Foundation

// A serialized per-connection fixture: no networking and no real user data.
enum BridgeCommand { case translation }
struct FixtureBridgeResponse { let outcome: Outcome; let text: String?
    enum Outcome { case text }
}
struct FixtureWireResponse { let response: FixtureBridgeResponse }
actor TranslationBridgeFixtureHub {
    static let shared = TranslationBridgeFixtureHub()
    private var slow: CheckedContinuation<Void, Never>?
    private(set) var slowStarted = false
    private(set) var slowDisconnected = false
    private(set) var sawCancel = false
    private(set) var sawFast = false
    func handle(_ payload: TranslationBridgePayload) async throws -> TranslationBridgeReply {
        switch payload.operation {
        case .capabilities:
            return TranslationBridgeReply(capability: fixtureCapability(), event: nil, failure: nil)
        case .cancel:
            sawCancel = true
            return TranslationBridgeReply(capability: nil, event: nil, failure: nil)
        case .translateText:
            let request = payload.request!
            if request.source == "slow" {
                slowStarted = true
                await withCheckedContinuation { slow = $0 }
            } else { sawFast = true }
            return TranslationBridgeReply(capability: nil, event: TranslationEvent(context: request.context,
                source: request.source, translation: "Hello", failure: nil), failure: nil)
        }
    }
    func releaseSlow() { slow?.resume(); slow = nil }
    func recordSlowDisconnect() { slowDisconnected = true }
}
actor BridgeClient {
    private var busy = false
    private var isSlow = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func send(_ command: BridgeCommand, translationPayload: TranslationBridgePayload?, timeoutSeconds: Double) async throws -> FixtureWireResponse {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        isSlow = translationPayload?.request?.source == "slow"
        let reply = try await TranslationBridgeFixtureHub.shared.handle(translationPayload!)
        let data = try JSONEncoder().encode(reply)
        return FixtureWireResponse(response: FixtureBridgeResponse(outcome: .text, text: String(decoding: data, as: UTF8.self)))
    }
    func disconnect() async { if isSlow { await TranslationBridgeFixtureHub.shared.recordSlowDisconnect() } }
}
