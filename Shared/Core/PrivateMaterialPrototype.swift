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
    /// Opaque source scope, never a source URL or credential. Only demo is currently accepted.
    var sourceScope = "demo"
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
    let id: UUID
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
        return TermImportPreview(id: UUID(), candidates: candidates, rejectedCount: rejected, ignoredFieldCount: ignored)
    }
}
enum MaterialPrototypeError: Error, LocalizedError {
    case disconnected, invalidImport, wrongAccount, reviewRequired, staleSelection
    var errorDescription: String? {
        switch self {
        case .disconnected: "真实账号尚未连接；仅能使用演示适配器。"
        case .invalidImport: "请选择不超过 256 KB 的 terms JSON；每行仅需 term 和 kind。"
        case .wrongAccount: "账号已切换，请重新预览并确认。"
        case .reviewRequired: "请先逐项人工核对导入预览。"
        case .staleSelection: "素材来源或会话已变化，请重新选择并确认。"
        }
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
/// Explicitly approved draft-only references, not delivery or customer-access proof.
struct MaterialTextReference: Equatable, Sendable {
    let title: String
    let summary: String
    let customerURL: URL
    let attribution: String
    let sourceVersion: Int
    var draftText: String { summary + "\n" + customerURL.absoluteString + "\n" + attribution }
}
struct MaterialImageReference: Equatable, Sendable {
    let materialID: UUID
    let sourceScope: String
    let sourceVersion: Int
}

/// Opaque confirmation context. No source URL, credentials, or internal content.
struct MaterialSelection: Equatable, Sendable {
    fileprivate let accountID: String
    fileprivate let generation: UInt64
    fileprivate let materialID: UUID
    fileprivate let sourceScope: String
    fileprivate let version: Int
}

@MainActor final class PrivateMaterialSession: ObservableObject {
    @Published private(set) var account: MaterialAccount?
    @Published private(set) var materials: [ProductMaterial] = []
    @Published private(set) var privateTerms: [PrivateTermCandidate] = []
    @Published private(set) var status = "真实账号未连接 · 仅提供本地/演示原型"
    @Published private(set) var cacheVersion = 0
    private let adapter: any MaterialReadOnlyAdapter
    private var generation: UInt64 = 0
    private var importPreviews: [UUID: (accountID: String, generation: UInt64, preview: TermImportPreview)] = [:]
    init(adapter: any MaterialReadOnlyAdapter = MockMaterialAdapter()) { self.adapter = adapter }
    var productionConnected: Bool { false }
    func connectProduction() { status = MaterialPrototypeError.disconnected.localizedDescription }
    func useDemo(_ id: String) async {
        clear()
        account = MaterialAccount(id: id, isDemo: true)
        let epoch = generation
        do {
            let result = try await adapter.materials(for: account!, now: Date())
            guard epoch == generation else { return }
            materials = result.filter { $0.accountID == id && $0.sourceScope == "demo" }
            status = materials.count == result.count ? "演示账号 \(id) · 无真实登录或同步" : "已拒绝不属于当前账号或来源的演示素材"
        } catch { if epoch == generation { status = error.localizedDescription } }
    }
    func logout() { clear(); status = "已清空本地演示缓存 · 真实账号未连接" }
    func revoke() { logout() }
    private func clear() {
        generation &+= 1; cacheVersion += 1
        account = nil; materials = []; privateTerms = []; importPreviews.removeAll()
    }
    /// The selected file is parsed locally; only allowed candidate fields are retained.
    func previewImport(_ data: Data) throws -> TermImportPreview {
        guard let account, account.isDemo else { throw MaterialPrototypeError.disconnected }
        let preview = try TermImportPreview.parse(data)
        importPreviews.removeAll()
        importPreviews[preview.id] = (account.id, generation, preview)
        return preview
    }
    /// No production caller or credential is configured; the reader is injected.
    func previewNotion(sourceID: UUID, fields: [NotionPreviewField], reader: NotionPrivatePreviewReader) async throws -> TermImportPreview {
        guard let account, account.isDemo else { throw MaterialPrototypeError.disconnected }
        let epoch = generation
        let preview: TermImportPreview
        do { preview = try await reader.preview(sourceID: sourceID, fields: fields) }
        catch NotionPreviewError.permission {
            if generation == epoch { clear(); status = "来源不可访问，已关闭本次会话；请重新核验授权。" }
            throw NotionPreviewError.permission
        }
        guard generation == epoch, self.account == account else { throw MaterialPrototypeError.wrongAccount }
        importPreviews.removeAll()
        importPreviews[preview.id] = (account.id, generation, preview)
        return preview
    }
    func confirmImport(_ preview: TermImportPreview, selected: Set<UUID>, expectedAccount: String, reviewed: Bool = false) throws {
        guard account?.id == expectedAccount else { throw MaterialPrototypeError.wrongAccount }
        guard reviewed else { throw MaterialPrototypeError.reviewRequired }
        guard let registered = importPreviews[preview.id], registered.accountID == expectedAccount,
              registered.generation == generation, registered.preview.candidates == preview.candidates,
              registered.preview.rejectedCount == preview.rejectedCount,
              registered.preview.ignoredFieldCount == preview.ignoredFieldCount,
              !selected.isEmpty, selected.isSubset(of: Set(preview.candidates.map(\.id))) else {
            throw MaterialPrototypeError.staleSelection
        }
        importPreviews[preview.id] = nil
        let chosen = preview.candidates.filter { selected.contains($0.id) }
        for term in chosen where !privateTerms.contains(where: { $0.term == term.term && $0.kind == term.kind }) { privateTerms.append(term) }
    }
    /// Installs only data from the user-chosen local index, while the originating
    /// account and session remain unchanged. It never writes to a host document.
    func restoreLocalTerms(_ items: [PrivateIndexItem], expectedAccount: String, expectedVersion: Int) throws {
        guard account?.id == expectedAccount, cacheVersion == expectedVersion else { throw MaterialPrototypeError.wrongAccount }
        let rows: [[String: String]] = items.map { item in
            let kind: String = item.kind == .route ? "privateRoute" : (item.kind == .place ? "place" : "general")
            return ["term": item.title, "kind": kind]
        }
        let data = try JSONSerialization.data(withJSONObject: ["terms": rows])
        let checked = try TermImportPreview.parse(data)
        guard checked.rejectedCount == 0, checked.candidates.count == items.count else { throw MaterialPrototypeError.invalidImport }
        privateTerms = checked.candidates
    }
    func searchTerms(_ query: String) -> [PrivateTermCandidate] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return privateTerms }
        return privateTerms.filter { $0.term.localizedCaseInsensitiveContains(text) }
    }
    func searchMaterials(_ query: String) -> [ProductMaterial] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return materials }
        return materials.filter { $0.displayName.localizedCaseInsensitiveContains(text) }
    }
    /// A permit is valid only for the exact currently registered item and session generation.
    func select(_ material: ProductMaterial) throws -> MaterialSelection {
        guard let account, materials.contains(material), material.accountID == account.id else {
            throw MaterialPrototypeError.staleSelection
        }
        return MaterialSelection(accountID: account.id, generation: generation, materialID: material.id,
                                 sourceScope: material.sourceScope, version: material.version)
    }
    func rejection(_ material: ProductMaterial, selection: MaterialSelection?, action: MaterialAction,
                   confirmed: Bool, now: Date = Date()) -> String? {
        guard let account, let selection, selection.accountID == account.id, selection.generation == generation,
              selection.materialID == material.id, selection.sourceScope == material.sourceScope,
              selection.version == material.version, materials.contains(material) else { return MaterialPrototypeError.staleSelection.localizedDescription }
        return MaterialGate.rejection(material, account: account, channel: "customerDraft", action: action,
                                      userConfirmed: confirmed, now: now)
    }
    func textReference(_ material: ProductMaterial, selection: MaterialSelection?, confirmed: Bool) throws -> MaterialTextReference {
        if let reason = rejection(material, selection: selection, action: .textDraft, confirmed: confirmed) {
            throw NSError(domain: "MaterialGate", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        guard let url = material.customerURL else { throw MaterialPrototypeError.staleSelection }
        return MaterialTextReference(title: material.displayName, summary: material.approvedSummary,
                                     customerURL: url, attribution: material.attribution, sourceVersion: material.version)
    }
    func draft(_ material: ProductMaterial, selection: MaterialSelection?, confirmed: Bool) throws -> String {
        try textReference(material, selection: selection, confirmed: confirmed).draftText
    }
    func imageReference(_ material: ProductMaterial, selection: MaterialSelection?, confirmed: Bool) throws -> MaterialImageReference {
        if let reason = rejection(material, selection: selection, action: .image, confirmed: confirmed) {
            throw NSError(domain: "MaterialGate", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        return MaterialImageReference(materialID: material.id, sourceScope: material.sourceScope, sourceVersion: material.version)
    }
    /// Deliberately fail closed. The existing TCP bridge is not an authenticated
    /// account-sharing channel, and no App Group entitlement is configured.
    func keyboardSnapshot(hasFullAccess: Bool, now: Date = Date()) -> MaterialKeyboardSnapshot? { nil }
    var keyboardAvailability: String { "私人素材未接入键盘：安全传输/签名权益尚未验证，请在主应用预览与分享。" }
}
