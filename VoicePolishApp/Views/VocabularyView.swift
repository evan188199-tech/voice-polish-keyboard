import SwiftUI

struct VocabularyView: View {
    @ObservedObject var settings: AppSettings
    @State private var entries: [VocabularyEntry]
    @State private var newPhrase = ""
    @Environment(\.dismiss) private var dismiss

    init(settings: AppSettings) {
        self.settings = settings
        _entries = State(initialValue: VocabularyEntry.load())
    }

    var body: some View {
        NavigationStack {
            List {
                NavigationLink("旅游地名词典（本地候选确认）") { PlaceNameDictionaryView() }
                Section {
                    HStack {
                        TextField("添加词条", text: $newPhrase)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("添加") {
                            let phrase = newPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !phrase.isEmpty else { return }
                            entries.append(VocabularyEntry(phrase: phrase))
                            newPhrase = ""
                            persist()
                        }
                        .disabled(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("新增专有词")
                } footer: {
                    Text("英文词用于本地大小写整理；2–8 字中文词提供普通话音近候选，需确认，不自动改写，也不是声学热词。词表不会默认上传给润色服务。")
                }

                Section {
                    Text("开启下方词条开关后，仅所选词会随以后普通润色发送至当前配置：\(settings.baseURL) / \(settings.modelName)。默认关闭；切换配置、地址或模型后须重新选择。不发送备注；不用于问答、Coding 或连接探测。")
                        .font(.caption)
                    Text("仅支持保守文字词条，数字/标点及可疑指令词会被排除；最多20词、400字。开关不代表声学热词生效。")
                        .font(.caption)
                }
                Section("词表 (\(entries.count))") {
                    if entries.isEmpty {
                        Text("暂无词条").foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading) {
                            Text(entry.phrase)
                            Toggle("随润色发送此词", isOn: Binding(get: {
                                entry.polishDestination == settings.vocabularyDestination
                            }, set: { selected in
                                guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
                                entries[index].polishDestination = selected ? settings.vocabularyDestination : nil
                                persist()
                            }))
                            .font(.caption)
                        }
                    }
                    .onDelete { offsets in
                        entries.remove(atOffsets: offsets)
                        persist()
                    }
                    .onMove { source, destination in
                        entries.move(fromOffsets: source, toOffset: destination)
                        persist()
                    }
                }
            }
            .navigationTitle("专有词词表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
        }
    }

    private func persist() {
        VocabularyEntry.save(entries)
        settings.customVocabulary = entries.map(\.phrase).joined(separator: "\n")
    }
}
