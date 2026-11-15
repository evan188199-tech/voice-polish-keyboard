import SwiftUI

struct PlaceNameDictionaryView: View {
    @ObservedObject var store: PlaceNameDictionaryStore = .shared
    @State private var query = ""
    @State private var editing: PlaceNameEntry?
    var body: some View {
        List {
            Section {
                Text("本地转写后辅助，不是 ASR 热词增强。只提示你录入的别名；每次修改需确认，不回改其他应用文字。私人词条不会整表发送到云端。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("新增本地地名") { editing = PlaceNameEntry(name: "") }
            }
            Section("地名词表") {
                ForEach(store.search(query)) { entry in
                    VStack(alignment: .leading) {
                        HStack {
                            Button { editing = entry } label: {
                                VStack(alignment: .leading) {
                                    Text(entry.name + (entry.traditional == entry.name ? "" : " / " + entry.traditional))
                                    Text("\(entry.language.rawValue) · \(entry.region) · \(entry.isConfirmed ? "用户已核对" : "未核对")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Toggle("启用", isOn: Binding(get: { entry.isEnabled }, set: { store.setEnabled(entry.id, $0) }))
                                .labelsHidden()
                        }
                        Text(entry.source).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    let visible = store.search(query)
                    for offset in offsets { store.remove(visible[offset].id) }
                }
            }
        }
        .navigationTitle("旅游地名词典")
        .searchable(text: $query, prompt: "地名、别名、语言或地区")
        .sheet(item: $editing) { entry in
            NavigationStack {
                PlaceNameEditor(entry: entry) { try store.upsert($0) }
            }
        }
    }
}
private struct PlaceNameEditor: View {
    @State var entry: PlaceNameEntry
    let onSave: (PlaceNameEntry) throws -> Void
    @State private var aliases = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section("本地词条") {
                TextField("规范地名", text: $entry.name)
                TextField("对应繁体写法（可空）", text: $entry.traditional)
                TextField("别名/待确认写法，以逗号分隔", text: $aliases)
                Picker("语言标签", selection: $entry.language) {
                    ForEach(PlaceLanguage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextField("地区说明（可空，用于同名区分）", text: $entry.region)
                TextField("来源说明（只存本机）", text: $entry.source)
                Toggle("我已核对词条", isOn: $entry.isConfirmed)
                Toggle("启用候选", isOn: $entry.isEnabled)
            }
            Section {
                Text("不提供未经核验的拼音/粤拼。别名命中也只给候选，不会自动替换。确认某次纠错不会扩大为永久规则。")
                    .font(.caption)
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("编辑地名")
        .onAppear { aliases = entry.aliases.joined(separator: "，") }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    entry.aliases = aliases.components(separatedBy: CharacterSet(charactersIn: ",，\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    do { try onSave(entry); dismiss() } catch { self.error = error.localizedDescription }
                }
            }
        }
    }
}
