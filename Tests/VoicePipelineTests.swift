import XCTest
@testable import VoicePolishApp

final class VoicePipelineTests: XCTestCase {
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
