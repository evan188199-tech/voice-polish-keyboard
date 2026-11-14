import SwiftUI

/// Local settings only. This checkpoint does not turn on a production backend.
struct TranslationSettingsView: View {
    @ObservedObject var preferences: TranslationPreferences = .shared
    let service: TranslationServiceRegistry
    @State private var capability: TranslationCapability = .unavailable
    var body: some View {
        List {
            Section("翻译目标语言") {
                ForEach(preferences.targets) { target in Text(target.displayName) }
                    .onDelete { offsets in
                        let original = preferences.targets
                        for index in offsets { preferences.remove(original[index]) }
                        revokeService()
                    }
                    .onMove { source, destination in
                        if let index = source.first { preferences.move(from: index, to: destination) }
                        revokeService()
                    }
                Menu("添加目标语言") {
                    ForEach(TranslationTarget.choices) { target in
                        Button(target.displayName) { preferences.add(target); revokeService() }.disabled(preferences.targets.contains(target))
                    }
                }
            }
            Section("服务与数据去向") {
                Text(capability.serviceLabel)
                Toggle("允许当前已选服务用于翻译", isOn: Binding(
                    get: { capability.isAvailable && preferences.consentServiceID == capability.serviceID },
                    set: { enabled in
                        preferences.consent(to: enabled && capability.isAvailable ? capability.serviceID : nil)
                        if !enabled { revokeService() }
                    }))
                    .disabled(!capability.isAvailable)
                Text("仅主动翻译时发送当前原文，不默认上传音频、宿主全文或私人词典。此开关记录你的同意，不代表模型能力、密钥、额度或网络已验证。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("当前真实翻译适配仍禁用，仅完成本地模块及 mock 检查；不可宣称离线翻译或生产服务可用。")
                    .font(.caption).foregroundStyle(.orange)
            }
            Section("操作") {
                Text("键盘单点 Speak 普通听写；长按后上滑选择语言再说话，点 Speak 结束。成功译文直接插入草稿，不自动发送；原文与可选预览在恢复入口。")
                    .font(.caption)
            }
        }
        .navigationTitle("翻译目标语言")
        .task { capability = await service.capability }
        .toolbar { EditButton() }
    }

    private func revokeService() {
        Task {
            await service.revoke()
            capability = await service.capability
        }
    }
}
