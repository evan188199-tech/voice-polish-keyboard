import Foundation

/// Conservative layout rules, not semantic summarization. No text is truncated.
enum FaithfulTextFormatter {
    static func isProtected(_ text: String) -> Bool {
        text.contains("`") || text.contains("/") || text.contains("\\")
            || text.contains("{") || text.contains("}") || text.contains("=")
            || text.contains("\"") || text.contains("'") || text.contains("“") || text.contains("”")
            || text.contains("‘") || text.contains("’") || text.contains("「") || text.contains("」")
            || text.contains("『") || text.contains("』")
    }

    static func format(_ text: String, mode: PolishMode) -> String {
        guard mode != .coding, mode != .askLLM, !isProtected(text), !text.isEmpty else { return text }
        if let list = explicitList(text) { return list }
        // Existing paragraphs and short narration stay as dictated. For long narration,
        // group three Chinese sentences without guessing topics or adding bullets.
        guard text.count >= 160, !text.contains("\n") else { return text }
        var output = ""
        var sentences = 0
        let characterCount = text.count
        for (index, character) in text.enumerated() {
            output.append(character)
            if "。！？".contains(character) {
                sentences += 1
                if sentences % 3 == 0, index < characterCount - 1 { output += "\n\n" }
            }
        }
        return output
    }

    private static func explicitList(_ text: String) -> String? {
        let pattern = #"第([一二三四五六七八九])(點|点|件事|步|項|项)?[、，,:：\s]*"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count >= 2, matches.count <= 9,
              let first = matches.first, let prefixRange = Range(NSRange(location: 0, length: first.range.location), in: text)
        else { return nil }
        let prefix = String(text[prefixRange])
        guard prefix.range(of: #"([有共分][一二三四五六七八九十0-9]+[件項项點点步]|事項|事项|清單|清单|步驟|步骤)"#, options: .regularExpression) != nil
        else { return nil }
        let numbers = Array("一二三四五六七八九")
        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range(at: 1), in: text), String(text[range]) == String(numbers[index]) else { return nil }
        }
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,；;：:"))
        var result = prefix.trimmingCharacters(in: trim) + "："
        for (index, match) in matches.enumerated() {
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : (text as NSString).length
            guard let range = Range(NSRange(location: start, length: end - start), in: text) else { return nil }
            var item = String(text[range]).trimmingCharacters(in: trim)
            guard !item.isEmpty else { return nil }
            if index == matches.count - 1,
               let extra = item.range(of: #"另外(?=預算|预算|注意|補充|补充|不要|唔好|請|请|限制|需|要)"#, options: .regularExpression) {
                item.insert(contentsOf: "\n\n", at: extra.lowerBound)
            }
            result += "\n\(index + 1). " + item
        }
        return result
    }

    /// Strict mode accepts layout changes only: lexical order and every token survive.
    /// This is intentionally conservative; rejected provider output falls back locally.
    static func preservesContent(_ candidate: String, source: String) -> Bool {
        signature(candidate) == signature(source) && preservesNumbers(candidate, source: source)
    }

    private static func withoutListMarkers(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?m)^\s*[1-9][.)、][ \t]+"#, with: "", options: .regularExpression)
    }

    private static func signature(_ text: String) -> String {
        String(withoutListMarkers(text).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Lexical checks alone discard punctuation and would accept -3.5 as 35.
    /// Exact tokens deliberately reject ambiguous numeric rewrites rather than
    /// claiming to verify their meaning. List markers are generated layout.
    static func preservesNumbers(_ candidate: String, source: String) -> Bool {
        numericTokens(candidate) == numericTokens(source)
    }

    /// Negation can change the meaning of an entire clause. When an explicit
    /// marker occurs, allow punctuation/layout changes but preserve lexical
    /// order so that the marker cannot silently move to another clause.
    static func preservesExplicitNegation(_ candidate: String, source: String) -> Bool {
        let sourceMarkers = negationTokens(source)
        let candidateMarkers = negationTokens(candidate)
        guard sourceMarkers == candidateMarkers else { return false }
        return sourceMarkers.isEmpty || signature(candidate) == signature(source)
    }

    private static func negationTokens(_ text: String) -> [String] {
        let pattern = #"[不無无沒没未勿莫唔冇毋非别別]|(?<![A-Za-z0-9_])(?:no|not|never|neither|nor|without|cannot|none|nobody|nothing|nowhere)(?![A-Za-z0-9_])"#
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() }
    }

    private static func numericTokens(_ text: String) -> [String] {
        let input = withoutListMarkers(text)
        let regex = try! NSRegularExpression(pattern: #"(?:[+\-−＋－][ \t]*)?(?:\p{N}+(?:[.,]\p{N}+)*|[.,]\p{N}+)|[$€£¥￥%％]"#)
        let ns = input as NSString
        return regex.matches(in: input, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}

struct DictationTextPreparation: Sendable {
    let original: String
    let body: String
    let strictLayout: Bool
    let correctionNeedsConfirmation: Bool
    let literalContent: Bool
    let protectNumbers: Bool

    init(_ text: String, mode: PolishMode) {
        original = text
        let correction = SpokenCorrection.process(text, mode: mode)
        body = FaithfulTextFormatter.format(correction.body, mode: mode)
        correctionNeedsConfirmation = correction.needsConfirmation
        literalContent = mode == .coding || FaithfulTextFormatter.isProtected(text)
        protectNumbers = mode != .askLLM
        strictLayout = mode != .askLLM && (text.count >= 120 || body != text || correction.needsConfirmation || mode == .coding || FaithfulTextFormatter.isProtected(text))
    }

    func accept(_ candidate: String) -> Bool {
        !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!protectNumbers || FaithfulTextFormatter.preservesNumbers(candidate, source: body))
            && (!protectNumbers || FaithfulTextFormatter.preservesExplicitNegation(candidate, source: body))
            && (!literalContent || candidate == body)
            && (!strictLayout || FaithfulTextFormatter.preservesContent(candidate, source: body))
    }
}
