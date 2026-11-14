import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAIL: \(label)") }
    print("PASS: \(label)")
}
func waitForTranslationTest(_ ms: UInt64 = 40) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
func fixtureCapability() -> TranslationCapability {
    TranslationCapability(serviceID: "fixture-service", serviceLabel: "虚构本地 mock", isAvailable: true,
        supportedTargets: TranslationTarget.choices, orderedTargets: TranslationTarget.choices, failure: nil)
}
actor ControlledTranslator: TextTranslating {
    var capability: TranslationCapability { get async { fixtureCapability() } }
    var requests: [TranslationRequest] = []
    var pending: [UUID: CheckedContinuation<TranslationEvent, Error>] = [:]
    func translate(_ request: TranslationRequest) async throws -> TranslationEvent {
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending[request.context.id] = $0 }
    }
    func finish(_ id: UUID, text: String? = nil, failure: TranslationFailure? = nil) {
        guard let continuation = pending.removeValue(forKey: id), let request = requests.first(where: { $0.context.id == id }) else { return }
        if let failure { continuation.resume(throwing: failure) }
        else { continuation.resume(returning: TranslationEvent(context: request.context, source: request.source, translation: text, failure: nil)) }
    }
    func count() -> Int { requests.count }
    func firstID() -> UUID? { requests.first?.context.id }
}
actor CapturingPolisher: TextPolishing {
    var calls = 0
    var seenSettings: PolishingSettings?
    var seenSource = ""
    var response: String
    init(response: String) { self.response = response }
    func polish(_ raw: String, settings: PolishingSettings) async throws -> String {
        calls += 1; seenSettings = settings; seenSource = raw; return response
    }
    func snapshot() -> (Int, PolishingSettings?, String) { (calls, seenSettings, seenSource) }
}
final class TranslationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var networkFailure: URLError.Code?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let code = Self.networkFailure { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor func model(_ service: any TextTranslating, timeout: UInt64 = 1_000_000_000,
                      defaults: UserDefaults? = nil) async -> TranslationViewModel {
    let m = TranslationViewModel(service: service, defaults: defaults ?? UserDefaults(suiteName: "translation-\(UUID())")!, timeoutNanoseconds: timeout)
    await m.appear(hasFullAccess: true)
    return m
}
func context(_ target: TranslationTarget = .english, kind: TranslationSourceKind = .typed,
             mode: TranslationDeliveryMode = .automatic) -> TranslationContext {
    TranslationContext(target: target, sourceKind: kind, deliveryMode: mode, consentServiceID: "fixture-service")
}

// Pure gesture policy: no audio or API can start from an unselected/cancelled hold.
check(TranslationSpeakGesture.ended(elapsed: 0.1, horizontal: 0, vertical: 0, width: 300, targetCount: 3, canTranslate: true) == .dictate, "single tap is ordinary dictation")
for (elapsed, x, y) in [(0.6,0.0,0.0),(0.2,0.0,-80.0),(0.6,160.0,-80.0),(0.6,0.0,80.0)] {
    check(TranslationSpeakGesture.ended(elapsed: elapsed, horizontal: x, vertical: y, width: 300, targetCount: 3, canTranslate: true) == .none, "cancel/short/sideways/downward gesture never starts translation")
}
check(TranslationSpeakGesture.ended(elapsed: 0.5, horizontal: -100, vertical: -60, width: 300, targetCount: 3, canTranslate: true) == .translate(0), "hold up and select first target")
check(TranslationSpeakGesture.ended(elapsed: 0.5, horizontal: 100, vertical: -60, width: 300, targetCount: 3, canTranslate: true) == .translate(2), "hold up and select third target")
check(TranslationSpeakGesture.ended(elapsed: 0.5, horizontal: 0, vertical: -60, width: 300, targetCount: 0, canTranslate: true) == .none, "empty targets never start capture")
check(TranslationSpeakGesture.ended(elapsed: 0.5, horizontal: 0, vertical: -60, width: 300, targetCount: 3, canTranslate: false) == .none, "unavailable service never starts capture")
let english = TranslationTarget.english
check(english.script == nil && english.instruction.contains("Output English"), "English target has no forced Chinese script")
check(TranslationTarget.traditionalHK.language == .chinese && TranslationTarget.traditionalHK.script == .traditionalHK, "language and script are independent")
let preferencesDefaults = UserDefaults(suiteName: "translation-targets-\(UUID())")!
let preferences = TranslationPreferences(defaults: preferencesDefaults)
preferences.remove(.simplified); preferences.move(from: 1, to: 0); preferences.add(.simplified); preferences.add(.simplified)
preferences.consent(to: "fixture-service")
let reloaded = TranslationPreferences(defaults: preferencesDefaults)
check(reloaded.targets == [.traditionalHK, .english, .simplified] && reloaded.consentServiceID == "fixture-service", "target add/delete/order/dedup and service consent survive restart")

let service = ControlledTranslator()
let m = await model(service)
var inserted: [String] = []
m.onInsert = { inserted.append($0) }
m.editSource("明天不要出發")
let id1 = m.submitTyped()!
check(m.submitTyped() == nil, "duplicate Translate click cannot submit twice")
await waitForTranslationTest()
m.editSource("后天才出发")
let id2 = m.submitTyped()!
await waitForTranslationTest()
await service.finish(id1, text: "Do not leave tomorrow.")
await waitForTranslationTest()
check(inserted.isEmpty && m.draft.translation == nil, "edited source blocks late original response")
await service.finish(id2, text: "Leave the day after tomorrow.")
await waitForTranslationTest()
check(inserted == ["Leave the day after tomorrow."] && !m.draft.previewCanInsert, "normal success inserts directly once without preview gate")
check(m.submitTyped() == nil, "repeated Translate after immediate success cannot insert the unchanged draft twice")
m.insertPreview()
check(inserted.count == 1, "auto-insert result cannot be inserted a second time via preview")
m.editSource("hello")
let changedLanguageID = m.submitTyped()!
await waitForTranslationTest()
m.chooseTarget(.traditionalHK)
await service.finish(changedLanguageID, text: "hello")
await waitForTranslationTest()
check(inserted.count == 1 && m.draft.translation == nil, "target change invalidates old request")
m.chooseTarget(.english); m.editSource("您好")
m.previewBeforeInsert = true
let previewID = m.submitTyped()!
await waitForTranslationTest(); await service.finish(previewID, text: "Hello."); await waitForTranslationTest()
check(inserted.count == 1 && m.draft.previewCanInsert, "preview is optional and withholds only when requested")
m.insertPreview(); m.insertPreview()
check(inserted.last == "Hello." && inserted.count == 2, "explicit optional preview inserts once")
m.editSource("原文保留")
let cancelledID = m.submitTyped()!
await waitForTranslationTest(); m.cancelDraft(); await service.finish(cancelledID, text: "Preserve original."); await waitForTranslationTest()
check(m.draft.source == "原文保留" && m.draft.translation == nil && inserted.count == 2, "cancel preserves source and blocks ignored-cancellation response")
m.insertOriginal(); m.insertOriginal()
check(inserted.count == 3 && inserted.last == "原文保留", "explicit original insertion is distinct from translation and guarded against repeat")
m.disappear()

let voiceService = ControlledTranslator()
let voice = await model(voiceService)
var voiceInserted: [String] = []
voice.onInsert = { voiceInserted.append($0) }
let v1 = voice.prepareVoice(target: .english)!, v2 = voice.prepareVoice(target: .traditionalHK)!
voice.receiveVoiceSource("聽日唔好走", contextID: v1.id)
voice.receiveVoiceSource("Keep API", contextID: v2.id)
await waitForTranslationTest()
let firstVoiceCount = await voiceService.count()
check(firstVoiceCount == 1, "voice queue processes FIFO even with multiple submitted segments")
await voiceService.finish(v1.id, text: "Do not leave tomorrow."); await waitForTranslationTest()
await voiceService.finish(v2.id, text: "保留 API"); await waitForTranslationTest()
check(voiceInserted == ["Do not leave tomorrow.", "保留 API"], "voice targets are snapshotted and deliver once in order")
voice.receiveVoiceSource("重複 ASR 回包", contextID: v1.id)
await waitForTranslationTest()
check(voiceInserted.count == 2, "duplicate ASR result cannot translate or deliver again")
let hidden = voice.prepareVoice(target: .english)!
voice.receiveVoiceSource("保留未交付原文", contextID: hidden.id)
await waitForTranslationTest(); voice.disappear(); await voiceService.finish(hidden.id, text: "Retain undelivered original."); await waitForTranslationTest()
check(voiceInserted.count == 2 && voice.lastEvent?.source == "保留未交付原文", "host/appearance change blocks insertion and preserves current voice source")

let timeoutService = ControlledTranslator()
let timed = await model(timeoutService, timeout: 20_000_000)
timed.editSource("保留超时原文")
let timedID = timed.submitTyped()!
await waitForTranslationTest(70)
check(timed.draft.failure == .timeout && timed.draft.source == "保留超时原文" && timed.draft.translation == nil, "timeout resolves even when provider ignores cancellation")
await timeoutService.finish(timedID, text: "Late text."); await waitForTranslationTest()
check(timed.draft.translation == nil, "late timeout completion is ignored")
timed.disappear()

let unavailable = await model(DisabledTranslationService())
var unavailableInsertions = 0
unavailable.onInsert = { _ in unavailableInsertions += 1 }
unavailable.editSource("离线原文")
check(unavailable.submitTyped() == nil && unavailable.draft.translation == nil && unavailable.draft.source == "离线原文", "no backend preserves source without faking a translation")
await unavailable.appear(hasFullAccess: false)
check(unavailable.capability.failure == .noFullAccess && unavailable.prepareVoice(target: .english) == nil && unavailableInsertions == 0, "Full Access is a transport gate, never microphone authorization")
unavailable.disappear()
let empty = await model(ControlledTranslator())
check(empty.submitTyped() == nil && empty.draft.failure == .emptySource, "empty source never submits")
empty.editSource(String(repeating: "字", count: 4000))
check(empty.submitTyped() == nil && empty.draft.failure == .inputTooLong && empty.draft.source.count == 4000, "UTF-8 byte limit keeps full source without request or truncation")
empty.disappear()

let rebuildingDefaults = UserDefaults(suiteName: "translation-rebuild-\(UUID())")!
let rebuildingService = ControlledTranslator()
let beforeRebuild = await model(rebuildingService, defaults: rebuildingDefaults)
beforeRebuild.editSource("保留重建原文")
let rebuildRequest = beforeRebuild.submitTyped()!
await waitForTranslationTest()
beforeRebuild.disappear()
await rebuildingService.finish(rebuildRequest, text: "Original retained.")
let afterRebuild = await model(rebuildingService, defaults: rebuildingDefaults)
var rebuildInsertions = 0
afterRebuild.onInsert = { _ in rebuildInsertions += 1 }
check(afterRebuild.draft.source == "保留重建原文" && afterRebuild.draft.translation == nil && !afterRebuild.draft.previewCanInsert && rebuildInsertions == 0, "keyboard object reconstruction restores source without stale translation insertion")
afterRebuild.disappear()
for reason in [TranslationFailure.offline, .rejected, .rateLimited, .emptyResult, .truncated, .invalidResult] {
    // Use the model's own injected service for a deterministic provider failure.
    let controlled = ControlledTranslator(), failureModel = await model(controlled)
    failureModel.editSource("完整原文")
    var failuresInserted = 0
    failureModel.onInsert = { _ in failuresInserted += 1 }
    let id = failureModel.submitTyped()!
    await waitForTranslationTest()
    await controlled.finish(id, failure: reason)
    await waitForTranslationTest()
    check(failureModel.draft.source == "完整原文" && failureModel.draft.translation == nil && failureModel.draft.failure == reason && failuresInserted == 0, "provider failure retains original and never auto-inserts source")
    failureModel.disappear()
}

let identityService = ControlledTranslator(), identityModel = await model(identityService)
let hostA = UUID(), hostB = UUID()
await identityModel.appear(hasFullAccess: true, hostSessionID: hostA)
var identityInsertions = 0
identityModel.onInsert = { _ in identityInsertions += 1 }
identityModel.editSource("不要写入另一个输入框")
let hostRequest = identityModel.submitTyped()!
await waitForTranslationTest()
await identityModel.appear(hasFullAccess: true, hostSessionID: hostB)
await identityService.finish(hostRequest, text: "Do not insert into another field.")
await waitForTranslationTest()
check(identityInsertions == 0, "explicit host-document identity change blocks stale insertion even without hide")
identityModel.disappear()

let fixtureText = "2026-11-14，不要改 -3.5，预算 $20，保留 `API_KEY` 和 {{name}} https://example.test/a"
let fixtureTranslation = "On 2026-11-14, do not change -3.5; budget $20. Keep `API_KEY` and {{name}} https://example.test/a"
check(!TranslationContentGuard.validate(source: "Only text", translation: "Only text with 1000 https://example.test/new"), "added numeric facts and links are rejected")
check(TranslationContentGuard.validate(source: fixtureText, translation: fixtureTranslation), "valid bilingual fixture preserves signs, decimals, date, currency, code, placeholder and URL")
for mutation in [fixtureTranslation.replacingOccurrences(of: "-3.5", with: "35"), fixtureTranslation.replacingOccurrences(of: "2026-11-14", with: "20261114"), fixtureTranslation.replacingOccurrences(of: "`API_KEY`", with: "`API`"), fixtureTranslation.replacingOccurrences(of: "{{name}}", with: "name"), fixtureTranslation.replacingOccurrences(of: "https://example.test/a", with: "https://example.test/b")] {
    check(!TranslationContentGuard.validate(source: fixtureText, translation: mutation), "protected token/numeric mutation is rejected")
}

let response = #"{"target":"en","translation":"Do not leave tomorrow."}"#
let provider = CapturingPolisher(response: response)
let baseSettings = PolishingSettings(baseURL: "https://fixture.invalid", modelName: "mock", apiKey: "fixture-only", mode: .askLLM, chineseScript: .traditionalHK,
    askHistory: [AskConversationTurn(user: "old", assistant: "history")])
let adapter = ConfiguredTranslationService(provider: provider, settings: baseSettings, serviceID: "fixture-service", serviceLabel: "mock",
    verifiedTargets: TranslationTarget.choices, userEnabled: true, allowRequests: true)
let request = TranslationRequest(context: context(), source: "聽日唔好走")
let translated = try! await adapter.translate(request)
let snapshot = await provider.snapshot()
check(translated.translation == "Do not leave tomorrow." && snapshot.1?.chineseScript == nil && snapshot.1?.askHistory.isEmpty == true && snapshot.1?.mode == .rewrite, "translation bypasses ask history and global Chinese-script constraints")
check(snapshot.1?.styleSystemPrompt?.contains("Output English") == true && snapshot.2.contains("source_text"), "translation prompt treats input as data and uses explicit English target")
let disabledAdapter = ConfiguredTranslationService(provider: provider, settings: baseSettings, serviceID: "fixture-service", serviceLabel: "mock",
    verifiedTargets: TranslationTarget.choices, userEnabled: true)
do { _ = try await disabledAdapter.translate(request); check(false, "real calls default disabled") }
catch { check(error as? TranslationFailure == .unavailable, "allowRequests defaults false even with configured credentials") }
let notEnabledAdapter = ConfiguredTranslationService(provider: provider, settings: baseSettings, serviceID: "fixture-service", serviceLabel: "mock", verifiedTargets: [.english], userEnabled: false, allowRequests: true)
do { _ = try await notEnabledAdapter.translate(request); check(false, "consent gate") }
catch { check(error as? TranslationFailure == .notEnabled, "user enablement is required before provider invocation") }
let noKey = PolishingSettings(baseURL: "https://fixture.invalid", modelName: "mock", apiKey: "")
let missingAdapter = ConfiguredTranslationService(provider: provider, settings: noKey, serviceID: "fixture-service", serviceLabel: "mock", verifiedTargets: [.english], userEnabled: true, allowRequests: true)
do { _ = try await missingAdapter.translate(request); check(false, "missing configuration") }
catch { check(error as? TranslationFailure == .missingConfiguration, "empty key never reaches provider") }
let englishOnly = ConfiguredTranslationService(provider: provider, settings: baseSettings, serviceID: "fixture-service", serviceLabel: "mock", verifiedTargets: [.english], userEnabled: true, allowRequests: true)
do { _ = try await englishOnly.translate(TranslationRequest(context: context(.traditionalHK), source: "Hello")); check(false, "unsupported target") }
catch { check(error as? TranslationFailure == .unsupportedTarget, "unsupported target is rejected before request") }
let changedConsent = TranslationContext(target: .english, sourceKind: .typed, consentServiceID: "other-service")
do { _ = try await adapter.translate(TranslationRequest(context: changedConsent, source: "Hello")); check(false, "service consent binding") }
catch { check(error as? TranslationFailure == .serviceChanged, "consent is bound to the selected service") }
let hugeSource = TranslationRequest(context: context(), source: String(repeating: "字", count: 4000))
do { _ = try await adapter.translate(hugeSource); check(false, "oversize adapter guard") }
catch { check(error as? TranslationFailure == .inputTooLong, "adapter checks UTF-8 size before provider") }
for bad in [#"{"target":"en","translation":""}"#, #"{"target":"zh-Hans","translation":"text"}"#, "text without envelope"] {
    do { _ = try ConfiguredTranslationService.parse(bad, target: .english); check(false, "malformed envelope") }
    catch { check(true, "empty/wrong-language/unstructured provider output is not accepted") }
}
let snapshotAfter = await provider.snapshot()
check(snapshotAfter.0 == 1, "unavailable adapter never invokes provider")
for target in [TranslationTarget.simplified, .traditionalHK] {
    let value = target == .simplified ? "明天不要出发。" : "聽日唔好出發。"
    let json = try! JSONSerialization.data(withJSONObject: ["target": target.code, "translation": value])
    check(try! ConfiguredTranslationService.parse(String(data: json, encoding: .utf8)!, target: target) == value, "mock English-to-Chinese target envelope parses without script masquerading")
}
for target in [TranslationTarget.simplified, .traditionalHK] {
    let text = target == .simplified ? "明天不要出发。" : "聽日唔好出發。"
    let data = try! JSONSerialization.data(withJSONObject: ["target": target.code, "translation": text])
    let mock = CapturingPolisher(response: String(data: data, encoding: .utf8)!)
    let chineseAdapter = ConfiguredTranslationService(provider: mock, settings: baseSettings, serviceID: "fixture-service", serviceLabel: "mock", verifiedTargets: TranslationTarget.choices, userEnabled: true, allowRequests: true)
    let result = try! await chineseAdapter.translate(TranslationRequest(context: context(target), source: "Do not leave tomorrow."))
    check(result.translation == text, "injected provider translates English into the explicitly selected Chinese script")
}
let mockConfig = URLSessionConfiguration.ephemeral
mockConfig.protocolClasses = [TranslationURLProtocol.self]
let mockSession = URLSession(configuration: mockConfig)
let httpAdapter = ConfiguredTranslationService(provider: APITextPolisher(session: mockSession), settings: baseSettings, serviceID: "fixture-service", serviceLabel: "local HTTP mock",
    verifiedTargets: TranslationTarget.choices, userEnabled: true, allowRequests: true)
TranslationURLProtocol.body = #"{"choices":[{"finish_reason":"length","message":{"content":"truncated"}}]}"#.data(using: .utf8)!
do { _ = try await httpAdapter.translate(request); check(false, "truncation must fail") }
catch { check(error as? TranslationFailure == .truncated, "mock truncated HTTP completion maps to failure") }
TranslationURLProtocol.statusCode = 429
TranslationURLProtocol.body = Data()
do { _ = try await httpAdapter.translate(request); check(false, "quota must fail") }
catch { check(error as? TranslationFailure == .rateLimited, "mock HTTP quota/limit never returns original as translation") }
for (code, expected) in [(URLError.Code.notConnectedToInternet, TranslationFailure.offline), (.timedOut, .timeout)] {
    TranslationURLProtocol.networkFailure = code
    do { _ = try await httpAdapter.translate(request); check(false, "network failure") }
    catch { check(error as? TranslationFailure == expected, "HTTP mock network/timeout maps to explicit unavailable failure") }
}
TranslationURLProtocol.networkFailure = nil
mockSession.invalidateAndCancel()
print("Translation checkpoint completed: logic/mock only; no iOS build, ASR, live translation or host insertion test.")
