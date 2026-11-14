import Foundation

@main enum FlatCorrectionWireChecks {
    static func main() {
        var failures = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) { if value() { print("PASS: \(label)") } else { failures += 1; print("FAIL: \(label)") } }
        func fields(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
        let id = UUID(), raw = "明天联系小明，把小明改成晓明。"
        check(CorrectionWireDisposition.classify(jobID: id, text: "普通文字", encodedResponse: fields(["correctionReviewRequired": false])) == .normal, "explicit false allows normal dictation")
        check(CorrectionWireDisposition.classify(jobID: id, text: "结果", encodedResponse: fields(["correctionReviewRequired": true, "rawTranscript": raw])) == .review(rawTranscript: raw), "required review preserves matching raw transcript")
        check(CorrectionWireDisposition.classify(jobID: id, text: "结果", encodedResponse: fields([:])) == .unknown, "old bridge without flag is quarantined")
        check(CorrectionWireDisposition.classify(jobID: nil, text: "结果", encodedResponse: fields(["correctionReviewRequired": false])) == .unknown, "missing job ID is quarantined")
        check(CorrectionWireDisposition.classify(jobID: id, text: "结果", encodedResponse: fields(["correctionReviewRequired": true])) == .unknown, "required without raw is quarantined")
        check(CorrectionWireDisposition.classify(jobID: id, text: "结果", encodedResponse: fields(["correctionReviewRequired": true, "rawTranscript": "  "])) == .unknown, "empty raw is quarantined")
        check(CorrectionWireDisposition.classify(jobID: id, text: "结果", encodedResponse: fields(["correctionReviewRequired": false, "rawTranscript": raw])) == .unknown, "negative flag contradicting correction text is quarantined")
        check(CorrectionWireDisposition.classify(jobID: id, text: raw, encodedResponse: fields(["correctionReviewRequired": false])) == .unknown, "negative flag contradicting visible correction is quarantined")
        check(CorrectionWireDisposition.classify(jobID: id, text: "", encodedResponse: fields(["correctionReviewRequired": false])) == .unknown, "empty text never accepted")
        check(CorrectionWireDisposition.classify(jobID: id, text: "结果", encodedResponse: fields(["correctionReviewRequired": "false"])) == .unknown, "wrong flag type is quarantined")
        if failures > 0 { print("FAILED: \(failures)"); exit(1) }
        print("Flat correction metadata fixtures passed; no production wire diff integrated")
    }
}
