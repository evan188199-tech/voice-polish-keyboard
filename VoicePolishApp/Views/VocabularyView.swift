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
                    Text("用于本地整理与可选 API 润色提示，帮助保留产品名、人名与中英粤混合表达。")
                }

                Section("词表 (\(entries.count))") {
                    if entries.isEmpty {
                        Text("暂无词条").foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        Text(entry.phrase)
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
