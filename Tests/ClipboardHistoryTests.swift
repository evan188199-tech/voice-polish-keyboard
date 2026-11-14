import XCTest
@testable import VoicePolishApp

final class ClipboardHistoryTests: XCTestCase {

    // MARK: - ClipboardHistoryStore

    func testAppendDedupsConsecutiveIdentical() {
        var entries: [ClipboardEntry] = []
        entries = ClipboardHistoryStore.append("hello", to: entries)
        entries = ClipboardHistoryStore.append("hello", to: entries)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.text, "hello")
    }

    func testAppendAllowsReAddingAfterDifferentContent() {
        var entries: [ClipboardEntry] = []
        entries = ClipboardHistoryStore.append("A", to: entries)
        entries = ClipboardHistoryStore.append("B", to: entries)
        entries = ClipboardHistoryStore.append("A", to: entries)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first?.text, "A", "re-adding A after B should insert it again at the top")
    }

    func testAppendSkipsWhitespaceOnly() {
        var entries: [ClipboardEntry] = []
        entries = ClipboardHistoryStore.append("   \n  ", to: entries)
        XCTAssertTrue(entries.isEmpty)
    }

    func testAppendTruncatesLongText() {
        let long = String(repeating: "x", count: ClipboardHistoryPolicy.maxTextLength + 500)
        var entries: [ClipboardEntry] = []
        entries = ClipboardHistoryStore.append(long, to: entries)
        XCTAssertEqual(entries.first?.text.count, ClipboardHistoryPolicy.maxTextLength)
    }

    func testAppendCapsAtMaxEntries() {
        var entries: [ClipboardEntry] = []
        for i in 0..<(ClipboardHistoryPolicy.maxEntries + 20) {
            entries = ClipboardHistoryStore.append("item-\(i)", to: entries)
        }
        XCTAssertEqual(entries.count, ClipboardHistoryPolicy.maxEntries)
        // Newest should be the last appended item.
        XCTAssertEqual(entries.first?.text, "item-\(ClipboardHistoryPolicy.maxEntries + 19)")
    }

    func testRemoveById() {
        var entries: [ClipboardEntry] = []
        entries = ClipboardHistoryStore.append("A", to: entries)
        entries = ClipboardHistoryStore.append("B", to: entries)
        let target = entries.first!.id
        entries = ClipboardHistoryStore.remove(id: target, from: entries)
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries.contains { $0.id == target })
    }

    func testLoadSaveRoundtrip() {
        let defaults = UserDefaults(suiteName: "clipboard-test-\(UUID().uuidString)")!
        var entries: [ClipboardEntry] = []
        let now = Date()
        entries = ClipboardHistoryStore.append("alpha", to: entries, at: now.addingTimeInterval(-1))
        entries = ClipboardHistoryStore.append("beta", to: entries, at: now)
        ClipboardHistoryStore.save(entries, defaults: defaults)

        let loaded = ClipboardHistoryStore.load(defaults: defaults)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first?.text, "beta")
        XCTAssertEqual(loaded.last?.text, "alpha")
    }

    func testPrunedCopyDropsExpired() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recent = ClipboardEntry(text: "recent", createdAt: now)
        let old = ClipboardEntry(
            text: "old",
            createdAt: now.addingTimeInterval(-(ClipboardHistoryPolicy.expirationDays + 1) * 86_400)
        )
        let pruned = ClipboardHistoryStore.prunedCopy([recent, old], at: now)
        XCTAssertEqual(pruned.count, 1)
        XCTAssertEqual(pruned.first?.text, "recent")
    }

    // MARK: - Mirror store

    @MainActor func testMirrorMergeReplacesAndFiltersHiddenIDs() {
        let suite = "clipboard-mirror-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let mirror = ClipboardMirrorStore(defaults: defaults)

        let e1 = ClipboardEntry(text: "A", createdAt: Date())
        let e2 = ClipboardEntry(text: "B", createdAt: Date())
        mirror.merge([e1, e2])
        XCTAssertEqual(mirror.entries.count, 2)

        mirror.hide(id: e1.id)
        XCTAssertEqual(mirror.entries.count, 1)
        XCTAssertFalse(mirror.entries.contains { $0.id == e1.id })

        // Re-merge the full snapshot; the hidden id stays hidden.
        let visible = mirror.merge([e1, e2])
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.id, e2.id)
    }

    @MainActor func testMirrorClearMarksAllAsHidden() {
        let defaults = UserDefaults(suiteName: "clipboard-mirror-clear-\(UUID().uuidString)")!
        let mirror = ClipboardMirrorStore(defaults: defaults)
        let e1 = ClipboardEntry(text: "A", createdAt: Date())
        let e2 = ClipboardEntry(text: "B", createdAt: Date())
        mirror.merge([e1, e2])
        mirror.clear()
        XCTAssertTrue(mirror.entries.isEmpty)
        // After clear, re-pushing the same entries should still yield nothing.
        let visible = mirror.merge([e1, e2])
        XCTAssertTrue(visible.isEmpty)
    }

    // MARK: - Bridge protocol round-trips

    func testClipboardWireMessageRoundtrip() throws {
        let entries = [
            ClipboardEntry(text: "hello", createdAt: Date(timeIntervalSince1970: 1234))
        ]
        let message = WireMessage(command: .syncClipboardHistory, token: "t", clipboardEntries: entries)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        XCTAssertEqual(decoded.command, .syncClipboardHistory)
        XCTAssertEqual(decoded.clipboardEntries?.count, 1)
        XCTAssertEqual(decoded.clipboardEntries?.first?.text, "hello")
    }

    func testClearClipboardCommandRoundtrip() throws {
        let message = WireMessage(command: .clearClipboardHistory, token: "t")
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        XCTAssertEqual(decoded.command, .clearClipboardHistory)
        XCTAssertNil(decoded.clipboardEntries)
    }

    func testClipboardBridgeResponseRoundtrip() throws {
        let entries = [ClipboardEntry(text: "x", createdAt: Date())]
        let response = BridgeResponse.ok(message: "done", clipboardEntries: entries)
        let wire = WireResponse(requestID: UUID(), response: response)
        let data = try JSONEncoder().encode(wire)
        let decoded = try JSONDecoder().decode(WireResponse.self, from: data)
        XCTAssertEqual(decoded.response.outcome, .ok)
        XCTAssertEqual(decoded.response.clipboardEntries?.count, 1)
        XCTAssertEqual(decoded.response.clipboardEntries?.first?.text, "x")
    }

    func testExistingResponsesHaveNilClipboardEntries() {
        XCTAssertNil(BridgeResponse.ok().clipboardEntries)
        XCTAssertNil(BridgeResponse.text("hi").clipboardEntries)
        XCTAssertNil(BridgeResponse.error("nope").clipboardEntries)
    }
}
