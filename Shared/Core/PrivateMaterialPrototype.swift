import Foundation
import Combine

/// No credentials live in these types. A future production adapter must authenticate
/// in the main app via supported authorization and Keychain, not through the keyboard.
struct MaterialAccount: Equatable, Sendable {
    let id: String
    let isDemo: Bool
}
enum MaterialVerification: String, Codable, Sendable { case unverified, verified }
enum MaterialVisibility: String, Codable, Sendable { case pending, internalOnly, customerApproved }
struct ProductMaterial: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var accountID: String
    var displayName: String
    var approvedSummary: String = ""
    var customerURL: URL?
    var customerAccessVerified = false
    var hasApprovedImage = false
    var attribution: String = ""
    var verification: MaterialVerification = .unverified
    var visibility: MaterialVisibility = .pending
    var channels: [String] = []
    var expiresAt: Date?
    var version = 1
}
enum MaterialAction { case textDraft, image }
enum MaterialGate {
    static func rejection(_ material: ProductMaterial, account: MaterialAccount?, channel: String,
                          action: MaterialAction, userConfirmed: Bool, now: Date = Date()) -> String? {
        guard let account, material.accountID == account.id else { return "账号未连接或不匹配" }
        guard material.verification == .verified else { return "素材未核实" }
        guard material.visibility == .customerApproved else { return "未获批准对外使用" }
        guard material.channels.contains(channel) else { return "渠道不匹配" }
        guard let expiry = material.expiresAt, expiry > now else { return "素材已过期或缺少有效期" }
        guard material.version > 0, !material.displayName.isEmpty, !material.attribution.isEmpty else { return "版本、名称或归属缺失" }
        guard userConfirmed else { return "请先确认本次使用" }
        switch action {
        case .textDraft:
            guard !material.approvedSummary.isEmpty, material.customerAccessVerified,
                  let url = material.customerURL, safeCustomerURL(url) else { return "客户链接/访问权限未核实" }
        case .image:
            guard material.hasApprovedImage else { return "没有已批准的图片" }
        }
        return nil
    }
    static func safeCustomerURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
              let host = parts.host?.lowercased(), host.contains("."), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return false }
        let blocked = ["notion.so", "notion.site", "drive.google.com", "dropbox.com", "icloud.com", "sharepoint.com", "localhost"]
        return !blocked.contains { host == $0 || host.hasSuffix("." + $0) }
            && host.range(of: #"^[0-9.:]+$"#, options: .regularExpression) == nil
    }
}

