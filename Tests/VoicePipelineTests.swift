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

final class VoicePipelineTests: XCTestCase {
    @MainActor func testMicrophoneDenialStopsBeforeModelPreparation() async {
        let suite = "permission-denied-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let transcriber = DelayedPreparationTranscriber()
        let coordinator = VoiceSessionCoordinator(transcriber: transcriber, polisher: FixturePolisher(),
            historyStore: DictationHistoryStore(defaults: defaults), requestMicrophonePermission: { false })
        await coordinator.activate()
        XCTAssertEqual(coordinator.state, .error)
        XCTAssertEqual(coordinator.lastErrorCode, .micDenied)
        XCTAssertFalse(coordinator.isInputReady)
        let starts = await transcriber.starts
        XCTAssertEqual(starts, 0)
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
        catch TranscriberError.invalidModel { }
        catch { XCTFail("expected invalid-model error, received \(error)") }
        let ready = await transcriber.isReady
        let phase = await transcriber.preparePhase
        XCTAssertFalse(ready)
        XCTAssertNil(phase)
    }
    func testBridgeReviewMetadataIsPerResponseAndLegacyCompatible() throws {
        let first = UUID(), second = UUID()
        let firstResponse = BridgeResponse.text("小明", jobID: first, rawTranscript: "小明，不对，是晓明", correctionReviewRequired: true)
        let secondResponse = BridgeResponse.text("今天天晴", jobID: second, rawTranscript: "今天天晴", correctionReviewRequired: false)
        let firstDecoded = try JSONDecoder().decode(BridgeResponse.self, from: JSONEncoder().encode(firstResponse))
        let secondDecoded = try JSONDecoder().decode(BridgeResponse.self, from: JSONEncoder().encode(secondResponse))
        XCTAssertEqual(firstDecoded.jobID, first)
        XCTAssertEqual(firstDecoded.rawTranscript, "小明，不对，是晓明")
        XCTAssertEqual(firstDecoded.correctionReviewRequired, true)
        XCTAssertEqual(secondDecoded.jobID, second)
        XCTAssertEqual(secondDecoded.rawTranscript, "今天天晴")
        XCTAssertEqual(secondDecoded.correctionReviewRequired, false)
        let legacy = try JSONDecoder().decode(BridgeResponse.self, from: Data(#"{"outcome":"text","text":"旧结果"}"#.utf8))
        XCTAssertNil(legacy.rawTranscript)
        XCTAssertNil(legacy.correctionReviewRequired)
        XCTAssertNil(BridgeResponse.error("失败").rawTranscript)
    }
    func testVoiceStageDiagnosticsRemainBoundedAndContainOnlyFixedMarkers() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-stages-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        for _ in 0..<42 { VoiceStageDiagnostics.record(.micRequested, url: file) }
        VoiceStageDiagnostics.record(.captureEmpty, url: file)
        let stages = VoiceStageDiagnostics.load(url: file)
        XCTAssertEqual(stages.count, 40)
        XCTAssertEqual(stages.last, .captureEmpty)
        XCTAssertTrue(stages.allSatisfy { $0 == .micRequested || $0 == .captureEmpty })
    }
    func testSkippedFailuresRetainOrderAndCanBeConsumedOnce() {
        var queue = OrderedFailureIDs()
        let first = UUID(), second = UUID()
        queue.append(first); queue.append(second); queue.append(first)
        XCTAssertEqual(queue.ids, [first, second])
        XCTAssertTrue(queue.allows(first))
        XCTAssertFalse(queue.allows(second))
        XCTAssertFalse(queue.allows(UUID()))
        queue.remove(first)
        XCTAssertEqual(queue.first, second)
        XCTAssertTrue(queue.allows(second))
        queue.remove(first)
        XCTAssertEqual(queue.ids, [second])
        queue.remove(second)
        XCTAssertNil(queue.first)
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
