import Foundation

/// Offline simplified <-> traditional Chinese script conversion using CFStringTransform.
/// Does not perform vocabulary-level Hong Kong / Taiwan word-switching.
enum ChineseScriptConverter {
    enum Direction: String, Codable, Sendable, CaseIterable {
        case toTraditional
        case toSimplified

        var displayName: String {
            switch self {
            case .toTraditional: return "繁"
            case .toSimplified: return "简"
            }
        }
    }

    static func convert(_ text: String, direction: Direction?) -> String {
        guard let direction, !text.isEmpty else { return text }
        // ICU transforms: simplified Hans <-> traditional Hant.
        let transformName: CFString
        switch direction {
        case .toTraditional:
            transformName = "Hans-Hant" as CFString
        case .toSimplified:
            transformName = "Hant-Hans" as CFString
        }
        return applyTransform(text, transformName)
    }

    static func alreadyInDirection(_ text: String, direction: Direction) -> Bool {
        return convert(text, direction: direction) == text
    }

    private static func applyTransform(_ text: String, _ transformName: CFString) -> String {
        let mutable = NSMutableString(string: text)
        var range = CFRange(location: 0, length: CFStringGetLength(mutable as CFString))
        let ok = CFStringTransform(mutable as CFMutableString, &range, transformName, false)
        return ok ? (mutable as String) : text
    }
}

/// User-facing preference persisted in AppSettings.
enum ChineseScriptPreference: String, Codable, Sendable, CaseIterable {
    case simplified
    case traditionalHK

    static let `default`: ChineseScriptPreference = .simplified

    var shortLabel: String { self == .simplified ? "简" : "繁" }

    var settingsDescription: String { self == .simplified ? "输出简体中文" : "输出香港繁体" }

    var conversionDirection: ChineseScriptConverter.Direction {
        self == .traditionalHK ? .toTraditional : .toSimplified
    }
}
