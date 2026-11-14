import Foundation

// This DTO is a proposed receiver contract, not the shipping wire protocol.
struct ProposedResponse: Decodable {
    struct Metadata: Decodable {
        let schemaVersion: Int
        let disposition: String
        let rawTranscript: String?
        let reviewText: String?
    }
    let outcome: String
    let jobID: UUID?
    let text: String?
    let correctionReview: Metadata?
}
enum ReceiverDecision: Equatable { case normal, review, quarantine }
func classify(_ input: Data, expectedJobID: UUID? = nil) -> ReceiverDecision {
    guard let response = try? JSONDecoder().decode(ProposedResponse.self, from: input),
          response.outcome == "text", let responseJobID = response.jobID,
          expectedJobID == nil || expectedJobID == responseJobID, let text = response.text,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let metadata = response.correctionReview, metadata.schemaVersion == 1 else { return .quarantine }
    switch metadata.disposition {
    case "not_required":
        // A not-required signal containing review material is inconsistent.
        guard metadata.rawTranscript == nil, metadata.reviewText == nil else { return .quarantine }
        return .normal
    case "required":
        guard let raw = metadata.rawTranscript, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let review = metadata.reviewText, !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .quarantine }
        return .review
    default: return .quarantine
    }
}
@main enum ProposedWireTests {
    static func main() throws {
        var failures = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            if value() { print("PASS: \(label)") } else { failures += 1; print("FAIL: \(label)") }
        }
        let job = UUID().uuidString
        func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        func envelope(_ metadata: [String: Any]) -> [String: Any] { ["outcome": "text", "jobID": job, "text": "虚构结果", "correctionReview": metadata] }
        check(classify(data(envelope(["schemaVersion": 1, "disposition": "not_required"]))) == .normal, "explicit no-review allows ordinary dictation")
        check(classify(data(envelope(["schemaVersion": 1, "disposition": "required", "rawTranscript": "虚构原始转写", "reviewText": "虚构核对文本"]))) == .review, "required review includes job-bound source and review text")
        check(classify(data(["outcome": "text", "jobID": job, "text": "虚构结果"])) == .quarantine, "legacy missing field is unknown")
        check(classify(data(["outcome": "text", "text": "虚构结果", "correctionReview": ["schemaVersion": 1, "disposition": "not_required"]])) == .quarantine, "missing job identity is unknown")
        check(classify(data(envelope(["schemaVersion": 1, "disposition": "required", "rawTranscript": "", "reviewText": "虚构核对文本"]))) == .quarantine, "empty raw transcription never fabricates review")
        check(classify(data(envelope(["schemaVersion": 1, "disposition": "required", "rawTranscript": "虚构原始转写"]))) == .quarantine, "missing review text is unknown")
        check(classify(data(envelope(["schemaVersion": 1, "disposition": "not_required", "rawTranscript": "虚构原始转写"]))) == .quarantine, "inconsistent no-review metadata is rejected")
        check(classify(data(envelope(["schemaVersion": 1, "disposition": "not_required"])), expectedJobID: UUID()) == .quarantine, "mismatched requested job identity is quarantined")
        check(classify(data(["outcome": "ok", "jobID": job, "text": "虚构结果", "correctionReview": ["schemaVersion": 1, "disposition": "not_required"]])) == .quarantine, "non-text outcome cannot authorize delivery")
        check(classify(data(envelope(["schemaVersion": 2, "disposition": "not_required"]))) == .quarantine, "unknown version is quarantined")
        check(classify(data(envelope(["schemaVersion": 1, "disposition": "unknown"]))) == .quarantine, "explicit unknown is quarantined")
        check(classify(data(["outcome": "text", "jobID": job, "text": "", "correctionReview": ["schemaVersion": 1, "disposition": "not_required"]])) == .quarantine, "empty result is not deliverable")
        if failures > 0 { print("FAILED: \(failures)"); exit(1) }
        print("Proposed receiver contract fixtures passed; not connected to shipping wire")
    }
}
