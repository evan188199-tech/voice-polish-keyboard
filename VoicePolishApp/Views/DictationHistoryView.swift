import SwiftUI

struct DictationHistoryView: View {
    @ObservedObject var store: DictationHistoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.entries.isEmpty {
                    ContentUnavailableView("暂无语音历史", systemImage: "waveform", description: Text("完成识别的语音会保存在本机。"))
                } else {
                    List {
                        ForEach(store.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.result ?? entry.transcript)
                                    .lineLimit(4)
                                if entry.result != nil, !entry.transcript.isEmpty {
                                    Text("原文：\(entry.transcript)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                HStack {
                                    Text(entry.mode.shortLabel)
                                    if let asr = entry.transcriptionLatencyMs { Text("识别 \(asr) ms") }
                                    if let polish = entry.polishingLatencyMs { Text("润色 \(polish) ms") }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                            .contextMenu {
                                if let text = entry.result ?? Optional(entry.transcript), !text.isEmpty {
                                    Button("复制") { UIPasteboard.general.string = text }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { store.remove(id: entry.id) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("语音历史")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("完成") { dismiss() } }
                if !store.entries.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) { Button("清空", role: .destructive) { store.clear() } }
                }
            }
        }
    }
}
