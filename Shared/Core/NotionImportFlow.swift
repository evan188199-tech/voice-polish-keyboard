import Foundation
import Combine

/// UI-facing state. The default reader cannot access a network or credentials.
@MainActor final class NotionImportFlow: ObservableObject {
    @Published var sourceID = ""
    @Published var propertyID = ""
    @Published var propertyName = ""
    @Published var kind: PrivateTermCandidate.Kind = .general
    @Published private(set) var busy = false
    @Published private(set) var status = "未连接：需先配置授权账号与来源。"
    private var generation = 0
    private let reader: NotionPrivatePreviewReader
    init(reader: NotionPrivatePreviewReader = NotionPrivatePreviewReader()) { self.reader = reader }

    func cancel() { generation &+= 1; busy = false; status = "已取消；未导入任何内容。" }
    func fetch(session: PrivateMaterialSession) async -> TermImportPreview? {
        guard !busy, let account = session.account, account.isDemo,
              let source = UUID(uuidString: sourceID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            status = "请选择演示会话并填写有效来源 ID；真实账号尚未连接。"; return nil
        }
        let fieldID = propertyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fieldID.isEmpty, !name.isEmpty, fieldID.utf8.count <= 128, name.utf8.count <= 128 else {
            status = "请填写要预览的字段 ID 和字段名称。"; return nil
        }
        generation &+= 1; let token = generation
        busy = true; status = "正在读取所选字段；尚未导入。"
        do {
            let result = try await session.previewNotion(sourceID: source,
                fields: [NotionPreviewField(propertyID: fieldID, responseName: name, kind: kind)], reader: reader)
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
