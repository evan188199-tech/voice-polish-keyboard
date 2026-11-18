import Foundation

struct VocabularyEntry: Identifiable, Codable, Hashable {
    var id: UUID
    /// Canonical spelling sent to local text processing and the polish prompt.
    var phrase: String
    var aliases: [String]
    var category: String
    var notes: String
    var isEnabled: Bool
    var hitCount: Int
    /// Explicit consent bound to one profile/address/model; nil means local only.
    var polishDestination: String? = nil

    init(
        id: UUID = UUID(),
        phrase: String,
        aliases: [String] = [],
        category: String = "",
        notes: String = "",
        isEnabled: Bool = true,
        hitCount: Int = 0
    ) {
        self.id = id
        self.phrase = phrase
        self.aliases = aliases
        self.category = category
        self.notes = notes
        self.isEnabled = isEnabled
        self.hitCount = hitCount
    }

    private static let storageKey = "vocabulary_entries"

    static func load() -> [VocabularyEntry] {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let entries = try? JSONDecoder().decode([VocabularyEntry].self, from: data) {
            return entries
        }
        // Migrate the original newline-only vocabulary without ever deleting it.
        let legacy = UserDefaults.standard.string(forKey: "custom_vocabulary") ?? ""
        let migrated = legacy.split(whereSeparator: \.isNewline)
            .map { VocabularyEntry(phrase: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.phrase.isEmpty }
        if !migrated.isEmpty { save(migrated) }
        return migrated
    }

    static func save(_ entries: [VocabularyEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        let joined = entries.filter(\.isEnabled).map(\.phrase).joined(separator: "\n")
        UserDefaults.standard.set(joined, forKey: "custom_vocabulary")
    }

    /// Highest-value terms first, capped before they are sent to an ASR/LLM.
    static func promptVocabulary(from entries: [VocabularyEntry], maxCharacters: Int = 1_200) -> String {
        var remaining = maxCharacters
        var selected: [String] = []
        for entry in entries.filter(\.isEnabled).sorted(by: { $0.hitCount > $1.hitCount }) {
            let value = entry.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= remaining else { continue }
            selected.append(value)
            remaining -= value.count + 1
        }
        return selected.joined(separator: "\n")
    }

    private enum CodingKeys: String, CodingKey {
        case id, phrase, aliases, category, notes, isEnabled, hitCount, polishDestination
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        phrase = try container.decode(String.self, forKey: .phrase)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        hitCount = try container.decodeIfPresent(Int.self, forKey: .hitCount) ?? 0
        polishDestination = try container.decodeIfPresent(String.self, forKey: .polishDestination)
    }
}
