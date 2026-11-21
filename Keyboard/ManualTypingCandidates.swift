import Foundation
import Combine
#if os(iOS)
import UIKit
#endif

/// An ephemeral view of the insertion point. Only the on/off preference is persisted.
struct ManualTypingContext: Equatable {
    let ticket: UUID
    let document: UUID
    let before: String
    let after: String
}

@MainActor
final class ManualTypingCandidates: ObservableObject {
    struct Choice: Identifiable, Equatable {
        let id = UUID()
        let word: String
    }

    private struct Undo {
        let target: ManualTypingContext
        let inserted: String
        let original: String
    }

    @Published private(set) var choices: [Choice] = []
    @Published private(set) var canUndo = false
    @Published private(set) var enabled: Bool
    private var active = false
    private var offeredAt: ManualTypingContext?
    private var typedSuffix = ""
    private var undo: Undo?
    private let defaults: UserDefaults
    private let spellings: (String) -> [String]
    var readContext: () -> ManualTypingContext? = { nil }
    var replaceSuffix: (_ remove: Int, _ insert: String) -> Void = { _, _ in }

    init(defaults: UserDefaults = .standard, spellings: @escaping (String) -> [String]) {
        self.defaults = defaults
        self.spellings = spellings
        enabled = defaults.object(forKey: "manual_english_suggestions") as? Bool ?? true
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "manual_english_suggestions")
        refresh()
    }

    func setActive(_ value: Bool) {
        active = value
        refresh()
    }

    func refresh() {
        guard active, enabled, let context = readContext() else {
            clear()
            return
        }
        if undo?.target != context { undo = nil }
        canUndo = undo != nil
        guard context != offeredAt else { return }
        offeredAt = context
        choices = []
        typedSuffix = ""
        guard let query = Self.query(before: context.before, after: context.after) else { return }
        typedSuffix = query.replacing
        var seen = Set<String>()
        let words = query.replacing.isEmpty ? Self.following[query.word, default: []] : spellings(query.word)
        var available: [Choice] = []
        for word in words where (1...32).contains(word.count) && word.allSatisfy({ $0.isASCII && $0.isLetter }) {
            guard word.lowercased() != query.replacing, seen.insert(word).inserted else { continue }
            available.append(Choice(word: word))
            if available.count == 3 { break }
        }
        choices = available
    }

    func apply(_ choice: Choice) {
        guard active, enabled, let context = readContext(), context == offeredAt, choices.contains(choice) else {
            refresh()
            return
        }
        // Replace only the part that actually changed. A completion usually just appends letters.
        let prefix = choice.word.commonPrefix(with: typedSuffix)
        let original = String(typedSuffix.dropFirst(prefix.count))
        let inserted = String(choice.word.dropFirst(prefix.count))
        replaceSuffix(original.count, inserted)
        let expectedBefore = context.before.dropLast(original.count) + inserted
        if let target = readContext(), target.document == context.document,
           target.before == expectedBefore, target.after == context.after {
            undo = Undo(target: target, inserted: inserted, original: original)
        }
        refresh()
    }

    func undoLast() {
        guard active, enabled, let undo, readContext() == undo.target else {
            refresh()
            return
        }
        self.undo = nil
        replaceSuffix(undo.inserted.count, undo.original)
        refresh()
    }

    private func clear() {
        offeredAt = nil
        undo = nil
        canUndo = false
        typedSuffix = ""
        choices = []
    }

    /// Restrict spelling to lowercase words at a word boundary. Hosts with selected text,
    /// specialized input traits or inaccessible context are already excluded by the controller.
    private static func query(before: String, after: String) -> (word: String, replacing: String)? {
        if let next = after.first, !next.isWhitespace {
            guard ".,!?;".contains(next), after.dropFirst().first?.isWhitespace != false else { return nil }
        }
        let line = before.suffix(160).split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let codePunctuation = CharacterSet(charactersIn: "`/\\@#$_=+*{}[]()<>:|&%~")
        guard line.rangeOfCharacter(from: codePunctuation) == nil,
              !line.contains(where: { $0.isLetter && !$0.isASCII }) else { return nil }
        let following = line.last == " "
        let words = line.split(whereSeparator: \.isWhitespace)
        if let first = words.first, codePrefixes.contains(first) { return nil }
        guard let token = words.last, (1...32).contains(token.count),
              token.allSatisfy({ $0.isASCII && $0.isLetter }),
              token == token.lowercased() || (following && String(token) == token.capitalized) else { return nil }
        let word = token.lowercased()
        if following { return (word, "") }
        return token.count >= 2 ? (word, word) : nil
    }

    private static let codePrefixes: Set<Substring> = [
        "func", "def", "const", "enum", "struct", "import", "return", "sudo", "git", "npm"
    ]

    // Small fixed phrase continuations work offline without learning users' messages.
    private static let following = [
        "good": ["morning", "afternoon", "evening"], "thank": ["you"], "thanks": ["for"],
        "see": ["you"], "nice": ["to"], "look": ["forward"], "how": ["are", "is"],
        "i": ["am", "will", "have"], "we": ["can", "will", "are"], "you": ["are", "can", "have"],
        "would": ["like", "you"], "please": ["let", "send", "confirm"], "let": ["me", "us"],
        "hong": ["Kong"], "check": ["in", "out"], "meet": ["at", "you"]
    ]
}

#if os(iOS)
extension ManualTypingCandidates {
    convenience init() {
        let checker = UITextChecker()
        let language = UITextChecker.availableLanguages.first { $0 == "en_US" }
            ?? UITextChecker.availableLanguages.first { $0.hasPrefix("en") }
        self.init { word in
            guard let language else { return [] }
            let range = NSRange(word.startIndex..., in: word)
            let misspelled = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0,
                                                           wrap: false, language: language)
            let guesses = misspelled == range
                ? checker.guesses(forWordRange: range, in: word, language: language) ?? [] : []
            let completions = checker.completions(forPartialWordRange: range, in: word, language: language) ?? []
            return guesses + completions
        }
    }
}
#endif
