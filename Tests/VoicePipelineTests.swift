import XCTest
@testable import VoicePolishApp

final class VoicePipelineTests: XCTestCase {
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
