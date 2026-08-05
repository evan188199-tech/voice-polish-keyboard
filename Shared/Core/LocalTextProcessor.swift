import Foundation

/// Runs before the optional API polisher: filler cleanup, punctuation spacing,
/// VAD segment joining, and English casing normalization for all-caps ASR artifacts.
/// Cloud polish (纠错/代码/润色/问答) success paths keep the LLM text as-is; this
/// processor only shapes local ASR text that may also be fed into polish.
enum LocalTextProcessor {
    /// Short ALL-CAPS tokens that are commonly intentional acronyms.
    private static let preservedAcronyms: Set<String> = [
        "AI", "API", "ASR", "CLI", "CPU", "DNS", "GPU", "HDD", "HTTP", "HTTPS",
        "ID", "IME", "IP", "JSON", "LLM", "OK", "OS", "PC", "PDF", "RAM", "ROM",
        "SDK", "SQL", "SSH", "SSD", "TTS", "TV", "UI", "URL", "USB", "UX", "VPN",
        "WWDC", "XML"
    ]

    /// Product / brand spellings with intentional internal capitals (e.g. iPhone).
    /// Keys are always lowercased; values are the preferred display form.
    private static let builtInPreferredCasing: [String: String] = {
        let terms = [
            "iPhone", "iPad", "iPod", "iMac", "iOS", "iPadOS", "macOS", "tvOS", "watchOS",
            "iCloud", "iMessage", "iTunes", "MacBook", "FaceTime", "AirPods", "AirPlay",
            "AirTag", "HomePod", "TestFlight", "App Store", "Mac App Store",
            "ChatGPT", "OpenAI", "GitHub", "GitLab", "YouTube", "Wi-Fi", "WiFi",
            "Bluetooth", "JavaScript", "TypeScript", "Objective-C", "SwiftUI", "Xcode",
            "Chatwoot", "Tailscale", "SenseVoice", "WhisperKit", "OpenCode", "Codex",
            "Blender", "ComfyUI", "Hugging Face", "PyTorch", "TensorFlow", "Core ML",
            "PowerPoint", "LinkedIn", "WhatsApp", "Telegram", "WeChat", "TikTok"
        ]
        var map: [String: String] = [:]
        for term in terms {
            map[term.lowercased()] = term
            // Index whitespace-separated tokens only (never split "Wi-Fi" into "Wi"/"Fi").
            for token in term.split(whereSeparator: { $0.isWhitespace }) {
                let s = String(token)
                if s.count >= 2 {
                    map[s.lowercased()] = map[s.lowercased()] ?? s
                }
            }
        }
        // Prefer full Wi-Fi spelling when ASR emits WIFI / wifi.
        map["wifi"] = "Wi-Fi"
        map["wi-fi"] = "Wi-Fi"
        return map
    }()

    static func process(_ text: String, vocabulary: String) -> String {
        var t = text

        let fillers = ["嗯", "啊", "呃", "哦", "um", "uh", "ah"]
        for filler in fillers {
            t = t.replacingOccurrences(of: filler, with: "")
        }

        let pairs: [(String, String)] = [
            (" ,", ","), (" .", "."), (" ?", "?"), (" !", "!"),
            (" ，", "，"), (" 。", "。"), (" ？", "？"), (" ！", "！")
        ]
        for (from, to) in pairs {
            t = t.replacingOccurrences(of: from, with: to)
        }

        for char in [".", "。", ",", "，"] {
            let doubled = char + char
            while t.contains(doubled) {
                t = t.replacingOccurrences(of: doubled, with: char)
            }
        }

        while t.contains("  ") {
            t = t.replacingOccurrences(of: "  ", with: " ")
        }
        t = collapseSpacesBetweenCJK(t)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)

