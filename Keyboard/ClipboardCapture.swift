import UIKit

/// Reads the system clipboard once when the keyboard appears.
///
/// iOS keyboards cannot observe pasteboard changes in the background; this only
/// samples the current value at keyboard-appearance time. Requires Full Access.
enum ClipboardCapture {
    private static let enabledKey = "clipboard_history_enabled"

    /// Returns the freshly-captured entry, or nil if disabled / no text / same as last.
    static func captureIfNeeded(defaults: UserDefaults = .standard) -> ClipboardEntry? {
        guard defaults.object(forKey: enabledKey) == nil
                || defaults.bool(forKey: enabledKey) else { return nil }

        let pasteboard = UIPasteboard.general
        // Probe for text content first to avoid triggering a read on non-text payloads.
        guard pasteboard.hasStrings else { return nil }
        guard let raw = pasteboard.string else { return nil }

        let current = ClipboardHistoryStore.load(defaults: defaults)
        let updated = ClipboardHistoryStore.append(raw, to: current)
        guard updated.count != current.count else { return nil }
        ClipboardHistoryStore.save(updated, defaults: defaults)
        return updated.first
    }
}
