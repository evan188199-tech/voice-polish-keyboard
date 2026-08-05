import Foundation

/// Snapshot of dual-engine ASR output for the main-app A/B surface.
struct ASRCompareSnapshot: Equatable, Sendable {
    var primaryText: String?
    var compareText: String?
    var primaryLatencyMs: Int?
    var compareLatencyMs: Int?
    var compareEngineDisplayName: String
    var compareError: String?
    var compareLocaleIdentifier: String?

    static let empty = ASRCompareSnapshot(
        primaryText: nil,
        compareText: nil,
        primaryLatencyMs: nil,
        compareLatencyMs: nil,
        compareEngineDisplayName: "系统听写 (on-device)",
        compareError: nil,
        compareLocaleIdentifier: nil
    )
}

/// Pure locale ranking used by Apple on-device ASR (unit-testable without Speech).
enum AppleSpeechLocaleSelector {
    /// Prefer Cantonese (zh-HK / yue), then other Chinese, then English, else first available.
    static func preferredLocaleIdentifier(from availableIdentifiers: [String]) -> String? {
        guard !availableIdentifiers.isEmpty else { return nil }

        let normalized = availableIdentifiers.map { ($0, $0.replacingOccurrences(of: "_", with: "-")) }

        func match(prefixes: [String]) -> String? {
            for prefix in prefixes {
                if let hit = normalized.first(where: { _, id in
                    id.caseInsensitiveCompare(prefix) == .orderedSame
                        || id.lowercased().hasPrefix(prefix.lowercased() + "-")
                        || id.lowercased().hasPrefix(prefix.lowercased() + "_")
                }) {
                    return hit.0
                }
            }
            return nil
        }

        if let id = match(prefixes: ["zh-HK", "yue-Hant-HK", "yue-HK", "yue-Hant", "yue"]) {
            return id
        }
        if let id = match(prefixes: ["zh-Hant-HK", "zh-Hant-TW", "zh-TW", "zh-Hant", "zh-CN", "zh-Hans", "zh"]) {
            return id
        }
        if let id = match(prefixes: ["en-HK", "en-GB", "en-US", "en"]) {
            return id
        }
        return availableIdentifiers[0]
    }

    static func displayName(for localeIdentifier: String?) -> String {
        guard let localeIdentifier, !localeIdentifier.isEmpty else {
            return "系统听写 (on-device)"
        }
        return "系统听写 · \(localeIdentifier) (on-device)"
    }
}
