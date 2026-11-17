import Foundation

/// Selects optional, untrusted data for a future polish request. This type does
/// not read storage, invoke a model, or authorize a request. The caller must
/// keep the payload in a user-data channel, separate from system instructions.
/// Filtering and JSON encoding reduce risk; they cannot guarantee that a model
/// will ignore instructions embedded in user data.
enum PolishContextPolicy {
    static let maxTerms = 20
    static let maxTermCharacters = 32
    static let maxVocabularyCharacters = 400
    static let maxPayloadCharacters = 1_024

    struct CorrectionSelection {
        /// UTF-16 range in this job's transcript, explicitly selected by the user.
        let range: NSRange
        let replacement: String
    }

    private struct Correction: Encodable {
        let selected: String
        let replacement: String
    }
    private struct Payload: Encodable {
        let vocabulary: [String]
        let correction: Correction?
    }

    /// Nil means no context should be sent. Selection IDs default to empty;
    /// correction is included only when the caller supplies a selection for the
    /// current transcript. No aliases, notes, metadata or surrounding text leave.
    static func payload(
        entries: [VocabularyEntry],
        selectedIDs: Set<UUID> = [],
        transcript: String = "",
        correction: CorrectionSelection? = nil
    ) -> String? {
        let candidates = entries.filter { selectedIDs.contains($0.id) && $0.isEnabled && safeTerm($0.phrase) }
            .sorted {
                if $0.hitCount != $1.hitCount { return $0.hitCount > $1.hitCount }
                let a = $0.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                let b = $1.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                if a != b { return a < b }
                return $0.id.uuidString < $1.id.uuidString
            }
        var seen = Set<String>()
        let unique = candidates.filter {
            let key = $0.phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return seen.insert(key).inserted
        }
        // Preorder ties before calling the existing ranking/budget implementation.
        // Assign distinct ranks so its hit-count-only sort remains deterministic.
        let ranked = unique.prefix(maxTerms).enumerated().map { index, entry in
            var copy = entry
            copy.hitCount = maxTerms - index
            return copy
        }
        let vocabulary = VocabularyEntry.promptVocabulary(from: ranked, maxCharacters: maxVocabularyCharacters)
            .split(separator: "\n").map(String.init)
        var selectedCorrection: Correction?
        if let selection = correction,
           let range = Range(selection.range, in: transcript), !range.isEmpty {
            let selected = String(transcript[range])
            if safeTerm(selected), safeTerm(selection.replacement) {
                selectedCorrection = Correction(selected: selected, replacement: selection.replacement)
            }
        }
        guard !vocabulary.isEmpty || selectedCorrection != nil else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Payload(vocabulary: vocabulary, correction: selectedCorrection)),
              let result = String(data: data, encoding: .utf8), result.count <= maxPayloadCharacters else { return nil }
        return result
    }

    /// Conservative term-only allowlist: no URLs, punctuation, control chars,
    /// digits, markup or delimiters. Some legitimate terms will be omitted.
    private static func safeTerm(_ input: String) -> Bool {
        let term = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= maxTermCharacters, term == input else { return false }
        guard term.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == " " }) else { return false }
        let folded = term.lowercased()
        let suspicious = ["ignore", "instruction", "system", "prompt", "password", "secret", "token", "credential", "忽略", "指令", "系统", "系統", "密码", "密碼", "凭证", "憑證"]
        return !suspicious.contains(where: folded.contains)
    }
}
