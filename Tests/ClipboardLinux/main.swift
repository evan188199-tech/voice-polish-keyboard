import Foundation

@main struct ClipboardChecks {
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: \(label)") }
        print("PASS: \(label)")
    }
    @MainActor static func main() async {
        let defaults = UserDefaults(suiteName: "clipboard-fixture-\(UUID())")!
        let mirror = ClipboardMirrorStore(defaults: defaults)
        let entries = [ClipboardEntry(text: "fictional A"), ClipboardEntry(text: "fictional B")]
        let merged = mirror.merge(entries)
        check(merged == entries, "merge returns submitted fixture")
        let reopened = ClipboardMirrorStore(defaults: defaults)
        check(reopened.entries == entries, "immediate reload sees merged snapshot before UI publication")
        mirror.clear()
        check(mirror.merge(entries).isEmpty, "clear hides entries even before UI publication")
        let reconstructed = ClipboardMirrorStore(defaults: defaults)
        check(reconstructed.merge(entries).isEmpty, "hidden entries remain hidden after reconstruction")
        let third = ClipboardEntry(text: "fictional C")
        _ = reconstructed.merge([third])
        reconstructed.hide(id: third.id)
        check(reconstructed.merge([third]).isEmpty, "hide survives re-merge")
        let afterHide = ClipboardMirrorStore(defaults: defaults)
        check(afterHide.merge([third]).isEmpty, "hide survives reconstruction")

        let expiredDefaults = UserDefaults(suiteName: "clipboard-expiry-\(UUID())")!
        let expired = ClipboardEntry(text: "old fiction", createdAt: Date(timeIntervalSince1970: 1000))
        ClipboardHistoryStore.save([expired], defaults: expiredDefaults)
        check(ClipboardHistoryStore.load(defaults: expiredDefaults).isEmpty, "expired fixed-date fixture is intentionally pruned")
        let fresh = ClipboardEntry(text: "recent fiction", createdAt: Date())
        ClipboardHistoryStore.save([fresh], defaults: expiredDefaults)
        check(ClipboardHistoryStore.load(defaults: expiredDefaults) == [fresh], "current fixture round trips")

        let concurrentDefaults = UserDefaults(suiteName: "clipboard-race-\(UUID())")!
        let concurrent = ClipboardMirrorStore(defaults: concurrentDefaults)
        let race = ClipboardEntry(text: "fictional race")
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    if i.isMultiple(of: 2) { _ = await concurrent.merge([race]) }
                    else { await concurrent.hide(id: race.id) }
                }
            }
        }
        check(concurrent.entries.isEmpty, "interleaved merge/hide never restores hidden entry")
        let concurrentReload = ClipboardMirrorStore(defaults: concurrentDefaults)
        check(concurrentReload.merge([race]).isEmpty, "concurrent result persists across reconstruction")
    }
}
