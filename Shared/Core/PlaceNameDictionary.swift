import Foundation
import Combine

enum PlaceDictionaryError: Error, LocalizedError {
    case empty, invalid, duplicate, scriptConflict
    var errorDescription: String? {
        switch self {
        case .empty: "规范地名不能为空。"
        case .invalid: "地名最多 80 字，候选别名至少 2 字；不接受链接或多行地名。"
        case .duplicate: "相同地名和地区已存在，请编辑现有词条。"
        case .scriptConflict: "简繁写法不对应，请检查；其他名称请放入别名。"
        }
    }
}
@MainActor final class PlaceNameDictionaryStore: ObservableObject {
    static let shared = PlaceNameDictionaryStore()
    @Published private(set) var entries: [PlaceNameEntry]
    private let defaults: UserDefaults
    private let key = "local_place_dictionary_v1"
    init(defaults: UserDefaults = .standard, seed: Bool = true) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([PlaceNameEntry].self, from: data) {
            entries = saved
        } else { entries = seed ? Self.seeds : [] }
    }
    func upsert(_ entry: PlaceNameEntry) throws {
        var value = entry
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.traditional = value.traditional.trimmingCharacters(in: .whitespacesAndNewlines)
        value.region = value.region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty else { throw PlaceDictionaryError.empty }
        guard value.name.count <= 80, !value.name.contains("\n"), !value.name.contains(":"), !value.name.contains("/"),
              value.aliases.allSatisfy({ $0.count >= 2 && $0.count <= 80 && !$0.contains("\n") && !$0.contains("/") })
        else { throw PlaceDictionaryError.invalid }
        let normalized = ChineseScriptConverter.convert(value.name, direction: .toSimplified)
        if !value.traditional.isEmpty, ChineseScriptConverter.convert(value.traditional, direction: .toSimplified) != normalized {
            throw PlaceDictionaryError.scriptConflict
        }
        if entries.contains(where: { $0.id != value.id && ChineseScriptConverter.convert($0.name, direction: .toSimplified) == normalized && $0.region == value.region }) {
            throw PlaceDictionaryError.duplicate
        }
        value.origin = .user
        if let index = entries.firstIndex(where: { $0.id == value.id }) { entries[index] = value }
        else { entries.insert(value, at: 0) }
        persist()
    }
    func remove(_ id: UUID) { entries.removeAll { $0.id == id }; persist() }
    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isEnabled = enabled
        persist()
    }
    func search(_ query: String) -> [PlaceNameEntry] {
        guard !query.isEmpty else { return entries }
        return entries.filter { ([$0.name, $0.traditional, $0.region, $0.language.rawValue] + $0.aliases).contains { $0.localizedCaseInsensitiveContains(query) } }
    }
    private func persist() { if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) } }
    // General geographic names only. No private routes, source relationships,
    // pronunciation claims or unverified acoustic-confusion mappings are shipped.
    static var seeds: [PlaceNameEntry] {
        let names = [("广州","廣州"),("香港","香港"),("澳门","澳門"),("桂林","桂林"),("成都","成都"),("重庆","重慶"),
            ("潮汕","潮汕"),("汕头","汕頭"),("潮州","潮州"),("揭阳","揭陽"),("南澳岛","南澳島"),("深圳","深圳"),
            ("佛山","佛山"),("顺德","順德"),("阳朔","陽朔"),("昆明","昆明"),("大理","大理"),("丽江","麗江"),
            ("厦门","廈門"),("鼓浪屿","鼓浪嶼"),("张家界","張家界"),("黄山","黃山"),("宏村","宏村")]
        return names.map { PlaceNameEntry(name: $0.0, traditional: $0.1, source: "公开通用地名初始词表（非发音验证）", origin: .publicSeed) }
    }
}