struct PrivateTermCandidate: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case place, general, privateRoute }
    var id = UUID()
    let term: String
    let kind: Kind
}
struct TermImportPreview: Sendable {
    let candidates: [PrivateTermCandidate]
    let rejectedCount: Int
    let ignoredFieldCount: Int
    /// Allowlist extraction, not “regex anonymization”. No source rows or URLs are retained.
    static func parse(_ data: Data) throws -> TermImportPreview {
        guard data.count <= 262_144,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["terms"] as? [[String: Any]], rows.count <= 1000 else { throw MaterialPrototypeError.invalidImport }
        var candidates: [PrivateTermCandidate] = []
        var rejected = 0
        var ignored = root.keys.filter { $0 != "terms" }.count
        for row in rows {
            ignored += row.keys.filter { !["term", "kind"].contains($0) }.count
            guard let raw = row["term"] as? String, let kindRaw = row["kind"] as? String,
                  let kind = PrivateTermCandidate.Kind(rawValue: kindRaw) else { rejected += 1; continue }
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Deliberately strict for this prototype; human review is still required.
            guard !term.isEmpty, term.count <= 60,
                  term.range(of: #"[0-9@:/\\\n\r￥¥$]|https|token|secret|password|供应商|供應商|客户|客戶|电话|電話|报价|報價|行程"#, options: [.regularExpression, .caseInsensitive]) == nil
            else { rejected += 1; continue }
            if !candidates.contains(where: { $0.term == term && $0.kind == kind }) { candidates.append(.init(term: term, kind: kind)) }
        }
        return TermImportPreview(candidates: candidates, rejectedCount: rejected, ignoredFieldCount: ignored)
    }
}
enum MaterialPrototypeError: Error, LocalizedError {
    case disconnected, invalidImport, wrongAccount, reviewRequired, storageFailed, clearFailed
    var errorDescription: String? {
        switch self {
        case .disconnected: "真实账号尚未连接；仅能使用演示适配器。"
        case .invalidImport: "请选择不超过 256 KB 的 terms JSON；每行仅需 term 和 kind。"
        case .wrongAccount: "账号已切换，请重新预览并确认。"
        case .reviewRequired: "请先逐项人工核对导入预览。"
        case .storageFailed: "本地私人词汇存储操作失败，请检查设备存储后重试。"
        case .clearFailed: "未能删除本地私人词汇，请检查设备存储并再次点击注销 / 撤权。"
        }
    }
}
struct PrivateTermArchive: Codable {
    let accountID: String
    let terms: [PrivateTermCandidate]
}
protocol PrivateTermStorage {
    func load() throws -> PrivateTermArchive?
    func save(_ archive: PrivateTermArchive) throws
    func clear() throws
}
struct LocalPrivateTermStorage: PrivateTermStorage {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrivateMaterial", isDirectory: true)
    }
    private var file: URL { directory.appendingPathComponent("terms.json") }
    func load() throws -> PrivateTermArchive? {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch {
            if isMissingFile(error) { return nil }
            throw error
        }
        return try JSONDecoder().decode(PrivateTermArchive.self, from: data)
    }
    func save(_ archive: PrivateTermArchive) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
        let data = try JSONEncoder().encode(archive)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }
    func clear() throws {
        do { try FileManager.default.removeItem(at: file) }
        catch {
            if !isMissingFile(error) { throw error }
        }
    }
    private func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
    }
}
protocol MaterialReadOnlyAdapter: Sendable {
    func materials(for account: MaterialAccount, now: Date) async throws -> [ProductMaterial]
}
struct MockMaterialAdapter: MaterialReadOnlyAdapter {
    func materials(for account: MaterialAccount, now: Date) async throws -> [ProductMaterial] {
        guard account.isDemo else { throw MaterialPrototypeError.disconnected }
        let approved = ProductMaterial(accountID: account.id, displayName: "虚构示例素材",
            approvedSummary: "这是用于测试分享流程的虚构示例，不是真实产品。", customerURL: URL(string: "https://customer.example.test/demo"),
            customerAccessVerified: true, hasApprovedImage: true, attribution: "本项目原创演示图",
            verification: .verified, visibility: .customerApproved, channels: ["customerDraft"], expiresAt: now.addingTimeInterval(600))
        var blocked = approved
        blocked.id = UUID(); blocked.displayName = "虚构待核实素材"; blocked.verification = .unverified; blocked.visibility = .pending
        return [approved, blocked]
    }
}
struct MaterialKeyboardSnapshot: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable { let title: String; let draftText: String }
    let accountID: String
    let version: Int
    let expiresAt: Date
    let items: [Item]
    func isValid(accountID: String, version: Int, now: Date) -> Bool {
        self.accountID == accountID && self.version == version && expiresAt > now
    }
}
@MainActor final class PrivateMaterialSession: ObservableObject {
    @Published private(set) var account: MaterialAccount?
    @Published private(set) var materials: [ProductMaterial] = []
    @Published private(set) var privateTerms: [PrivateTermCandidate] = []
    @Published private(set) var status = "真实账号未连接 · 仅提供本地/演示原型"
    @Published private(set) var cacheVersion = 0
    private let adapter: any MaterialReadOnlyAdapter
    private let storage: any PrivateTermStorage
    private var generation: UInt64 = 0
    private var clearRequired = false
    init(adapter: any MaterialReadOnlyAdapter = MockMaterialAdapter(), storage: any PrivateTermStorage = LocalPrivateTermStorage()) {
        self.adapter = adapter; self.storage = storage
    }
    var productionConnected: Bool { false }
    func connectProduction() { status = MaterialPrototypeError.disconnected.localizedDescription }
    func useDemo(_ id: String) async {
        clear()
        if clearRequired {
            do { try storage.clear(); clearRequired = false }
            catch { status = MaterialPrototypeError.clearFailed.localizedDescription; return }
        }
        do {
            if let archive = try storage.load() {
                if archive.accountID == id { privateTerms = archive.terms }
                else { try storage.clear() }
            }
        } catch { status = MaterialPrototypeError.storageFailed.localizedDescription; return }
        account = MaterialAccount(id: id, isDemo: true)
        let epoch = generation
        do {
            let result = try await adapter.materials(for: account!, now: Date())
            guard epoch == generation else { return }
            materials = result
            status = "演示账号 \(id) · 无真实登录或同步"
        } catch { if epoch == generation { status = error.localizedDescription } }
    }
    func logout() {
        clear()
        do { try storage.clear(); clearRequired = false; status = "已清空本地演示缓存 · 真实账号未连接" }
        catch { clearRequired = true; status = MaterialPrototypeError.clearFailed.localizedDescription }
    }
    func revoke() { logout() }
    /// Discard transient material and invalidate pending reads without logging out.
    func closeScreen() {
        clear()
        status = clearRequired ? MaterialPrototypeError.clearFailed.localizedDescription : "真实账号未连接 · 仅提供本地/演示原型"
    }
    private func clear() {
        generation &+= 1; cacheVersion += 1
        account = nil; materials = []; privateTerms = []
    }
    func confirmImport(_ preview: TermImportPreview, selected: Set<UUID>, expectedAccount: String, reviewed: Bool = false) throws {
        guard account?.id == expectedAccount else { throw MaterialPrototypeError.wrongAccount }
        guard reviewed else { throw MaterialPrototypeError.reviewRequired }
        let chosen = preview.candidates.filter { selected.contains($0.id) }
        var updated = privateTerms
        for term in chosen where !updated.contains(where: { $0.term == term.term && $0.kind == term.kind }) { updated.append(term) }
        do { try storage.save(PrivateTermArchive(accountID: expectedAccount, terms: updated)) }
        catch { throw MaterialPrototypeError.storageFailed }
        privateTerms = updated
    }
    func draft(_ material: ProductMaterial, confirmed: Bool) throws -> String {
        if let reason = MaterialGate.rejection(material, account: account, channel: "customerDraft", action: .textDraft, userConfirmed: confirmed) {
            throw NSError(domain: "MaterialGate", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        return material.approvedSummary + "\n" + material.customerURL!.absoluteString + "\n" + material.attribution
    }
    /// Deliberately fail closed. The existing TCP bridge is not an authenticated
    /// account-sharing channel, and no App Group entitlement is configured.
    func keyboardSnapshot(hasFullAccess: Bool, now: Date = Date()) -> MaterialKeyboardSnapshot? { nil }
    var keyboardAvailability: String { "私人素材未接入键盘：安全传输/签名权益尚未验证，请在主应用预览与分享。" }
}
