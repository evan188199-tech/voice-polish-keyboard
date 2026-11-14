import Foundation
import Combine

/// One captured clipboard item.
///
/// Pure value type, codable, shared by the keyboard extension and the main app via the loopback bridge.
struct ClipboardEntry: Codable, Equatable, Identifiable, Sendable, Hashable {
    let id: String
    let text: String
    let createdAt: Date

    init(id: String = UUID().uuidString, text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// Tunable policy for the keyboard-side clipboard history store.
enum ClipboardHistoryPolicy {
    /// Maximum number of entries kept.
    static let maxEntries = 50
    /// Per-entry text truncation length (characters).
    static let maxTextLength = 2000
    /// Entries older than this are pruned on load/append.
    static let expirationDays: TimeInterval = 7
}

/// Keyboard-side authoritative store. Backed by the extension's own UserDefaults.
///
/// Dedup strategy: only compare against the most recent entry's text, so repeating
/// the same content consecutively won't stack up, but re-copying an older item will.
enum ClipboardHistoryStore {
    private static let key = "clipboard_history_v1"

    static func load(defaults: UserDefaults = .standard) -> [ClipboardEntry] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data)
        else { return [] }
        return pruneExpired(decoded)
    }

    static func save(_ entries: [ClipboardEntry], defaults: UserDefaults = .standard) {
        let capped = Array(entries.prefix(ClipboardHistoryPolicy.maxEntries))
        if let data = try? JSONEncoder().encode(capped) {
            defaults.set(data, forKey: key)
        }
    }

    /// Returns the new list after appending, deduping, truncating, and capping.
    /// Caller is responsible for persisting via `save`.
    static func append(_ text: String, to entries: [ClipboardEntry], at now: Date = Date()) -> [ClipboardEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        let truncated: String
        if trimmed.count > ClipboardHistoryPolicy.maxTextLength {
            truncated = String(trimmed.prefix(ClipboardHistoryPolicy.maxTextLength))
        } else {
            truncated = trimmed
        }
        if let last = entries.first, last.text == truncated {
            return entries
        }
        var updated = entries
        updated.insert(ClipboardEntry(text: truncated, createdAt: now), at: 0)
        if updated.count > ClipboardHistoryPolicy.maxEntries {
            updated = Array(updated.prefix(ClipboardHistoryPolicy.maxEntries))
        }
        return updated
    }

    static func remove(id: String, from entries: [ClipboardEntry]) -> [ClipboardEntry] {
        entries.filter { $0.id != id }
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    static func prunedCopy(_ entries: [ClipboardEntry], at now: Date = Date()) -> [ClipboardEntry] {
        pruneExpired(entries, at: now)
    }

    private static func pruneExpired(_ entries: [ClipboardEntry], at now: Date = Date()) -> [ClipboardEntry] {
        let cutoff = now.addingTimeInterval(-ClipboardHistoryPolicy.expirationDays * 86_400)
        return entries.filter { $0.createdAt >= cutoff }
    }
}

/// Main-app-side persistent mirror of the keyboard's clipboard history.
///
/// Because the bridge is one-way (keyboard = client, main app = server), the main app
/// cannot push deletions back to the keyboard. Deletions here are "hidden" via an id set
/// and applied on the next incoming sync so they stick.
@MainActor
final class ClipboardMirrorStore: ObservableObject {
    static let shared = ClipboardMirrorStore()

    private let entriesKey = "clipboard_mirror_v1"
    private let hiddenIDsKey = "clipboard_hidden_ids_v1"
    private let defaults: UserDefaults
    @Published private(set) var entries: [ClipboardEntry] = []
    private var hiddenIDs: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    private func reload() {
        if let data = defaults.data(forKey: entriesKey),
           let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data) {
            entries = decoded
        }
        if let ids = defaults.array(forKey: hiddenIDsKey) as? [String] {
            hiddenIDs = Set(ids)
        }
        entries = entries.filter { !hiddenIDs.contains($0.id) }
        persist()
    }

    /// All mirror changes and persistence are serialized on the main actor.
    @discardableResult
    func merge(_ incoming: [ClipboardEntry]) -> [ClipboardEntry] {
        entries = Array(incoming.filter { !hiddenIDs.contains($0.id) }.prefix(ClipboardHistoryPolicy.maxEntries))
        persist()
        return entries
    }

    func hide(id: String) {
        hiddenIDs.insert(id)
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        hiddenIDs.formUnion(entries.map(\.id))
        entries = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: entriesKey)
        }
        defaults.set(Array(hiddenIDs), forKey: hiddenIDsKey)
    }
}
