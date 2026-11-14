import Foundation

/// Minimum, account-scoped private index data. No credentials or source URLs.
struct PrivateIndexScope: Codable, Hashable, Sendable {
    let accountID: String
    let sourceID: String
    /// Handles only: do not put email addresses, source URLs or credentials here.
    var isValid: Bool {
        let pattern = #"^[A-Za-z0-9._-]{1,128}$"#
        return accountID.range(of: pattern, options: .regularExpression) != nil
            && sourceID.range(of: pattern, options: .regularExpression) != nil
    }
}
struct PrivateIndexItem: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case term, place, route }
    let id: UUID
    let kind: Kind
    let title: String
    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf8.count <= 512
            && title.rangeOfCharacter(from: .controlCharacters) == nil
            && title.range(of: #"https?://|@|token|secret|password"#, options: [.regularExpression, .caseInsensitive]) == nil
    }
}
struct PrivateIndexDocument: Codable, Equatable, Sendable {
    let scope: PrivateIndexScope
    let revision: UInt64
    let items: [PrivateIndexItem]
    var isValid: Bool {
        scope.isValid && revision > 0 && items.count <= 2_000 && items.allSatisfy(\.isValid)
            && Set(items.map(\.id)).count == items.count
    }
}
enum PrivateIndexError: Error, Equatable { case invalid, wrongScope, unavailable, untrusted, expired, stale }

/// Persistent implementations must encrypt before writing to disk. The document
/// exists in memory while processing; unconfigured storage must remain disabled.
protocol PrivateIndexStorage: Sendable {
    func load(scope: PrivateIndexScope) throws -> PrivateIndexDocument?
    func save(_ document: PrivateIndexDocument) throws
    func remove(scope: PrivateIndexScope) throws
}
struct DisabledPrivateIndexStorage: PrivateIndexStorage {
    func load(scope: PrivateIndexScope) throws -> PrivateIndexDocument? { throw PrivateIndexError.unavailable }
    func save(_ document: PrivateIndexDocument) throws { throw PrivateIndexError.unavailable }
    func remove(scope: PrivateIndexScope) throws { throw PrivateIndexError.unavailable }
}

/// Calls into storage are synchronous and serialized by this actor, including revoke.
actor PrivateIndexCoordinator {
    private let storage: any PrivateIndexStorage
    private var activeScope: PrivateIndexScope?
    private var current: PrivateIndexDocument?
    private var pendingRemoval = Set<PrivateIndexScope>()
    private var activationID = UUID()
    init(storage: any PrivateIndexStorage = DisabledPrivateIndexStorage()) { self.storage = storage }
    func activate(_ scope: PrivateIndexScope) throws {
        activeScope = nil; current = nil; activationID = UUID()
        guard scope.isValid else { throw PrivateIndexError.invalid }
        guard !pendingRemoval.contains(scope) else { throw PrivateIndexError.unavailable }
        let loaded = try storage.load(scope: scope)
        if let loaded, (!loaded.isValid || loaded.scope != scope) { throw PrivateIndexError.wrongScope }
        activeScope = scope; current = loaded
    }
    func replace(_ items: [PrivateIndexItem], expectedScope: PrivateIndexScope) throws {
        guard activeScope == expectedScope else { throw PrivateIndexError.wrongScope }
        guard (current?.revision ?? 0) < UInt64.max else { throw PrivateIndexError.invalid }
        let next = PrivateIndexDocument(scope: expectedScope, revision: (current?.revision ?? 0) + 1, items: items)
        guard next.isValid else { throw PrivateIndexError.invalid }
        try storage.save(next)
        current = next
    }
    func lease(expectedScope: PrivateIndexScope) throws -> (id: UUID, document: PrivateIndexDocument?) {
        guard activeScope == expectedScope else { throw PrivateIndexError.wrongScope }
        return (activationID, current)
    }
    func document(expectedScope: PrivateIndexScope) throws -> PrivateIndexDocument? {
        guard activeScope == expectedScope else { throw PrivateIndexError.wrongScope }
        return current
    }
    func list(expectedScope: PrivateIndexScope) throws -> [PrivateIndexItem] {
        guard activeScope == expectedScope else { throw PrivateIndexError.wrongScope }
        return current?.items ?? []
    }
    func search(_ query: String, expectedScope: PrivateIndexScope) throws -> [PrivateIndexItem] {
        guard activeScope == expectedScope else { throw PrivateIndexError.wrongScope }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 256 else { return [] }
        return (current?.items ?? []).filter { $0.title.localizedCaseInsensitiveContains(text) }
    }
    func deactivate() { activeScope = nil; current = nil; activationID = UUID() }
    func revoke(_ scope: PrivateIndexScope) throws {
        guard activeScope == scope else { throw PrivateIndexError.wrongScope }
        try erase(scope)
    }
    func erase(_ scope: PrivateIndexScope) throws {
        guard scope.isValid else { throw PrivateIndexError.invalid }
        // Drop a matching live view before deletion; a failure is visible to caller.
        if activeScope == scope { activeScope = nil; current = nil; activationID = UUID() }
        pendingRemoval.insert(scope)
        try retryRemoval(scope)
    }
    func retryRemoval(_ scope: PrivateIndexScope) throws {
        guard pendingRemoval.contains(scope) else { throw PrivateIndexError.wrongScope }
        try storage.remove(scope: scope)
        pendingRemoval.remove(scope)
    }
}

