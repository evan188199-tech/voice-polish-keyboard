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
final class ClipboardMirrorStore: ObservableObject, @unchecked Sendable {
    static let shared = ClipboardMirrorStore()

    private let entriesKey = "clipboard_mirror_v1"
    private let hiddenIDsKey = "clipboard_hidden_ids_v1"
    private let defaults: UserDefaults
    private let lock = NSLock()

    @Published private(set) var entries: [ClipboardEntry] = []
    private var hiddenIDs: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    private func reload() {
        lock.lock()
        defer { lock.unlock() }
        if let data = defaults.data(forKey: entriesKey),
           let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
        if let ids = defaults.array(forKey: hiddenIDsKey) as? [String] {
            hiddenIDs = Set(ids)
        } else {
            hiddenIDs = []
        }
        entries = entries.filter { !hiddenIDs.contains($0.id) }
        persistLocked()
    }

    /// Replace the mirror with the incoming keyboard snapshot, then filter out hidden ids.
    /// Returns the stored (visible) list. Safe to call from any thread.
    @discardableResult
    func merge(_ incoming: [ClipboardEntry]) -> [ClipboardEntry] {
        lock.lock()
        defer { lock.unlock() }
        let visible = incoming.filter { !hiddenIDs.contains($0.id) }
        let capped = Array(visible.prefix(ClipboardHistoryPolicy.maxEntries))
        let result = capped
        DispatchQueue.main.async { [weak self] in
            self?.entries = capped
        }
        persistLocked()
        return result
    }

    func hide(id: String) {
        lock.lock()
        defer { lock.unlock() }
        hiddenIDs.insert(id)
        DispatchQueue.main.async { [weak self] in
            self?.entries.removeAll { $0.id == id }
        }
        persistLocked()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        for entry in entries { hiddenIDs.insert(entry.id) }
        DispatchQueue.main.async { [weak self] in
            self?.entries = []
        }
        persistLocked()
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: entriesKey)
        }
        defaults.set(Array(hiddenIDs), forKey: hiddenIDsKey)
    }
}
