import Foundation

enum PlaceLanguage: String, CaseIterable, Codable, Sendable { case general = "通用", cantonese = "粤语", mandarin = "普通话" }
enum PlaceOrigin: String, Codable, Sendable { case publicSeed, user }
struct PlaceNameEntry: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var traditional: String = ""
    var aliases: [String] = []
    var language: PlaceLanguage = .general
    var region: String = ""
    var source: String = "用户本地录入"
    var origin: PlaceOrigin = .user
    var isConfirmed = false
    var isEnabled = true
}
struct PlaceNameSuggestion: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let location: Int
    let length: Int
    let original: String
    let replacement: String
    let region: String
    let confirmedEntry: Bool
    var range: NSRange { NSRange(location: location, length: length) }
}

enum PlaceNameMatcher {
    /// Local Mandarin transliteration candidates, not acoustic hotwords or automatic edits.
    /// Only the user's explicit short Chinese terms are considered; none leave the device.
    static func vocabularySuggestions(in text: String, vocabulary: String, script: ChineseScriptPreference) -> [PlaceNameSuggestion] {
        guard text.count <= 1000, !FaithfulPlaceProtection.isProtected(text) else { return [] }
        func chinese(_ value: String) -> Bool {
            !value.isEmpty && value.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) }
        }
        var readings: [Character: String] = [:]
        func sound(_ value: String) -> String {
            value.map { character in
                if let known = readings[character] { return known }
                let reading = (String(character).applyingTransform(.toLatin, reverse: false) ?? String(character))
                    .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                    .filter { $0.isASCII && $0.isLetter }
                readings[character] = reading
                return reading
            }.joined()
        }
        let terms = Array(Set(vocabulary.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { (2...8).contains($0.count) && chinese($0) })).sorted().prefix(128)
        let characters = Array(text)
        var offsets = [0]
        for character in characters { offsets.append(offsets.last! + String(character).utf16.count) }
        var output: [PlaceNameSuggestion] = []
        for term in terms where term.count <= characters.count {
            let replacement = ChineseScriptConverter.convert(term, direction: script.conversionDirection)
            let phonetic = sound(term)
            guard !phonetic.isEmpty else { continue }
            for start in 0...(characters.count - term.count) {
                let original = String(characters[start..<(start + term.count)])
                guard chinese(original), original != replacement, original != term,
                      sound(original) == phonetic else { continue }
                output.append(PlaceNameSuggestion(location: offsets[start], length: offsets[start + term.count] - offsets[start],
                    original: original, replacement: replacement, region: "本地专有词 · 普通话音近候选", confirmedEntry: false))
                if output.count >= 32 { return output }
            }
        }
        return output
    }

    static func suggestions(in text: String, entries: [PlaceNameEntry], script: ChineseScriptPreference) -> [PlaceNameSuggestion] {
        guard !FaithfulPlaceProtection.isProtected(text) else { return [] }
        let enabled = entries.filter(\.isEnabled).sorted { lhs, rhs in
            if lhs.origin != rhs.origin { return lhs.origin == .user }
            return lhs.name < rhs.name
        }
        let correctForms = Set(enabled.flatMap { [$0.name, $0.traditional] }.filter { !$0.isEmpty })
        var output: [PlaceNameSuggestion] = []
        for entry in enabled {
            let base = script == .traditionalHK && !entry.traditional.isEmpty ? entry.traditional : entry.name
            let replacement = ChineseScriptConverter.convert(base, direction: script.conversionDirection)
            for alias in Set(entry.aliases) where alias.count >= 2 && !correctForms.contains(alias) {
                var start = text.startIndex
                while start < text.endIndex, let range = text.range(of: alias, range: start..<text.endIndex) {
                    let ns = NSRange(range, in: text)
                    output.append(PlaceNameSuggestion(location: ns.location, length: ns.length, original: alias,
                        replacement: replacement, region: entry.region, confirmedEntry: entry.isConfirmed))
                    start = range.upperBound
                }
            }
        }
        return output
    }
}
// Keep this DTO/helper available to the extension without importing ASR or private stores.
enum FaithfulPlaceProtection {
    static func isProtected(_ text: String) -> Bool {
        text.contains("/") || text.contains("`") || text.contains("=") || text.contains("{")
            || text.contains("\"") || text.contains("“") || text.contains("「") || text.contains("『")
    }
}

struct PlaceReviewDraft: Codable, Equatable, Sendable {
    struct Choice: Codable, Equatable, Sendable { var selected: [UUID]; var rejected: [UUID] }
    let original: String
    let suggestions: [PlaceNameSuggestion]
    private(set) var choice = Choice(selected: [], rejected: [])
    private var undoStack: [Choice] = []
    init(original: String, suggestions: [PlaceNameSuggestion]) {
        self.original = original
        self.suggestions = suggestions
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var visibleSuggestions: [PlaceNameSuggestion] { suggestions.filter { !choice.rejected.contains($0.id) } }
    var text: String {
        let result = NSMutableString(string: original)
        for suggestion in suggestions.filter({ choice.selected.contains($0.id) }).sorted(by: { $0.location > $1.location }) {
            guard valid(suggestion) else { continue }
            result.replaceCharacters(in: suggestion.range, with: suggestion.replacement)
        }
        return result as String
    }
    private func valid(_ suggestion: PlaceNameSuggestion) -> Bool {
        guard suggestion.location >= 0, suggestion.length > 0,
              suggestion.location <= (original as NSString).length - suggestion.length else { return false }
        return (original as NSString).substring(with: suggestion.range) == suggestion.original
    }
    @discardableResult mutating func confirm(_ id: UUID) -> Bool {
        guard let candidate = suggestions.first(where: { $0.id == id }), valid(candidate) else { return false }
        undoStack.append(choice)
        choice.selected.removeAll { existingID in
            guard let other = suggestions.first(where: { $0.id == existingID }) else { return true }
            return NSIntersectionRange(other.range, candidate.range).length > 0
        }
        choice.selected.append(id)
        choice.rejected.removeAll { $0 == id }
        return true
    }
    mutating func reject(_ id: UUID) {
        undoStack.append(choice)
        choice.selected.removeAll { $0 == id }
        choice.rejected.append(id)
    }
    mutating func undo() { if let previous = undoStack.popLast() { choice = previous } }
}
