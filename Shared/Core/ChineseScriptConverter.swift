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
        let transformName: StringTransform
        switch direction {
        case .toTraditional:
            transformName = StringTransform("Hans-Hant")
        case .toSimplified:
            transformName = StringTransform("Hant-Hans")
        }
        return text.applyingTransform(transformName, reverse: false) ?? text
    }

    static func alreadyInDirection(_ text: String, direction: Direction) -> Bool {
        return convert(text, direction: direction) == text
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
