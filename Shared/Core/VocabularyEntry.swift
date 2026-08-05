import Foundation

struct VocabularyEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var phrase: String

    init(id: UUID = UUID(), phrase: String) {
        self.id = id
        self.phrase = phrase
    }

    private static let storageKey = "vocabulary_entries"

    static func load() -> [VocabularyEntry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([VocabularyEntry].self, from: data) else {
            return []
        }
        return entries
    }

    static func save(_ entries: [VocabularyEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        let joined = entries.map(\.phrase).joined(separator: "\n")
        UserDefaults.standard.set(joined, forKey: "custom_vocabulary")
    }
}
