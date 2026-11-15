import Foundation

struct SpokenCorrectionResult: Equatable, Sendable {
    let original: String
    let body: String
    let correctedTerms: [String]
    let needsConfirmation: Bool
}

struct SpokenCorrectionSuggestion: Equatable, Sendable {
    let original: String
    let corrected: String
    let target: String
    let replacement: String
}

/// Only edits the current undelivered transcript; it never reads or changes host text.
enum SpokenCorrection {
    /// Produces a preview for a user-selected local draft; it never edits the
    /// draft or reads a host app. Ambiguous or quoted input is left untouched.
    static func suggest(explanation: String, draft: String) -> SpokenCorrectionSuggestion? {
        guard !FaithfulTextFormatter.isProtected(draft), !FaithfulTextFormatter.isProtected(explanation),
              !["解释", "解釋", "引用", "逐字", "原话", "原話", "他说", "他說", "佢話", "她说", "她說", "不是", "唔係", "并非", "並非"].contains(where: explanation.contains)
        else { return nil }
        let pattern = #"^\s*([\p{Han}A-Za-z]{1,8})(?:是|係|系)([\p{Han}A-Za-z]{2,16})(?:的|嘅)([\p{Han}A-Za-z]{1,8})[。.!！]?\s*$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: explanation, range: NSRange(explanation.startIndex..., in: explanation)),
              let oldRange = Range(match.range(at: 1), in: explanation),
              let exampleRange = Range(match.range(at: 2), in: explanation),
              let newRange = Range(match.range(at: 3), in: explanation) else { return nil }
        let target = String(explanation[oldRange])
        let example = String(explanation[exampleRange])
        let replacement = String(explanation[newRange])
        let positions = occurrences(of: target, in: draft)
        guard target.count == replacement.count, occurrences(of: replacement, in: example).count == 1,
              positions.count == 1, let position = positions.first else { return nil }
        var corrected = draft
        corrected.replaceSubrange(position, with: replacement)
        return SpokenCorrectionSuggestion(original: draft, corrected: corrected, target: target, replacement: replacement)
    }

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
        // Two separately spelled characters, e.g. “志是智慧的智，明是明天的明”.
        // Only use a uniquely matching adjacent pair; homophones elsewhere remain ambiguous.
        let namePattern = #"[，,。；;]\s*([\p{Han}])(?:是|係|系)([\p{Han}]{2,8})(?:的|嘅)([\p{Han}])[，,、\s]+([\p{Han}])(?:是|係|系)([\p{Han}]{2,8})(?:的|嘅)([\p{Han}])[。.!！]?\s*$"#
        let nameRegex = try! NSRegularExpression(pattern: namePattern)
        if let match = nameRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let clause = Range(match.range, in: text) {
            let groups = (1...6).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
            guard groups.count == 6,
                  occurrences(of: groups[2], in: groups[1]).count == 1,
                  occurrences(of: groups[5], in: groups[4]).count == 1,
                  let firstSound = mandarinSound(groups[2]), let secondSound = mandarinSound(groups[5]),
                  mandarinSound(groups[0]) == firstSound, mandarinSound(groups[3]) == secondSound
            else { return unchanged(true) }
            let prefix = String(text[..<clause.lowerBound])
            let characters = Array(prefix.indices)
            var candidates: [Range<String.Index>] = []
            if characters.count >= 2 {
                for i in 0..<(characters.count - 1) {
                    let first = String(prefix[characters[i]])
                    let second = String(prefix[characters[i + 1]])
                    if mandarinSound(first) == firstSound && mandarinSound(second) == secondSound {
                        candidates.append(characters[i]..<prefix.index(after: characters[i + 1]))
                    }
                }
            }
            guard candidates.count == 1, let target = candidates.first else { return unchanged(true) }
            let replacement = groups[2] + groups[5]
            var body = prefix
            body.replaceSubrange(target, with: replacement)
            if text.hasSuffix("。") { body += "。" }
            else if text.hasSuffix(".") { body += "." }
            return SpokenCorrectionResult(original: text, body: body, correctedTerms: [replacement], needsConfirmation: false)
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
        guard replacement.count == old.count, occurrences(of: replacement, in: example).count == 1 else { return unchanged(true) }
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

    private static func mandarinSound(_ text: String) -> String? {
        guard text.count == 1, let scalar = text.unicodeScalars.first,
              (0x4E00...0x9FFF).contains(scalar.value),
              let latin = text.applyingTransform(.mandarinToLatin, reverse: false) else { return nil }
        return latin.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased()
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
