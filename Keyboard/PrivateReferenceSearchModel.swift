import Foundation
import Combine

/// Keyboard-only search over an authenticated short-lived snapshot. Production
/// transport is disabled until peer authentication is implemented and verified.
@MainActor final class PrivateReferenceSearchModel: ObservableObject {
    @Published private(set) var isOpen = false
    @Published var isEditing = false
    @Published private(set) var query = ""
    @Published private(set) var results: [PrivateIndexItem] = []
    @Published private(set) var message = "私人索引未连接，请在主应用查看状态。"
    private let reader: PrivateSnapshotReader
    private var scope: PrivateIndexScope?
    private var expiry: Date?
    private var generation: UInt64 = 0
    private var searchTask: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    init(reader: PrivateSnapshotReader = PrivateSnapshotReader()) { self.reader = reader }

    func open() { isOpen = true }
    func close() {
        generation &+= 1; searchTask?.cancel(); searchTask = nil
        isOpen = false; isEditing = false; query = ""; results = []; scope = nil; expiry = nil
        let previous = cleanup
        cleanup = Task { await previous?.value; await reader.disconnect() }
    }
    /// Only a verified transport may be supplied by the composition root. The
    /// current app does not call this with a real account or connect its TCP bridge.
    func connect(scope: PrivateIndexScope) async {
        generation &+= 1; let epoch = generation
        results = []; self.scope = nil; expiry = nil
        await cleanup?.value
        guard epoch == generation, isOpen else { return }
        do {
            try await reader.connect(scope: scope)
            guard epoch == generation, isOpen else { return }
            // Reader returns expiry as part of the authenticated snapshot.
            guard let until = await reader.expiration(scope: scope) else { throw PrivateIndexError.untrusted }
            guard epoch == generation, isOpen else { return }
            self.scope = scope; expiry = until
            message = "已连接当前会话；搜索并明确选择要插入当前输入框的词汇。"
            scheduleSearch()
        } catch {
            guard epoch == generation else { return }
            message = "私人索引不可用，未读取或插入内容。"
        }
    }
    func append(_ text: String) {
        let updated = query + text
        guard updated.utf8.count <= 256 else { message = "搜索内容过长。"; return }
        query = updated; scheduleSearch()
    }
    func deleteBackward() { if !query.isEmpty { query.removeLast(); scheduleSearch() } }
    func choose(_ id: UUID, now: Date = Date()) -> String? {
        guard isOpen, scope != nil, let expiry, expiry > now,
              let result = results.first(where: { $0.id == id }) else { return nil }
        // Explicit tap inserts into the current field; it does not assert original focus.
        return result.title
    }
    private func scheduleSearch() {
        generation &+= 1; let epoch = generation
        searchTask?.cancel(); results = []
        guard let scope, let expiry, expiry > Date(), !query.isEmpty else { return }
        let requested = query
        searchTask = Task { [weak self] in
            guard let self else { return }
            let matches = try? await self.reader.search(requested, scope: scope)
            guard !Task.isCancelled, self.generation == epoch, self.isOpen, self.scope == scope else { return }
            self.results = matches ?? []
            if matches == nil { self.message = "私人索引已过期或失效，请重新连接。" }
        }
    }
}
