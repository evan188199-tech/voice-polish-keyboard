import Foundation

@MainActor enum PlaceChecks {
    static func run() async {
        let check = KeyboardChecks.check
        let defaults = UserDefaults(suiteName: "place-checks-\(UUID())")!
        let store = PlaceNameDictionaryStore(defaults: defaults, seed: false)
        var guilin = PlaceNameEntry(name: "桂林", aliases: ["贵林"], language: .mandarin, region: "广西", isConfirmed: true)
        try! store.upsert(guilin)
        check(store.entries.count == 1 && store.search("贵林").count == 1, "place add and alias search stay local")
        let original = "明天去贵林，唔好改20个 API 参数，后天再去贵林"
        let suggestions = PlaceNameMatcher.suggestions(in: original, entries: store.entries, script: .simplified)
        var draft = PlaceReviewDraft(original: original, suggestions: suggestions)
        check(suggestions.count == 2 && draft.text == original, "candidate match never replaces without confirmation")
        check(draft.confirm(suggestions[0].id) && draft.text == "明天去桂林，唔好改20个 API 参数，后天再去贵林", "confirmation changes only chosen occurrence")
        draft.undo()
        check(draft.text == original, "candidate undo restores exact original")
        draft.reject(suggestions[0].id)
        check(draft.visibleSuggestions.count == 1 && draft.text == original, "candidate can be rejected without altering text")
        let serialized = try! JSONEncoder().encode(draft)
        let restored = try! JSONDecoder().decode(PlaceReviewDraft.self, from: serialized)
        check(restored == draft, "review draft survives restart with undo/rejection state")
        guilin.isEnabled = false
        try! store.upsert(guilin)
        check(PlaceNameMatcher.suggestions(in: original, entries: store.entries, script: .simplified).isEmpty, "disabled place yields no candidate")
        store.setEnabled(guilin.id, true)
        let reload = PlaceNameDictionaryStore(defaults: defaults, seed: false)
        check(reload.entries.count == 1 && reload.entries[0].isEnabled, "dictionary edit, toggle and restart persistence")
        for invalid in [PlaceNameEntry(name: ""), PlaceNameEntry(name: "桂林", region: "广西"), PlaceNameEntry(name: "广州", traditional: "桂林"), PlaceNameEntry(name: "深圳", aliases: ["深"])] {
            do { try store.upsert(invalid); check(false, "invalid entry must fail") }
            catch { check(true, "empty/duplicate/script-conflict/short alias rejected") }
        }
        let correct = "成都有朋友，城市都很热闹。明天去桂林，We visit Hong Kong."
        check(PlaceNameMatcher.suggestions(in: correct, entries: PlaceNameDictionaryStore.seeds + store.entries, script: .simplified).isEmpty, "correct names and ordinary words are never globally replaced")
        let alternate = PlaceNameEntry(name: "桂林", aliases: ["贵林"], region: "虚构同名区")
        let ambiguous = PlaceNameMatcher.suggestions(in: "去贵林", entries: [guilin, alternate].map { var e = $0; e.isEnabled = true; return e }, script: .traditionalHK)
        check(ambiguous.count == 2, "same-name regions remain multiple explicit candidates")
        check(PlaceNameMatcher.suggestions(in: "keep /tmp/贵林.txt", entries: store.entries, script: .simplified).isEmpty, "place suggestions do not rewrite code/path")
        check(PlaceNameDictionaryStore.seeds.allSatisfy { $0.aliases.isEmpty && $0.origin == .publicSeed }, "public seeds contain no invented pronunciation/confusion mappings")
        store.remove(guilin.id)
        check(store.entries.isEmpty, "dictionary deletion persists")
    }
}
