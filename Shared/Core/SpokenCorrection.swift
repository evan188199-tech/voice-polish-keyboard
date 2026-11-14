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
        // End-of-utterance explanation only. Replacement must be explicitly present
        // in its example word, and there must be exactly one preceding target.
        let regex = try! NSRegularExpression(pattern: #"(?:^|[，,。；;]\s*)([\p{Han}A-Za-z]{1,8})(?:是|係|系)([\p{Han}A-Za-z]{2,16})(?:的|嘅)([\p{Han}A-Za-z]{1,8})[。.!！]?\s*$"#)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let oldRange = Range(match.range(at: 1), in: text),
              let exampleRange = Range(match.range(at: 2), in: text),
              let newRange = Range(match.range(at: 3), in: text),
              let clauseRange = Range(match.range, in: text)
        else { return unchanged() }
        let old = String(text[oldRange]), example = String(text[exampleRange]), replacement = String(text[newRange])
        guard replacement != old, replacement.count == old.count, occurrences(of: replacement, in: example).count == 1 else { return unchanged(true) }
        let prefix = String(text[..<clauseRange.lowerBound])
        let targets = occurrences(of: old, in: prefix)
        guard targets.count == 1, let target = targets.first else { return unchanged(true) }
        // A correction is scoped to that exact occurrence, never a global replacement.
        var body = prefix
        body.replaceSubrange(target, with: replacement)
        if text.hasSuffix("。") { body += "。" }
        else if text.hasSuffix(".") { body += "." }
        return SpokenCorrectionResult(original: text, body: body, correctedTerms: [replacement], needsConfirmation: false)
    }

    private static func occurrences(of needle: String, in text: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: needle, range: start..<text.endIndex) {
            ranges.append(range)
            start = range.upperBound
        }
        return ranges
    }
}
