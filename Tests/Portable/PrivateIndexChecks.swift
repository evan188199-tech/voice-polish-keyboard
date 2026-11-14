import Foundation

final class FictionalIndexStore: PrivateIndexStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [PrivateIndexScope: PrivateIndexDocument] = [:]
    private var refuseDelete = false
    private var refuseSave = false
    func setRefuseSave(_ value: Bool) { lock.withLock { refuseSave = value } }
    func setRefuseDelete(_ value: Bool) { lock.withLock { refuseDelete = value } }
    func load(scope: PrivateIndexScope) throws -> PrivateIndexDocument? { lock.withLock { data[scope] } }
    func save(_ document: PrivateIndexDocument) throws {
        try lock.withLock { if refuseSave { throw PrivateIndexError.unavailable }; data[document.scope] = document }
    }
    func remove(scope: PrivateIndexScope) throws {
        try lock.withLock { if refuseDelete { throw PrivateIndexError.unavailable }; data[scope] = nil }
    }
}
actor FictionalSnapshotTransport: PrivateSnapshotTransport {
    enum Mode { case good, wrongScope, expired, longLived, delayed }
    var mode: Mode
    var pending: CheckedContinuation<PrivateSnapshot, Error>?
    init(_ mode: Mode) { self.mode = mode }
    func authenticatedSnapshot(sessionID: UUID, scope: PrivateIndexScope) async throws -> PrivateSnapshot {
        if mode == .delayed { return try await withCheckedThrowingContinuation { pending = $0 } }
        let actual = mode == .wrongScope ? PrivateIndexScope(accountID: "fiction-B", sourceID: scope.sourceID) : scope
        let expiry = Date().addingTimeInterval(mode == .expired ? -1 : (mode == .longLived ? 600 : 60))
        return PrivateSnapshot(sessionID: sessionID, scope: actual, revision: 1, expiresAt: expiry,
                               items: [PrivateIndexItem(id: UUID(), kind: .route, title: "虚构路线")])
    }
    func isPending() -> Bool { pending != nil }
    func resolve(scope: PrivateIndexScope) {
        pending?.resume(returning: PrivateSnapshot(sessionID: UUID(), scope: scope, revision: 1,
                                                   expiresAt: Date().addingTimeInterval(60), items: []))
        pending = nil
    }
}

struct FictionalTrustedPeer: PrivatePeerVerifying {
    func permits(sessionID: UUID, scope: PrivateIndexScope) async -> Bool { true }
}
actor DelayedPeerVerifier: PrivatePeerVerifying {
    private var pending: CheckedContinuation<Bool, Never>?
    func permits(sessionID: UUID, scope: PrivateIndexScope) async -> Bool {
        await withCheckedContinuation { pending = $0 }
    }
    func isPending() -> Bool { pending != nil }
    func resolve() { pending?.resume(returning: true); pending = nil }
}
struct FictionalPublisherTransport: PrivateSnapshotTransport {
    let publisher: PrivateSnapshotPublisher
    let selectedIDs: Set<UUID>
    func authenticatedSnapshot(sessionID: UUID, scope: PrivateIndexScope) async throws -> PrivateSnapshot {
        try await publisher.make(sessionID: sessionID, scope: scope, selectedIDs: selectedIDs)
    }
}

