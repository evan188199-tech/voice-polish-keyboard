import Foundation
import Network

// Fixture-only definitions; production bridge and translation clients are compiled unchanged.
enum AppConstants {
    static let protocolVersion: UInt16 = 3
    static let bridgePorts: [UInt16] = [UInt16.random(in: 50000...60000)]
}
enum BuildToken { static func generate() -> String { "fixture" } }
struct ClipboardEntry: Codable, Sendable { let text: String }
struct PlaceNameSuggestion: Codable, Sendable { let text: String }

actor Observations {
    var slowStarted = false
    var slowFinished = false
    var cancelReceived = false
    var fastReceived = false
    func snapshot() -> (Bool, Bool, Bool, Bool) { (slowStarted, slowFinished, cancelReceived, fastReceived) }
    func startSlow() { slowStarted = true }
    func finishSlow() { slowFinished = true }
    func recordCancel() { cancelReceived = true }
    func recordFast() { fastReceived = true }
}
func check(_ value: Bool, _ message: String) {
    guard value else { fatalError("FAIL: \(message)") }
    print("PASS: \(message)")
}
let observed = Observations()
let server = BridgeServer(ports: AppConstants.bridgePorts) { message, connection in
    guard let payload = message.translationPayload else { return }
    Task {
        if payload.operation == .translateText, let request = payload.request, request.source == "slow" {
            await observed.startSlow()
            return // Deliberately leave this connection waiting for cancellation.
        }
        let reply: TranslationBridgeReply
        if payload.operation == .cancel {
            await observed.recordCancel()
            reply = TranslationBridgeReply(capability: nil, event: nil, failure: nil)
        } else if let request = payload.request {
            await observed.recordFast()
            reply = TranslationBridgeReply(capability: nil, event: TranslationEvent(context: request.context,
                source: request.source, translation: "Hello", failure: nil), failure: nil)
        } else { return }
        guard let encoded = try? JSONEncoder().encode(reply), let text = String(data: encoded, encoding: .utf8) else { return }
        BridgeServer.send(response: WireResponse(requestID: message.requestID, response: .text(text)), over: connection)
    }
}
server.start()
defer { server.stop() }
let service = BridgeTranslationService()
let context = TranslationContext(target: .english, sourceKind: .typed, consentServiceID: "fixture")
let slow = Task {
    _ = try? await service.translate(TranslationRequest(context: context, source: "slow"))
    await observed.finishSlow()
}
for _ in 0..<100 {
    if await observed.snapshot().0 { break }
    try await Task.sleep(nanoseconds: 20_000_000)
}
check(await observed.snapshot().0, "slow request reached the real loopback server")
let cancel = Task { await service.cancel(context.id) }
let fastContext = TranslationContext(target: .english, sourceKind: .typed, consentServiceID: "fixture")
let fast = Task { try await service.translate(TranslationRequest(context: fastContext, source: "fast")) }
slow.cancel()
for _ in 0..<100 {
    let state = await observed.snapshot()
    if state.1 && state.2 && state.3 { break }
    try await Task.sleep(nanoseconds: 20_000_000)
}
let state = await observed.snapshot()
check(state.1, "cancellation finishes the real TCP client request promptly")
check(state.2 && state.3, "cancel and subsequent translation reach the server while the first request is held")
let fastReply = try await fast.value
check(fastReply.translation == "Hello", "subsequent translation returns through the real TCP bridge")
await cancel.value