        t = normalizeEnglishCasing(t, vocabulary: vocabulary)
        return t
    }

    /// Join VAD / multi-chunk ASR segments for a single hold.
    /// Chinese bare boundaries get `。`; Latin/mixed boundaries get a space;
    /// existing boundary punctuation is preserved without doubling.
    static func joinTranscriptSegments(_ segments: [String]) -> String {
        let cleaned = segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = cleaned.first else { return "" }

        var result = first
        for next in cleaned.dropFirst() {
            result += separator(between: result, and: next)
            result += next
        }
        return result
    }

    /// Fix SenseVoice-style ALL CAPS English while preserving Chinese, acronyms,
    /// and special product casing such as `iPhone` / `iOS` / `macOS`.
    static func normalizeEnglishCasing(_ text: String, vocabulary: String) -> String {
        guard !text.isEmpty else { return text }

        // User vocabulary wins over built-ins for the same key.
        var preferred = builtInPreferredCasing
        for (key, value) in vocabularyLookup(from: vocabulary) {
            preferred[key] = value
        }

        var result = remapLatinWords(text) { word in
            rewriteLatinWord(word, preferred: preferred)
        }

        result = capitalizeSentenceStarts(result, preferred: preferred)
        // Re-apply preferred casing so "Iphone" / "Ios" from sentence-capital never sticks.
        result = remapLatinWords(result) { word in
            let key = word.lowercased()
            if let preferredForm = preferred[key] {
                return preferredForm
            }
            return word
        }
        result = applyPreferredPhrases(result, preferred: preferred)
        result = restoreEnglishPronounI(result)
        return result
    }

    // MARK: - Helpers

    private static func rewriteLatinWord(_ word: String, preferred: [String: String]) -> String {
        let letters = word.filter(\.isLetter)
        guard !letters.isEmpty else { return word }

        let lowerKey = word.lowercased()
        if let preferredForm = preferred[lowerKey] {
            return preferredForm
        }

        // Only rewrite pure ALL-CAPS Latin tokens (ASR artifact).
        let isAllCapsLatin = word.allSatisfy { ch in
            if ch.isLetter { return ch.isASCII && ch.isUppercase }
            return ch.isNumber || ch == "-" || ch == "'"
        }
        guard isAllCapsLatin else { return word }

        let letterOnly = String(letters)
        if letterOnly.count == 1 {
            return letterOnly == "I" ? "I" : letterOnly.lowercased()
        }
        if letterOnly.count <= 4, preservedAcronyms.contains(letterOnly) {
            return letterOnly
        }
        return word.lowercased()
    }

    private static func vocabularyLookup(from vocabulary: String) -> [String: String] {
        var map: [String: String] = [:]
        let parts = vocabulary
            .components(separatedBy: CharacterSet(charactersIn: "\n,;|"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for phrase in parts {
            map[phrase.lowercased()] = phrase
            for token in phrase.split(whereSeparator: { $0.isWhitespace }) {
                let s = String(token)
                if s.count >= 2 {
                    map[s.lowercased()] = s
                }
            }
        }
        return map
    }

    /// Map contiguous Latin-letter tokens (ASCII letters + optional internal digits/'/-).
    private static func remapLatinWords(_ text: String, transform: (String) -> String) -> String {
        var output = ""
        var current = ""
        for ch in text {
            if isLatinWordChar(ch) {
                current.append(ch)
            } else {
                if !current.isEmpty {
                    output.append(transform(current))
                    current = ""
                }
                output.append(ch)
            }
        }
        if !current.isEmpty {
            output.append(transform(current))
        }
        return output
    }

    private static func isLatinWordChar(_ ch: Character) -> Bool {
        if ch.isASCII, ch.isLetter { return true }
        if ch.isNumber { return true }
        if ch == "'" || ch == "-" { return true }
        return false
    }

    private static let boundaryPunctuation: Set<Character> = [
        "。", "！", "？", "…", "；", ";", "：", ":", "，", ",", "、", ".", "!", "?"
    ]

    private static func separator(between left: String, and right: String) -> String {
        guard let leftLast = left.last, let rightFirst = right.first else { return " " }
        if isBoundaryPunctuation(leftLast) || isBoundaryPunctuation(rightFirst) {
            return ""
        }
        if isCJKLetter(leftLast) && isCJKLetter(rightFirst) {
            return "。"
        }
        return " "
    }

    private static func isBoundaryPunctuation(_ ch: Character) -> Bool {
        boundaryPunctuation.contains(ch)
    }

    /// Han / common CJK letters used for segment-boundary decisions.
    private static func isCJKLetter(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x3400...0x4DBF,  // CJK Extension A
                 0x4E00...0x9FFF,  // CJK Unified
                 0xF900...0xFAFF,  // CJK Compatibility Ideographs
                 0x3040...0x30FF,  // Hiragana / Katakana
                 0xAC00...0xD7AF:  // Hangul syllables
                return true
            default:
                continue
            }
        }
        return false
    }

    /// Remove residual spaces between Han characters without touching Latin tokens.
    private static func collapseSpacesBetweenCJK(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"([\p{Han}])[ \t]+([\p{Han}])"#,
            options: []
        ) else {
            return text
        }
        var result = text
        // Overlapping matches need a few passes ("很 好 明 天").
        for _ in 0..<8 {
            let range = NSRange(result.startIndex..., in: result)
            let next = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "$1$2"
            )
            if next == result { break }
            result = next
        }
        return result
    }

    private static func capitalizeSentenceStarts(_ text: String, preferred: [String: String]) -> String {
        var chars = Array(text)
        var capitalizeNext = true
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if capitalizeNext, ch.isWhitespace || ch == "\n" || ch == "\t" {
                i += 1
                continue
            }

            if capitalizeNext, ch.isLetter, ch.isASCII {
                // Read the whole Latin word so we can respect iPhone-style preferred casing.
                var j = i
                var wordChars: [Character] = []
                while j < chars.count, isLatinWordChar(chars[j]) {
                    wordChars.append(chars[j])
                    j += 1
                }
                let word = String(wordChars)
                if let preferredForm = preferred[word.lowercased()],
                   let first = preferredForm.first,
                   first.isLetter,
                   first.isLowercase {
                    // Keep brand casing that intentionally starts lowercase (iPhone, iOS, macOS).
                    let preferredChars = Array(preferredForm)
                    for offset in 0..<min(preferredChars.count, wordChars.count) {
                        chars[i + offset] = preferredChars[offset]
                    }
                    // If lengths differ (rare), fall back to full remap later.
                } else if ch.isLowercase {
                    chars[i] = Character(ch.uppercased())
                }
                capitalizeNext = false
                i = j
                continue
            } else if ch.isLetter {
                capitalizeNext = false
            }

            if ch == "." || ch == "!" || ch == "?" || ch == "。" || ch == "！" || ch == "？" || ch == "\n" {
                capitalizeNext = true
            }
            i += 1
        }
        return String(chars)
    }

    private static func applyPreferredPhrases(_ text: String, preferred: [String: String]) -> String {
        guard !preferred.isEmpty else { return text }
        let phrases = preferred.values
            .filter { $0.contains(where: \.isWhitespace) || $0.contains("-") }
            .filter { $0.contains(where: \.isLetter) }
            .sorted { $0.count > $1.count }

        var result = text
        for phrase in phrases {
            let pattern = NSRegularExpression.escapedPattern(for: phrase)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: phrase)
            )
        }
        return result
    }

    /// Standalone English pronoun "i" -> "I" (does not touch iPhone / iOS).
    private static func restoreEnglishPronounI(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\bi\b"#, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "I")
    }
}