@MainActor enum PrivateIndexChecks {
    static func run() async {
        let check = KeyboardChecks.check
        let a = PrivateIndexScope(accountID: "fiction-A", sourceID: "fiction-source")
        let b = PrivateIndexScope(accountID: "fiction-B", sourceID: "fiction-source")
        check(!PrivateIndexScope(accountID: "person@example.test", sourceID: "fiction-source").isValid &&
              !PrivateIndexScope(accountID: "fiction-A", sourceID: "https://example.test/private").isValid,
              "index scopes reject email addresses and source URLs")
        let item = PrivateIndexItem(id: UUID(), kind: .route, title: "虚构路线甲")
        let forbidden = PrivateIndexItem(id: UUID(), kind: .term, title: "https://fiction.invalid/internal")
        check(!forbidden.isValid, "private index refuses URL-like content as a search term")
        let store = FictionalIndexStore()
        let index = PrivateIndexCoordinator(storage: store)
        try! await index.activate(a)
        try! await index.replace([item], expectedScope: a)
        let found = try! await index.search("路线", expectedScope: a)
        check(found == [item], "confirmed fictional index is searchable within its scope")
        store.setRefuseSave(true)
        do { try await index.replace([], expectedScope: a); check(false, "failed save must be visible") }
        catch { check(true, "failed save is reported to the caller") }
        let afterFailedSave = try! await index.search("路线", expectedScope: a)
        check(afterFailedSave == [item], "failed save keeps prior in-memory index unchanged")
        store.setRefuseSave(false)
        await index.deactivate()
        do { _ = try await index.search("路线", expectedScope: a); check(false, "deactivated index must not be searchable") }
        catch { check(true, "account switch clears the active in-memory index") }
        try! await index.activate(a)
        let afterReactivation = try! await index.search("路线", expectedScope: a)
        check(afterReactivation == [item], "explicit local save remains account-scoped across deactivation")
        let reopened = PrivateIndexCoordinator(storage: store)
        try! await reopened.activate(a)
        let restored = try! await reopened.search("路线", expectedScope: a)
        check(restored == [item], "injected storage restores index across coordinator reconstruction")
        do { _ = try await reopened.search("路线", expectedScope: b); check(false, "wrong account must fail") }
        catch { check(true, "other account cannot search the current index") }
        do { try await reopened.replace([item, item], expectedScope: a); check(false, "duplicate IDs must fail") }
        catch { check(true, "duplicate private index identifiers are rejected") }
        try! await reopened.revoke(a)
        try! await reopened.activate(a)
        let afterDelete = try! await reopened.search("路线", expectedScope: a)
        check(afterDelete.isEmpty, "revocation deletes the mocked persisted index")
        try! await index.activate(a)
        try! await index.replace([item], expectedScope: a)
        store.setRefuseDelete(true)
        do { try await index.revoke(a); check(false, "delete failure must be visible") }
        catch { check(true, "failed deletion is reported rather than claiming success") }
        do { _ = try await index.search("路线", expectedScope: a); check(false, "failed revoke must close session") }
        catch { check(true, "failed revoke still clears active in-memory access") }
        do { try await index.activate(a); check(false, "failed deletion cannot reopen scope") }
        catch { check(true, "failed deletion blocks reopening until retry") }
        store.setRefuseDelete(false)
        try! await index.retryRemoval(a)
        try! await index.activate(a)
        let afterRetry = try! await index.search("路线", expectedScope: a)
        check(afterRetry.isEmpty, "successful retry completes failed revocation")
        try! await index.replace([item, PrivateIndexItem(id: UUID(), kind: .term, title: "不共享的虚构词")], expectedScope: a)
        let defaultPublisher = PrivateSnapshotPublisher(index: index)
        do { _ = try await defaultPublisher.make(sessionID: UUID(), scope: a, selectedIDs: [item.id]); check(false, "untrusted peer must fail") }
        catch { check(true, "snapshot publisher refuses every peer by default") }
        let publisher = PrivateSnapshotPublisher(index: index, verifier: FictionalTrustedPeer())
        let publisherReader = PrivateSnapshotReader(transport: FictionalPublisherTransport(publisher: publisher, selectedIDs: [item.id]))
        try! await publisherReader.connect(scope: a)
        let published = try! await publisherReader.search("路线", scope: a)
        check(published == [item], "fictional authenticated transport projects only explicitly selected terms")
        do { _ = try await publisher.make(sessionID: UUID(), scope: a, selectedIDs: [UUID()]); check(false, "unknown selection must fail") }
        catch { check(true, "snapshot cannot include an unselected or unknown private item") }
        let delayedPeer = DelayedPeerVerifier()
        let delayedPublisher = PrivateSnapshotPublisher(index: index, verifier: delayedPeer)
        let delayedPublish = Task { try await delayedPublisher.make(sessionID: UUID(), scope: a, selectedIDs: [item.id]) }
        while !(await delayedPeer.isPending()) { await Task.yield() }
        try! await index.activate(b); try! await index.activate(a)
        await delayedPeer.resolve()
        do { _ = try await delayedPublish.value; check(false, "old account session cannot publish") }
        catch { check((error as? PrivateIndexError) == .stale, "A-B-A scope switch invalidates delayed snapshot publication") }
        let termSession = PrivateMaterialSession()
        await termSession.useDemo("fiction-A")
        let termVersion = termSession.cacheVersion
        let placeItem = PrivateIndexItem(id: UUID(), kind: .place, title: "虚构地名")
        try! termSession.restoreLocalTerms([item, placeItem], expectedAccount: "fiction-A", expectedVersion: termVersion)
        check(termSession.privateTerms.count == 2 && termSession.privateTerms[1].kind == .place,
              "protected-index restore preserves route and place kinds after validation")
        await termSession.useDemo("fiction-B")
        do { try termSession.restoreLocalTerms([item], expectedAccount: "fiction-A", expectedVersion: termVersion); check(false, "stale restore must fail") }
        catch { check(termSession.privateTerms.isEmpty, "late protected-index restore cannot cross account switch") }
        let unavailable = PrivateSnapshotReader()
        do { try await unavailable.connect(scope: a); check(false, "default snapshot must fail closed") }
        catch { check(true, "production default never accepts the public bridge token as private authentication") }
        for mode in [FictionalSnapshotTransport.Mode.wrongScope, .expired, .longLived] {
            let reader = PrivateSnapshotReader(transport: FictionalSnapshotTransport(mode))
            do { try await reader.connect(scope: a); check(false, "invalid snapshot must fail") }
            catch { check(true, "wrong account or invalid snapshot expiry is rejected") }
        }
        let good = PrivateSnapshotReader(transport: FictionalSnapshotTransport(.good))
        try! await good.connect(scope: a)
        let matches = try! await good.search("路线", scope: a)
        check(matches.count == 1, "authenticated mock snapshot supports local private search")
        await good.disconnect()
        do { _ = try await good.search("路线", scope: a); check(false, "disconnect must clear snapshot") }
        catch { check(true, "disconnect drops private snapshot") }
        let keyboardSearch = PrivateReferenceSearchModel(reader: PrivateSnapshotReader(transport: FictionalSnapshotTransport(.good)))
        keyboardSearch.open()
        await keyboardSearch.connect(scope: a)
        keyboardSearch.append("路线")
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(keyboardSearch.results.count == 1, "keyboard mock searches authenticated scoped snapshot")
        if let match = keyboardSearch.results.first {
            check(keyboardSearch.choose(match.id) == "虚构路线", "explicit selection returns only the selected current result")
            check(keyboardSearch.choose(match.id, now: Date().addingTimeInterval(301)) == nil, "expired private result cannot be inserted")
        }
        keyboardSearch.close()
        check(keyboardSearch.results.isEmpty && !keyboardSearch.isOpen, "keyboard close clears private results")
        let disabledKeyboard = PrivateReferenceSearchModel()
        disabledKeyboard.open(); await disabledKeyboard.connect(scope: a)
        disabledKeyboard.append("路线")
        check(disabledKeyboard.results.isEmpty && disabledKeyboard.message.contains("不可用"), "keyboard default transport stays unconnected")
        disabledKeyboard.close()
        let slow = FictionalSnapshotTransport(.delayed)
        let stale = PrivateSnapshotReader(transport: slow)
        let task = Task { try await stale.connect(scope: a) }
        while !(await slow.isPending()) { await Task.yield() }
        await stale.disconnect(); await slow.resolve(scope: a)
        do { try await task.value; check(false, "late snapshot must fail") }
        catch { check(true, "late snapshot cannot revive a disconnected session") }
    }
}