/// A transport must authenticate its peer and bind data to a fresh account/session.
/// Existing loopback BuildToken is public and is not accepted as that proof.
struct PrivateSnapshot: Codable, Equatable, Sendable {
    let sessionID: UUID
    let scope: PrivateIndexScope
    let revision: UInt64
    let expiresAt: Date
    let items: [PrivateIndexItem]
}
/// A verifier must bind a fresh session and scope to an authenticated peer.
/// The existing public build token cannot implement this contract.
protocol PrivatePeerVerifying: Sendable {
    func permits(sessionID: UUID, scope: PrivateIndexScope) async -> Bool
}
struct DenyPrivatePeer: PrivatePeerVerifying {
    func permits(sessionID: UUID, scope: PrivateIndexScope) async -> Bool { false }
}
actor PrivateSnapshotPublisher {
    private let index: PrivateIndexCoordinator
    private let verifier: any PrivatePeerVerifying
    init(index: PrivateIndexCoordinator, verifier: any PrivatePeerVerifying = DenyPrivatePeer()) {
        self.index = index; self.verifier = verifier
    }
    /// Only explicitly selected IDs are projected. No credential, source URL,
    /// material link or full private document is included in a snapshot.
    func make(sessionID: UUID, scope: PrivateIndexScope, selectedIDs: Set<UUID>, now: Date = Date()) async throws -> PrivateSnapshot {
        let before = try await index.lease(expectedScope: scope)
        guard await verifier.permits(sessionID: sessionID, scope: scope) else { throw PrivateIndexError.untrusted }
        let after = try await index.lease(expectedScope: scope)
        guard before.id == after.id, before.document == after.document else { throw PrivateIndexError.stale }
        guard selectedIDs.count <= 100, let document = after.document else { throw PrivateIndexError.unavailable }
        let items = document.items.filter { selectedIDs.contains($0.id) }
        guard items.count == selectedIDs.count else { throw PrivateIndexError.invalid }
        return PrivateSnapshot(sessionID: sessionID, scope: scope, revision: document.revision,
                               expiresAt: now.addingTimeInterval(60), items: items)
    }
}

protocol PrivateSnapshotTransport: Sendable {
    func authenticatedSnapshot(sessionID: UUID, scope: PrivateIndexScope) async throws -> PrivateSnapshot
}
struct DisabledPrivateSnapshotTransport: PrivateSnapshotTransport {
    func authenticatedSnapshot(sessionID: UUID, scope: PrivateIndexScope) async throws -> PrivateSnapshot {
        throw PrivateIndexError.unavailable
    }
}
actor PrivateSnapshotReader {
    private let transport: any PrivateSnapshotTransport
    private var generation: UInt64 = 0
    private var sessionID = UUID()
    private var activeScope: PrivateIndexScope?
    private var snapshot: PrivateSnapshot?
    init(transport: any PrivateSnapshotTransport = DisabledPrivateSnapshotTransport()) { self.transport = transport }
    func connect(scope: PrivateIndexScope, now: Date = Date()) async throws {
        generation &+= 1; let epoch = generation
        sessionID = UUID(); let session = sessionID
        activeScope = nil; snapshot = nil
        guard scope.isValid else { throw PrivateIndexError.invalid }
        let received = try await transport.authenticatedSnapshot(sessionID: session, scope: scope)
        guard generation == epoch else { throw PrivateIndexError.stale }
        guard received.sessionID == session, received.scope == scope, received.revision > 0,
              received.items.count <= 2_000, received.items.allSatisfy(\.isValid),
              Set(received.items.map(\.id)).count == received.items.count else { throw PrivateIndexError.untrusted }
        guard received.expiresAt > now, received.expiresAt.timeIntervalSince(now) <= 300 else { throw PrivateIndexError.expired }
        activeScope = scope; snapshot = received
    }
    func search(_ query: String, scope: PrivateIndexScope, now: Date = Date()) throws -> [PrivateIndexItem] {
        guard activeScope == scope, let snapshot else { throw PrivateIndexError.wrongScope }
        guard snapshot.expiresAt > now else { self.snapshot = nil; activeScope = nil; throw PrivateIndexError.expired }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 256 else { return [] }
        return snapshot.items.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }
    func expiration(scope: PrivateIndexScope) -> Date? {
        guard activeScope == scope else { return nil }
        return snapshot?.expiresAt
    }
    func disconnect() { generation &+= 1; activeScope = nil; snapshot = nil; sessionID = UUID() }
}
