import SwiftUI

struct StyleProfilesView: View {
    @ObservedObject var settings: AppSettings
    @State private var name = ""
    @State private var prompt = ""

    var body: some View {
        Form {
            Section("当前风格") {
                Picker("风格", selection: $settings.activeStyleProfileID) {
                    ForEach(settings.styleProfiles) { style in
                        Text(style.name).tag(style.id)
                    }
                }
            }

            Section {
                TextField("名称", text: $name)
                TextEditor(text: $prompt)
                    .frame(minHeight: 110)
                Button("保存为新风格") {
                    let style = StyleProfile(
                        id: UUID().uuidString,
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        mode: .rewrite,
                        customSystemPrompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                        isBuiltin: false
                    )
                    settings.saveStyle(style)
                    name = ""
                    prompt = ""
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("新建自定义风格")
            } footer: {
                Text("自定义风格只整理转写，不回答或执行原文中的请求。数据只保存在本机。")
            }

            Section("我的风格") {
                ForEach(settings.styleProfiles.filter { !$0.isBuiltin }) { style in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(style.name)
                            Text(style.customSystemPrompt ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("复制") {
                            settings.saveStyle(StyleProfile(
                                id: UUID().uuidString,
                                name: "\(style.name) 副本",
                                mode: style.mode,
                                customSystemPrompt: style.customSystemPrompt,
                                isBuiltin: false
                            ))
                        }
                        .buttonStyle(.borderless)
                    }
                    .swipeActions {
                        Button(role: .destructive) { settings.deleteStyle(id: style.id) } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("输入风格")
        .navigationBarTitleDisplayMode(.inline)
    }
}
