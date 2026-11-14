import Foundation

// Stand-ins for unrelated protocol payloads; BridgeResponse itself is real.
struct ClipboardEntry: Codable, Sendable {}
struct PlaceNameSuggestion: Codable, Sendable {}
struct TranslationBridgePayload: Codable, Sendable {}
enum AppConstants { static let protocolVersion: UInt16 = 1 }

@main enum FlatCorrectionWireChecks {
    static func main() throws {
        var failures = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) { if value() { print("PASS: \(label)") } else { failures += 1; print("FAIL: \(label)") } }
        func classify(_ response: BridgeResponse) -> CorrectionWireDisposition {
            CorrectionWireDisposition.classify(jobID: response.jobID, text: response.text ?? "", rawTranscript: response.rawTranscript, correctionReviewRequired: response.correctionReviewRequired)
        }
        let id = UUID(), raw = "明天联系小明，把小明改成晓明。"
        let a = BridgeResponse.text("结果", jobID: id, rawTranscript: raw, correctionReviewRequired: true)
        let b = BridgeResponse.text("普通文字", jobID: UUID(), rawTranscript: "普通文字", correctionReviewRequired: false)
        let decodedA = try JSONDecoder().decode(BridgeResponse.self, from: JSONEncoder().encode(a))
        let decodedB = try JSONDecoder().decode(BridgeResponse.self, from: JSONEncoder().encode(b))
        check(classify(decodedA) == .review(rawTranscript: raw), "required metadata survives real wire round trip")
        check(classify(decodedB) == .normal, "separate false marker preserves normal dictation")
        let legacy = try JSONDecoder().decode(BridgeResponse.self, from: Data(#"{"outcome":"text","text":"旧结果"}"#.utf8))
        check(classify(legacy) == .unknown, "old bridge without flag and job is quarantined")
        check(classify(.text("结果", jobID: id)) == .unknown, "missing flag is quarantined")
        check(classify(.text("结果", correctionReviewRequired: false)) == .unknown, "missing job ID is quarantined")
        check(classify(.text("结果", jobID: id, correctionReviewRequired: true)) == .unknown, "required without raw is quarantined")
        check(classify(.text("结果", jobID: id, rawTranscript: " ", correctionReviewRequired: true)) == .unknown, "empty raw is quarantined")
        check(classify(.text("结果", jobID: id, rawTranscript: raw, correctionReviewRequired: false)) == .unknown, "negative flag contradicting correction text is quarantined")
        check(classify(.text(raw, jobID: id, correctionReviewRequired: false)) == .unknown, "negative flag contradicting visible correction is quarantined")
        check(classify(.text("", jobID: id, correctionReviewRequired: false)) == .unknown, "empty text is quarantined")
        let spelling = "明天联系小明，小明是黄晓明的晓明。"
        let prepared = DictationTextPreparation(spelling, mode: .rewrite)
        let spellingWire = BridgeResponse.text(prepared.body, jobID: UUID(), rawTranscript: prepared.original,
                                               correctionReviewRequired: prepared.correctionNeedsConfirmation)
        let spellingDecoded = try JSONDecoder().decode(BridgeResponse.self, from: JSONEncoder().encode(spellingWire))
        check(classify(spellingDecoded) == .review(rawTranscript: spelling),
              "conservative homophone formatter passes original and review flag through actual wire")
        let failure = BridgeResponse.error("失败")
        check(failure.rawTranscript == nil && failure.correctionReviewRequired == nil, "failure does not fabricate correction fields")
        let pending = BridgeResponse.ok()
        check(pending.rawTranscript == nil && pending.correctionReviewRequired == nil, "waiting response does not fabricate correction fields")
        if failures > 0 { print("FAILED: \(failures)"); exit(1) }
        print("Real BridgeResponse wire and classifier fixtures passed")
    }
}
