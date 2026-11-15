import XCTest
@testable import VoicePolishApp

private actor FixtureTranscriber: SpeechTranscribing {
    nonisolated let modelDisplayName = "mock"
    var isReady: Bool { true }
    var hasModelFiles: Bool { true }
    var downloadProgress: Double? { nil }
    var preparePhase: String? { nil }
    func prepareModel() async throws {}
    func removeModelFiles() async throws {}
    func transcribe(_ pcmData: Data, vocabulary: String) async throws -> String {
        let result = String(decoding: pcmData, as: UTF8.self)
        if result == "模拟识别失败" { throw URLError(.cannotDecodeContentData) }
        return result
    }
}

private actor FixturePolisher: TextPolishing {
    private(set) var calls = 0
    func polish(_ raw: String, settings: PolishingSettings) async throws -> String {
        calls += 1
        if raw == "触发失败" { throw PolishingError.noResponse }
        return settings.mode == .askLLM ? "在的" : raw
    }
}

private actor DelayedPreparationTranscriber: SpeechTranscribing {
    nonisolated let modelDisplayName = "mock-delayed"
    var isReady: Bool { false }
    var hasModelFiles: Bool { fileChecks += 1; return true }
    var downloadProgress: Double? { nil }
    var preparePhase: String? { nil }
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private(set) var starts = 0
    private(set) var fileChecks = 0
    private(set) var removals = 0
    func prepareModel() async throws {
        starts += 1
        let attempt = starts
        try await withCheckedThrowingContinuation { continuations[attempt] = $0 }
    }
    func finishPreparation(_ attempt: Int = 1) { continuations.removeValue(forKey: attempt)?.resume() }
    func removeModelFiles() async throws { removals += 1 }
    func transcribe(_ pcmData: Data, vocabulary: String) async throws -> String { "fixture" }
}
private actor DelayedPermission {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var started = false
    func request() async -> Bool {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func respond(_ allowed: Bool) { continuation?.resume(returning: allowed); continuation = nil }
}
private actor DelayedRemovalTranscriber: SpeechTranscribing {
    nonisolated let modelDisplayName = "fixture-removal"
    var isReady: Bool { true }
    var hasModelFiles: Bool { true }
    var downloadProgress: Double? { nil }
    var preparePhase: String? { nil }
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var removalStarted = false
    private(set) var preparations = 0
    func prepareModel() async throws { preparations += 1 }
    func removeModelFiles() async throws {
        removalStarted = true
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finishRemoval() { continuation?.resume(); continuation = nil }
    func transcribe(_ pcmData: Data, vocabulary: String) async throws -> String { "fixture" }
}
private actor InvalidModelTranscriber: SpeechTranscribing {
    nonisolated let modelDisplayName = "fixture-invalid"
    var isReady: Bool { false }
    var hasModelFiles: Bool { true }
    var downloadProgress: Double? { nil }
    var preparePhase: String? { nil }
    func prepareModel() async throws { throw TranscriberError.invalidModel }
    func removeModelFiles() async throws {}
    func transcribe(_ pcmData: Data, vocabulary: String) async throws -> String { "fixture" }
}

private struct FixtureTranslation: TextTranslating {
    var capability: TranslationCapability { get async {
        TranslationCapability(serviceID: "fixture", serviceLabel: "模拟翻译", isAvailable: true,
                              supportedTargets: [.english], orderedTargets: [.english], failure: nil)
    } }
    func translate(_ request: TranslationRequest) async throws -> TranslationEvent {
        guard request.context.consentServiceID == "fixture" else { throw TranslationFailure.serviceChanged }
        guard request.context.target == .english else { throw TranslationFailure.unsupportedTarget }
        return TranslationEvent(context: request.context, source: request.source, translation: "Hello", failure: nil)
    }
}

final class VoicePipelineTests: XCTestCase {
    @MainActor func testSyntheticQuestionThroughRealASRAndMockAnswer() async throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fixture = documents.appendingPathComponent("VoiceModelFixture", isDirectory: true)
        let audio = fixture.appendingPathComponent("zaibuzai.pcm")
        guard FileManager.default.fileExists(atPath: audio.path) else {
            throw XCTSkip("Synthetic question fixture was not explicitly installed")
        }
        let transcriber = SenseVoiceTranscriber(modelDir: fixture)
        try await transcriber.prepareModel()
        let suite = "real-asr-ask-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = DictationHistoryStore(defaults: defaults)
        let polisher = FixturePolisher()
        let coordinator = VoiceSessionCoordinator(transcriber: transcriber, polisher: polisher, historyStore: history)
        let port = UInt16.random(in: 50000...60000)
        let server = KeyboardBridgeServer(coordinator: coordinator, ports: [port])
        let client = BridgeClient(ports: [port])
        await server.start()
        defer { Task { await client.disconnect(); await server.stop() } }
        var connected = false
        for _ in 0..<10 {
            if await client.connect() { connected = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard connected else { return XCTFail("test bridge did not start") }
        let pcm = try Data(contentsOf: audio)
        let originalJob = coordinator.enqueueTestPCM(pcm, mode: .rewrite, enabled: false, apiKey: "")
        let questionJob = coordinator.enqueueTestPCM(pcm, mode: .askLLM, enabled: true, apiKey: "fixture")
        var outcomes: [BridgeResponse] = []
        for _ in 0..<250 where outcomes.count < 2 {
            let reply = try await client.send(.status)
            if let review = reply.response.status?.askReview {
                let confirmed = try await client.send(.confirmAskReview, jobID: review.jobID)
                XCTAssertEqual(confirmed.response.outcome, .ok)
            }
            if reply.response.outcome == .text || reply.response.outcome == .error { outcomes.append(reply.response) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard outcomes.count == 2 else { return XCTFail("both segments must finish") }
        XCTAssertEqual(outcomes.map(\.jobID), [originalJob, questionJob])
        XCTAssertEqual(outcomes[0].outcome, .text)
        XCTAssertEqual((outcomes[0].text ?? "").filter(\.isLetter), "在不在")
        XCTAssertEqual(outcomes[1].outcome, .text, outcomes[1].message ?? "expected mock answer")
        XCTAssertEqual(outcomes[1].text, "在的")
        let transcript = try XCTUnwrap(history.entries.first(where: { $0.id == questionJob })?.transcript)
        XCTAssertEqual(transcript.filter(\.isLetter), "在不在")
        let calls = await polisher.calls
        XCTAssertEqual(calls, 1, "only the question-mode segment calls the mock provider")
        let afterDelivery = try await client.send(.status)
        XCTAssertNotEqual(afterDelivery.response.outcome, .text, "the answer must not be delivered twice")
    }
    @MainActor func testPublicCantoneseAudioThroughRealPipelineAndBridge() async throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fixture = documents.appendingPathComponent("VoiceModelFixture", isDirectory: true)
        let audio = fixture.appendingPathComponent("fixture.pcm")
        guard FileManager.default.fileExists(atPath: audio.path) else {
            throw XCTSkip("Public offline model fixture was not explicitly installed")
        }
        let transcriber = SenseVoiceTranscriber(modelDir: fixture)
        try await transcriber.prepareModel()
        let suite = "real-asr-bridge-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = VoiceSessionCoordinator(transcriber: transcriber, polisher: FixturePolisher(),
                                                  historyStore: DictationHistoryStore(defaults: defaults))
        let port = UInt16.random(in: 50000...60000)
        let server = KeyboardBridgeServer(coordinator: coordinator, ports: [port])
        let client = BridgeClient(ports: [port])
        await server.start()
        defer { Task { await client.disconnect(); await server.stop() } }
        var connected = false
        for _ in 0..<10 {
            if await client.connect() { connected = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard connected else { return XCTFail("test bridge did not start") }
        let job = coordinator.enqueueTestPCM(try Data(contentsOf: audio), mode: .rewrite, enabled: false, apiKey: "")
        var outcome: BridgeResponse?
        for _ in 0..<250 {
            let reply = try await client.send(.status)
            if reply.response.outcome == .text || reply.response.outcome == .error { outcome = reply.response; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let result = try XCTUnwrap(outcome, "real ASR job did not finish")
        XCTAssertEqual(result.jobID, job)
        XCTAssertEqual(result.outcome, .text, result.message ?? "expected recognized text")
        XCTAssertFalse((result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let afterDelivery = try await client.send(.status)
        XCTAssertNotEqual(afterDelivery.response.outcome, .text, "the result must not be delivered twice")
    }
    func testPublicCantoneseAudioWithPinnedOfflineModel() async throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fixture = documents.appendingPathComponent("VoiceModelFixture", isDirectory: true)
        let audio = fixture.appendingPathComponent("fixture.pcm")
        guard FileManager.default.fileExists(atPath: audio.path) else {
            throw XCTSkip("Public offline model fixture was not explicitly installed")
        }
        let transcriber = SenseVoiceTranscriber(modelDir: fixture)
        try await transcriber.prepareModel()
        let source = try Data(contentsOf: audio)
        let result = try await transcriber.transcribe(source, vocabulary: "")
        XCTAssertFalse(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    @MainActor func testDeletionBlocksConcurrentActivationAndDownload() async throws {
        let suite = "model-deletion-race-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let transcriber = DelayedRemovalTranscriber()
        let coordinator = VoiceSessionCoordinator(transcriber: transcriber, polisher: FixturePolisher(),
            historyStore: DictationHistoryStore(defaults: defaults), requestMicrophonePermission: { true })
        let removal = Task { try await coordinator.deleteModel() }
        for _ in 0..<100 {
            if await transcriber.removalStarted { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard await transcriber.removalStarted else { removal.cancel(); return XCTFail("deletion did not start") }
        do { try await coordinator.downloadModel(); XCTFail("download must not overlap deletion") }
        catch TranscriberError.modelDeleting { }
        catch { XCTFail("unexpected error: \(error)") }
        await coordinator.activate()
        XCTAssertEqual(coordinator.lastErrorCode, .modelNotReady)
        let preparations = await transcriber.preparations
        XCTAssertEqual(preparations, 0)
        await transcriber.finishRemoval()
        try await removal.value
        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertEqual(coordinator.statusMessage, "本地模型已删除")
    }
    @MainActor func testInvalidModelReportsModelNotReady() async {
        let suite = "invalid-model-status-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = VoiceSessionCoordinator(transcriber: InvalidModelTranscriber(), polisher: FixturePolisher(),
            historyStore: DictationHistoryStore(defaults: defaults), requestMicrophonePermission: { true })
        await coordinator.activate()
        XCTAssertEqual(coordinator.state, .error)
        XCTAssertEqual(coordinator.lastErrorCode, .modelNotReady)
        XCTAssertTrue(coordinator.statusMessage?.contains("重新下载") == true)
        XCTAssertFalse(coordinator.isInputReady)
    }
    func testModelDownloadRejectsErrorPagesAndEmptyFiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("model-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let url = URL(string: "https://fixture.example.test/model")!
        func response(_ status: Int, _ mime: String) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": mime])!
        }
        try Data("fixture".utf8).write(to: file)
        XCTAssertNoThrow(try ModelDownloadValidation.check(response: response(200, "application/octet-stream"), file: file))
        XCTAssertNoThrow(try ModelDownloadValidation.check(response: response(200, "text/plain"), file: file))
        XCTAssertThrowsError(try ModelDownloadValidation.check(response: response(404, "text/html"), file: file))
        XCTAssertThrowsError(try ModelDownloadValidation.check(response: response(206, "application/octet-stream"), file: file))
        XCTAssertThrowsError(try ModelDownloadValidation.check(response: response(200, "text/html; charset=utf-8"), file: file))
        XCTAssertThrowsError(try ModelDownloadValidation.check(response: nil, file: file))
        try Data().write(to: file)
        XCTAssertThrowsError(try ModelDownloadValidation.check(response: response(200, "application/octet-stream"), file: file))
    }
    func testStoredModelRejectsEmptyFilesAndHTML() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stored-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertFalse(ModelDownloadValidation.isUsableFile(file, rejectHTML: true))
        try Data().write(to: file)
        XCTAssertFalse(ModelDownloadValidation.isUsableFile(file, rejectHTML: true))
        try Data("  <!DOCTYPE HTML><html>server error</html>".utf8).write(to: file)
        XCTAssertFalse(ModelDownloadValidation.isUsableFile(file, rejectHTML: true))
        try Data([0x08, 0x01, 0xff, 0x10]).write(to: file)
        XCTAssertTrue(ModelDownloadValidation.isUsableFile(file, rejectHTML: true))
        try Data("<html token> 123".utf8).write(to: file)
        XCTAssertTrue(ModelDownloadValidation.isUsableFile(file, rejectHTML: false), "tokens are checked for existence and size, not treated as an ONNX file")
    }
    func testModelIntegrityUsesStreamingSHA256() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("model-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        XCTAssertTrue(try ModelDownloadValidation.matchesSHA256(file, expected: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        XCTAssertFalse(try ModelDownloadValidation.matchesSHA256(file, expected: AppConstants.senseVoiceModelSHA256))
    }
    func testInvalidStoredModelFailsWithoutLeavingPreparationActive() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0x08, 0x01, 0xff, 0x10]).write(to: dir.appendingPathComponent("model.int8.onnx"))
        try Data("<unk> 0\n".utf8).write(to: dir.appendingPathComponent("tokens.txt"))
        let transcriber = SenseVoiceTranscriber(modelDir: dir)
        do { try await transcriber.prepareModel(); XCTFail("invalid model must not load") }
        catch { }
        let ready = await transcriber.isReady
        let phase = await transcriber.preparePhase
        XCTAssertFalse(ready)
        XCTAssertNil(phase)
    }
    @MainActor func testRestartSharesPreparationAndDeletionWaits() async throws {
        let suite = "activation-restart-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let transcriber = DelayedPreparationTranscriber()
        let coordinator = VoiceSessionCoordinator(transcriber: transcriber, polisher: FixturePolisher(),
            historyStore: DictationHistoryStore(defaults: defaults), requestMicrophonePermission: { true })
        let first = Task { await coordinator.activate() }
        for _ in 0..<100 {
            if await transcriber.starts == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard await transcriber.starts == 1 else { first.cancel(); return XCTFail("first preparation did not start") }
        coordinator.deactivate(statusMessage: "已关闭")
        let second = Task { await coordinator.activate() }
        for _ in 0..<100 {
            if await transcriber.fileChecks >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard await transcriber.fileChecks >= 2 else { second.cancel(); return XCTFail("second activation did not reach the model") }
        let duplicate = Task { await coordinator.activate() }
        await duplicate.value
        let count = await transcriber.starts
        XCTAssertEqual(count, 1, "restarted and duplicate activation must share preparation")
        do { try await coordinator.deleteModel(); XCTFail("deletion during preparation must fail") }
        catch TranscriberError.modelPreparing { }
        catch { XCTFail("unexpected deletion error: \(error)") }
        coordinator.deactivate(statusMessage: "再次关闭")
        await transcriber.finishPreparation()
        await first.value
        await second.value
        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertEqual(coordinator.statusMessage, "再次关闭")
        XCTAssertFalse(coordinator.isInputReady)
        try await coordinator.deleteModel()
        let removals = await transcriber.removals
        XCTAssertEqual(removals, 1, "deletion succeeds after preparation completes")
    }
    @MainActor func testLatePermissionDenialCannotReopenClosedSession() async throws {
        let suite = "permission-race-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let permission = DelayedPermission()
        let coordinator = VoiceSessionCoordinator(transcriber: FixtureTranscriber(), polisher: FixturePolisher(),
            historyStore: DictationHistoryStore(defaults: defaults), requestMicrophonePermission: { await permission.request() })
        let activation = Task { await coordinator.activate() }
        for _ in 0..<100 {
            if await permission.started { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let permissionStarted = await permission.started
        guard permissionStarted else { activation.cancel(); return XCTFail("permission request did not start") }
        coordinator.deactivate(statusMessage: "已关闭")
        await permission.respond(false)
        await activation.value
        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertEqual(coordinator.statusMessage, "已关闭")
        XCTAssertNil(coordinator.lastErrorCode)
    }
    @MainActor func testDeactivationInvalidatesDelayedActivation() async throws {
        let suite = "activation-race-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let transcriber = DelayedPreparationTranscriber()
        let coordinator = VoiceSessionCoordinator(transcriber: transcriber, polisher: FixturePolisher(),
            historyStore: DictationHistoryStore(defaults: defaults), requestMicrophonePermission: { true })
        let first = Task { await coordinator.activate() }
        for _ in 0..<100 {
            if await transcriber.starts == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = await transcriber.starts
        guard started == 1 else { first.cancel(); return XCTFail("model preparation did not start") }
        let duplicate = Task { await coordinator.activate() }
        await duplicate.value
        let count = await transcriber.starts
        XCTAssertEqual(count, 1, "concurrent activation must not prepare twice")
        coordinator.deactivate(statusMessage: "已关闭")
        await transcriber.finishPreparation()
        await first.value
        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertEqual(coordinator.statusMessage, "已关闭")
        XCTAssertFalse(coordinator.isInputReady, "a stale activation must not reopen the microphone")
    }
    @MainActor func testMockTranslationTravelsOverRealBridge() async throws {
        let suite = "bridge-translation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = VoiceSessionCoordinator(transcriber: FixtureTranscriber(), polisher: FixturePolisher(),
                                                  historyStore: DictationHistoryStore(defaults: defaults))
        let port = UInt16.random(in: 50000...60000)
        let server = KeyboardBridgeServer(coordinator: coordinator, ports: [port], translationService: FixtureTranslation())
        let client = BridgeClient(ports: [port])
        await server.start()
        defer { Task { await client.disconnect(); await server.stop() } }
        var connected = false
        for _ in 0..<10 {
            if await client.connect() { connected = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard connected else { return XCTFail("test bridge did not start") }
        func send(_ payload: TranslationBridgePayload) async throws -> TranslationBridgeReply {
            let response = try await client.send(.translation, translationPayload: payload)
            let text = try XCTUnwrap(response.response.text)
            return try JSONDecoder().decode(TranslationBridgeReply.self, from: Data(text.utf8))
        }
        let capability = try await send(TranslationBridgePayload(operation: .capabilities))
        XCTAssertEqual(capability.capability?.serviceID, "fixture")
        XCTAssertEqual(capability.capability?.supportedTargets, [.english])
        let context = TranslationContext(target: .english, sourceKind: .typed, consentServiceID: "fixture")
        let request = TranslationRequest(context: context, source: "你好")
        let reply = try await send(TranslationBridgePayload(operation: .translateText, request: request))
        XCTAssertEqual(reply.event?.context, context)
        XCTAssertEqual(reply.event?.source, "你好")
        XCTAssertEqual(reply.event?.translation, "Hello")
        let wrongContext = TranslationContext(target: .english, sourceKind: .typed, consentServiceID: "other")
        let failure = try await send(TranslationBridgePayload(operation: .translateText, request: .init(context: wrongContext, source: "你好")))
        XCTAssertEqual(failure.failure, .serviceChanged)
    }
    @MainActor func testMockVoiceResultsTravelOverRealBridgeInOrder() async throws {
        let suite = "bridge-pipeline-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = VoiceSessionCoordinator(transcriber: FixtureTranscriber(), polisher: FixturePolisher(),
                                                  historyStore: DictationHistoryStore(defaults: defaults))
        let port = UInt16.random(in: 50000...60000)
        let server = KeyboardBridgeServer(coordinator: coordinator, ports: [port])
        let client = BridgeClient(ports: [port])
        await server.start()
        defer { Task { await client.disconnect(); await server.stop() } }
        var connected = false
        for _ in 0..<10 {
            if await client.connect() { connected = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard connected else { return XCTFail("test bridge did not start") }
        let disabledResponse = try await client.send(.translation, translationPayload: TranslationBridgePayload(operation: .capabilities))
        let disabledText = try XCTUnwrap(disabledResponse.response.text)
        let disabledReply = try JSONDecoder().decode(TranslationBridgeReply.self, from: Data(disabledText.utf8))
        XCTAssertEqual(disabledReply.capability?.isAvailable, false, "production default must remain disabled")
        let missing = coordinator.enqueueTestPCM(Data("在不在".utf8), mode: .askLLM, enabled: true, apiKey: "")
        let answer = coordinator.enqueueTestPCM(Data("在不在".utf8), mode: .askLLM, enabled: true, apiKey: "fixture")
        var outcomes: [BridgeResponse] = []
        for _ in 0..<100 where outcomes.count < 2 {
            let response = try await client.send(.status)
            if let review = response.response.status?.askReview {
                let confirmed = try await client.send(.confirmAskReview, jobID: review.jobID)
                XCTAssertEqual(confirmed.response.outcome, .ok)
            }
            if response.response.outcome == .text || response.response.outcome == .error { outcomes.append(response.response) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard outcomes.count == 2 else { return XCTFail("expected two bridge outcomes") }
        XCTAssertEqual(outcomes[0].jobID, missing)
        XCTAssertEqual(outcomes[0].outcome, .error)
        XCTAssertTrue(outcomes[0].message?.contains("API") == true)
        XCTAssertEqual(outcomes[1].jobID, answer)
        XCTAssertEqual(outcomes[1].outcome, .text)
        XCTAssertEqual(outcomes[1].text, "在的")
        let afterDelivery = try await client.send(.status)
        XCTAssertNotEqual(afterDelivery.response.outcome, .text, "a consumed answer must not be returned twice")
        await server.stop()
        do {
            _ = try await client.send(.ping, timeoutSeconds: 2)
            XCTFail("an existing connection must not remain usable after the bridge stops")
        } catch {
            // Stop closes the previously accepted connection.
        }
        await server.start()
        var reconnected = false
        for _ in 0..<10 {
            if await client.connect() { reconnected = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard reconnected else { return XCTFail("bridge did not reconnect after restart") }
        let restarted = try await client.send(.ping)
        XCTAssertEqual(restarted.response.outcome, .ok)
        let afterReconnect = try await client.send(.status)
        XCTAssertNotEqual(afterReconnect.response.outcome, .text, "reconnect must not replay a consumed result")
    }

    @MainActor func testMockAskPipelineReportsFailuresInOrderAndKeepsSource() async throws {
        let suite = "mock-pipeline-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = DictationHistoryStore(defaults: defaults)
        let polisher = FixturePolisher()
        let coordinator = VoiceSessionCoordinator(transcriber: FixtureTranscriber(), polisher: polisher, historyStore: history)
        let missing = coordinator.enqueueTestPCM(Data("在不在".utf8), mode: .askLLM, enabled: true, apiKey: "")
        let success = coordinator.enqueueTestPCM(Data("在不在".utf8), mode: .askLLM, enabled: true, apiKey: "fixture")
        let failure = coordinator.enqueueTestPCM(Data("触发失败".utf8), mode: .askLLM, enabled: true, apiKey: "fixture")
        let asrFailure = coordinator.enqueueTestPCM(Data("模拟识别失败".utf8), mode: .askLLM, enabled: true, apiKey: "fixture")
        let dictation = coordinator.enqueueTestPCM(Data("在不在".utf8), mode: .rewrite, enabled: false, apiKey: "")
        var delivered: [(UUID?, VoiceSessionCoordinator.JobOutcome)] = []
        for _ in 0..<100 where delivered.count < 5 {
            if let review = coordinator.askReview {
                XCTAssertTrue(coordinator.confirmAskReview(jobID: review.jobID, text: review.text))
            }
            let response = coordinator.takeBridgeOutcome(jobID: nil)
            if let outcome = response.outcome, outcome != .pending { delivered.append((response.jobID, outcome)) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(delivered.map(\.0), [missing, success, failure, asrFailure, dictation])
        guard delivered.count == 5 else { return XCTFail("five ordered outcomes required") }
        if case .failed(let message) = delivered[0].1 { XCTAssertTrue(message.contains("API")) }
        else { XCTFail("missing configuration must report a failure, not the question") }
        XCTAssertEqual(delivered[1].1, .text("在的"))
        if case .failed = delivered[2].1 {} else { XCTFail("provider failure must be visible") }
        if case .failed = delivered[3].1 {} else { XCTFail("ASR failure must be visible") }
        XCTAssertEqual(delivered[4].1, .text("在不在"), "ordinary dictation transcribes a question rather than answering it")
        XCTAssertEqual(history.entries.first(where: { $0.id == missing })?.transcript, "在不在")
        XCTAssertNil(history.entries.first(where: { $0.id == missing })?.result)
        let calls = await polisher.calls
        XCTAssertEqual(calls, 2)
    }
    func testPipelineJobKeepsOnlySafeMetadata() throws {
        let job = VoicePipelineJob(
            id: UUID(),
            sequence: 7,
            phase: .transcribing,
            createdAt: Date(timeIntervalSince1970: 1),
            recordingDurationMs: 900,
            transcriptionLatencyMs: nil,
            polishingLatencyMs: nil,
            errorCode: nil
        )
        let decoded = try JSONDecoder().decode(VoicePipelineJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(decoded.sequence, 7)
        XCTAssertEqual(decoded.phase, .transcribing)
        XCTAssertEqual(decoded.recordingDurationMs, 900)
    }

    func testVocabularyDecodesLegacyEntryAndCapsPrompt() throws {
        let legacy = #"{"id":"00000000-0000-0000-0000-000000000001","phrase":"OpenLess"}"#.data(using: .utf8)!
        let entry = try JSONDecoder().decode(VocabularyEntry.self, from: legacy)
        XCTAssertTrue(entry.isEnabled)
        XCTAssertEqual(entry.hitCount, 0)
        XCTAssertEqual(VocabularyEntry.promptVocabulary(from: [entry], maxCharacters: 20), "OpenLess")
    }

    func testCustomStyleRemainsLocalAndUsesRewriteMode() {
        let custom = StyleProfile(
            id: "test",
            name: "邮件",
            mode: .rewrite,
            customSystemPrompt: "整理成简洁邮件。",
            isBuiltin: false
        )
        XCTAssertFalse(custom.isBuiltin)
        XCTAssertEqual(custom.mode, .rewrite)
        XCTAssertTrue(StyleProfile.builtins.contains(where: { $0.id == "builtin.prompt" }))
    }

    func testDiagnosticsDoNotStoreRecognizedText() {
        let defaults = UserDefaults(suiteName: "pipeline-diagnostics-\(UUID().uuidString)")!
        PipelineDiagnostics.record(jobID: UUID(), phase: .failed, elapsedMs: 12, errorCode: .unknown, defaults: defaults)
        let event = PipelineDiagnostics.load(defaults: defaults).first
        XCTAssertEqual(event?.phase, .failed)
        XCTAssertEqual(event?.elapsedMs, 12)
        let payload = String(data: try! JSONEncoder().encode(event), encoding: .utf8) ?? ""
        XCTAssertFalse(payload.contains("transcript"))
        XCTAssertFalse(payload.contains("audio"))
    }
}

private actor AskReviewFixturePolisher: TextPolishing {
    private(set) var inputs: [String] = []
    func polish(_ raw: String, settings: PolishingSettings) async throws -> String {
        inputs.append(raw)
        return "收到"
    }
}

extension VoicePipelineTests {
    @MainActor func testAskWaitsForEditedConfirmationAndCannotBeSentTwice() async throws {
        let suite = "ask-review-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let polisher = AskReviewFixturePolisher()
        let coordinator = VoiceSessionCoordinator(transcriber: FixtureTranscriber(), polisher: polisher,
                                                  historyStore: DictationHistoryStore(defaults: defaults))
        let id = coordinator.enqueueTestPCM(Data("在不在".utf8), mode: .askLLM, enabled: true, apiKey: "fixture")
        for _ in 0..<100 where coordinator.askReview == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(coordinator.askReview?.jobID, id)
        XCTAssertEqual(coordinator.askReview?.text, "在不在")
        let before = await polisher.inputs
        XCTAssertEqual(before, [], "recognition must not reach the model before confirmation")
        XCTAssertFalse(coordinator.confirmAskReview(jobID: id, text: "  "))
        XCTAssertTrue(coordinator.confirmAskReview(jobID: id, text: "你好，在吗"))
        XCTAssertFalse(coordinator.confirmAskReview(jobID: id, text: "重复提交"))
        var result: VoiceSessionCoordinator.JobOutcome?
        for _ in 0..<100 {
            result = coordinator.takeJobOutcome(jobID: id)
            if result != nil && result != .pending { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(result, .text("收到"))
        let after = await polisher.inputs
        XCTAssertEqual(after, ["你好，在吗"])
        XCTAssertNil(coordinator.takeJobOutcome(jobID: id), "a confirmed result must be consumed once")
    }

    @MainActor func testCancelAskReviewDoesNotCallModelAndReleasesQueue() async throws {
        let suite = "ask-cancel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let polisher = AskReviewFixturePolisher()
        let coordinator = VoiceSessionCoordinator(transcriber: FixtureTranscriber(), polisher: polisher,
                                                  historyStore: DictationHistoryStore(defaults: defaults))
        let id = coordinator.enqueueTestPCM(Data("问题".utf8), mode: .askLLM, enabled: true, apiKey: "fixture")
        let next = coordinator.enqueueTestPCM(Data("下一段".utf8), mode: .rewrite, enabled: false, apiKey: "")
        for _ in 0..<100 where coordinator.askReview == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(coordinator.cancelAskReview(jobID: id))
        XCTAssertFalse(coordinator.confirmAskReview(jobID: id, text: "问题"))
        var result: VoiceSessionCoordinator.JobOutcome?
        for _ in 0..<100 {
            result = coordinator.takeJobOutcome(jobID: next)
            if result != nil && result != .pending { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(result, .text("下一段"))
        let inputs = await polisher.inputs
        XCTAssertTrue(inputs.isEmpty)
    }
}

extension VoicePipelineTests {
    @MainActor func testAskReviewAndConfirmationOverRealBridge() async throws {
        let suite = "ask-review-bridge-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let polisher = AskReviewFixturePolisher()
        let coordinator = VoiceSessionCoordinator(transcriber: FixtureTranscriber(), polisher: polisher,
                                                  historyStore: DictationHistoryStore(defaults: defaults))
        let port = UInt16.random(in: 50000...60000)
        let server = KeyboardBridgeServer(coordinator: coordinator, ports: [port])
        let client = BridgeClient(ports: [port])
        await server.start()
        defer { Task { await client.disconnect(); await server.stop() } }
        var connected = false
        for _ in 0..<10 {
            if await client.connect() { connected = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard connected else { return XCTFail("bridge did not start") }
        let id = coordinator.enqueueTestPCM(Data("在不在".utf8), mode: .askLLM, enabled: true, apiKey: "fixture")
        var review: AskReview?
        for _ in 0..<100 {
            review = try await client.send(.status).response.status?.askReview
            if review != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(review, AskReview(jobID: id, text: "在不在"))
        let before = await polisher.inputs
        XCTAssertTrue(before.isEmpty)
        let wrong = try await client.send(.confirmAskReview, jobID: UUID())
        XCTAssertEqual(wrong.response.outcome, .error)
        let confirmed = try await client.send(.confirmAskReview, jobID: id)
        XCTAssertEqual(confirmed.response.outcome, .ok)
        let duplicate = try await client.send(.confirmAskReview, jobID: id)
        XCTAssertEqual(duplicate.response.outcome, .error)
        var final: BridgeResponse?
        for _ in 0..<100 {
            let response = try await client.send(.status).response
            if response.outcome == .text { final = response; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(final?.jobID, id)
        XCTAssertEqual(final?.text, "收到")
        let after = await polisher.inputs
        XCTAssertEqual(after, ["在不在"])
        let replay = try await client.send(.status)
        XCTAssertNotEqual(replay.response.outcome, .text)
    }
}

private final class SlowFirstTimeoutURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    static func reset() { lock.lock(); defer { lock.unlock() }; requests = 0 }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; let n = Self.requests; Self.lock.unlock()
        if n == 1 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 10.2) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
            return
        }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        let body = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"测试"}}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension VoicePipelineTests {
    @MainActor func testCoordinatorAllowsTimeoutRetryToCompleteOnce() async throws {
        SlowFirstTimeoutURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowFirstTimeoutURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let suite = "retry-pipeline-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = VoiceSessionCoordinator(transcriber: FixtureTranscriber(), polisher: APITextPolisher(session: session),
                                                  historyStore: DictationHistoryStore(defaults: defaults))
        let id = coordinator.enqueueTestPCM(Data("测试".utf8), mode: .rewrite, enabled: true, apiKey: "fixture")
        var outcome: VoiceSessionCoordinator.JobOutcome?
        for _ in 0..<800 {
            outcome = coordinator.takeJobOutcome(jobID: id)
            if outcome != nil && outcome != .pending { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(outcome, .text("测试"))
        XCTAssertEqual(SlowFirstTimeoutURLProtocol.count, 2)
        XCTAssertNil(coordinator.takeJobOutcome(jobID: id))
    }
}
