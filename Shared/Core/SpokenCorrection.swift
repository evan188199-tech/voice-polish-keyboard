import Foundation

struct SpokenCorrectionResult: Equatable, Sendable {
    let original: String
    let body: String
    let correctedTerms: [String]
    let needsConfirmation: Bool
}

/// Only edits the current undelivered transcript; it never reads or changes host text.
enum SpokenCorrection {
    static func process(_ text: String, mode: PolishMode) -> SpokenCorrectionResult {
        func unchanged(_ uncertain: Bool = false) -> SpokenCorrectionResult {
            SpokenCorrectionResult(original: text, body: text, correctedTerms: [], needsConfirmation: uncertain)
        }
        guard mode != .coding, mode != .askLLM, !FaithfulTextFormatter.isProtected(text) else { return unchanged() }
        let reporting = ["解释", "解釋", "引用", "逐字", "原话", "原話", "他說", "他说", "佢話", "她说", "她說"]
        guard !reporting.contains(where: text.contains) else { return unchanged() }
        // An explicitly bounded temporal self-correction; no general deletion of “不是”.
        if let regex = try? NSRegularExpression(pattern: #"^不是(今天|明天|後天|后天|昨天)[，,]\s*是((?:今天|明天|後天|后天|昨天).+)$"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 2), in: text) {
            return SpokenCorrectionResult(original: text, body: String(text[range]), correctedTerms: [], needsConfirmation: false)
        }
        guard !["不是", "唔係", "并非", "並非", "不要改", "唔好改"].contains(where: text.contains) else { return unchanged() }
        // A plain ASR transcript cannot establish which written characters a
        // speaker intended, even when the recognized spellings differ. Do not
        // silently execute oral edit commands: retain all words for review.
        let spokenEdit = try! NSRegularExpression(pattern: #"(?:^|[，,。；;]\s*)(?:把|将|將)([\p{Han}A-Za-z]{1,8})(?:改成|改为|改為|改做)([\p{Han}A-Za-z]{1,8})[。.!！]?\s*$"#)
        if spokenEdit.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return unchanged(true)
        }
        // Even an example-word explanation is only an ASR hypothesis: the
        // recognizer may have chosen plausible but incorrect characters. Keep
        // it intact and let the job-bound review UI ask the user explicitly.
        let spelling = try! NSRegularExpression(pattern: #"(?:^|[，,。；;]\s*)([\p{Han}A-Za-z]{1,8})(?:是|係|系)([\p{Han}A-Za-z]{2,16})(?:的|嘅)([\p{Han}A-Za-z]{1,8})[。.!！]?\s*$"#)
        guard spelling.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return unchanged() }
        return unchanged(true)
    }

}
