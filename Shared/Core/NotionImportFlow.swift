import Foundation
import Combine

/// UI-facing state. The default reader cannot access a network or credentials.
@MainActor final class NotionImportFlow: ObservableObject {
    @Published var sourceID = "" { didSet { if sourceID != oldValue { cancel(); fields = []; selectedFieldID = ""; discoveredSource = nil } } }
    @Published private(set) var fields: [NotionSourceField] = []
    @Published var selectedFieldID = ""
    private var discoveredSource: UUID?
    @Published var kind: PrivateTermCandidate.Kind = .general
    @Published private(set) var busy = false
    @Published private(set) var status = "未连接：需先配置授权账号与来源。"
    private var generation = 0
    private let reader: NotionPrivatePreviewReader
    private let metadata: NotionSourceMetadataReader
    init(reader: NotionPrivatePreviewReader = NotionPrivatePreviewReader(), metadata: NotionSourceMetadataReader = NotionSourceMetadataReader()) { self.reader = reader; self.metadata = metadata }

    func cancel() { generation &+= 1; busy = false; fields = []; selectedFieldID = ""; discoveredSource = nil; status = "已取消；未导入任何内容。" }
    func discover(session: PrivateMaterialSession) async {
        guard !busy, let account = session.account, account.isDemo,
              let source = UUID(uuidString: sourceID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            status = "请选择演示会话并填写有效来源 ID；真实账号尚未连接。"; return
        }
        generation &+= 1; let token = generation; let accountVersion = session.cacheVersion
        busy = true; fields = []; selectedFieldID = ""; discoveredSource = nil; status = "正在读取字段配置。"
        do {
            let found = try await metadata.fields(sourceID: source)
            guard token == generation else { return }
            guard !Task.isCancelled, session.account == account, session.cacheVersion == accountVersion,
                  UUID(uuidString: sourceID.trimmingCharacters(in: .whitespacesAndNewlines)) == source else { busy = false; return }
            fields = found; discoveredSource = source; busy = false
            status = found.isEmpty ? "来源没有可预览的文本字段。" : "请选择允许预览的文本字段。"
        } catch {
            guard token == generation else { return }
            guard !Task.isCancelled, session.account == account, session.cacheVersion == accountVersion else { busy = false; return }
            fields = []; discoveredSource = nil; busy = false
            if (error as? NotionPreviewError) == .permission { session.logout(); status = "来源不可访问；会话已关闭，请重新核验授权。" }
            else { status = "无法读取字段：请检查连接、来源授权或配置。" }
        }
    }
    func fetch(session: PrivateMaterialSession) async -> TermImportPreview? {
        guard !busy, let account = session.account, account.isDemo,
              let source = UUID(uuidString: sourceID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            status = "请选择演示会话并填写有效来源 ID；真实账号尚未连接。"; return nil
        }
        guard discoveredSource == source, let field = fields.first(where: { $0.id == selectedFieldID }) else {
            status = "请先发现并选择当前来源的文本字段。"; return nil
        }
        generation &+= 1; let token = generation
        busy = true; status = "正在读取所选字段；尚未导入。"
        do {
            let result = try await session.previewNotion(sourceID: source,
                fields: [NotionPreviewField(propertyID: field.id, responseName: field.name, kind: kind)], reader: reader)
            guard token == generation, !Task.isCancelled, session.account == account else {
                session.discardImportPreview(result.id)
                return nil
            }
            busy = false; status = "预览完成；须逐项核对并明确确认才会导入。"
            return result
        } catch {
            guard token == generation else { return nil }
            busy = false
            switch error {
            case NotionPreviewError.permission: status = "来源不可访问；请核验账号和所选来源授权。"
            case NotionPreviewError.unavailable: status = "读取不可用：真实账号和只读服务尚未配置。"
            case is CancellationError: status = "已取消；未导入任何内容。"
            default: status = "预览失败；请检查字段、网络或来源后重试。未导入任何内容。"
            }
            return nil
        }
    }
}
