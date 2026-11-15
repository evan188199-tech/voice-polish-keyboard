import Foundation

/// Checks exact protected literals, not same-character equality or semantic accuracy.
/// Names, Chinese written numerals, negation, idiom and tone still require review.
enum TranslationContentGuard {
    static func validate(source: String, translation: String) -> Bool {
        guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let patterns = [#"https?://[^\s<>，。]+"#, #"`[^`]+`"#, #"\{\{[^}]+\}\}|\$\{[^}]+\}|%\d*\$?[sd@]"#,
                        #"\d{4}-\d{1,2}-\d{1,2}|(?<![\p{L}\p{N}_])[-+−]?\d[\d,]*(?:\.\d+)?[%％]?"#,
                        #"[$€£¥￥]"#]
        return patterns.allSatisfy { pattern in
            let original = literals(pattern, in: source)
            let result = literals(pattern, in: translation)
            return original.sorted() == result.sorted()
        }
    }
    private static func literals(_ pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
