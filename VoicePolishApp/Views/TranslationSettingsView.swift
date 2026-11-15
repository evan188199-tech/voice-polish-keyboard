import SwiftUI

/// Local settings only. This checkpoint does not turn on a production backend.
struct TranslationSettingsView: View {
    @ObservedObject var preferences: TranslationPreferences = .shared
    let serviceID: String?
    let serviceLabel: String
    var body: some View {
        List {
            Section("翻译目标语言") {
                ForEach(preferences.targets) { target in Text(target.displayName) }
                    .onDelete { offsets in
                        let original = preferences.targets
                        for index in offsets { preferences.remove(original[index]) }
                    }
                    .onMove { source, destination in
                        if let index = source.first { preferences.move(from: index, to: destination) }
                    }
                Menu("添加目标语言") {
                    ForEach(TranslationTarget.choices) { target in
                        Button(target.displayName) { preferences.add(target) }.disabled(preferences.targets.contains(target))
                    }
                }
            }
            Section("服务与数据去向") {
                Text(serviceLabel)
                Toggle("允许当前已选服务用于翻译", isOn: Binding(
                    get: { serviceID != nil && preferences.consentServiceID == serviceID },
                    set: { preferences.consent(to: $0 ? serviceID : nil) }))
                    .disabled(serviceID == nil)
                Text("仅主动翻译时发送当前原文，不默认上传音频、宿主全文或私人词典。此开关记录你的同意，不代表模型能力、密钥、额度或网络已验证。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("翻译服务暂不可用。")
                    .font(.caption).foregroundStyle(.orange)
            }
            Section("操作") {
                Text("键盘单点 Speak 普通听写；翻译服务可用时，长按后上滑选择语言再说话，点 Speak 结束。译文保留后可由你确认插入，不会自动发送。")
                    .font(.caption)
            }
        }
        .navigationTitle("翻译目标语言")
        .toolbar { EditButton() }
    }
}
