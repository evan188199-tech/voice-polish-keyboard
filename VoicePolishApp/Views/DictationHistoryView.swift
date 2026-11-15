import SwiftUI
import UniformTypeIdentifiers

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
                            NavigationLink {
                                DictationDraftView(entry: entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.result ?? entry.transcript)
                                        .lineLimit(4)
                                    if entry.result != nil, !entry.transcript.isEmpty {
                                        Text("原文：\(entry.transcript)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    if let note = entry.processingNote {
                                        Text(note).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let error = entry.errorMessage {
                                        Text(error).font(.caption).foregroundStyle(.orange)
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
                            }
                            .contextMenu {
                                if let text = entry.result ?? Optional(entry.transcript), !text.isEmpty {
                                    Button("复制整理结果") { UIPasteboard.general.string = text }
                                    Button("恢复并复制识别原文") { UIPasteboard.general.string = entry.transcript }
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

/// A local, user-edited copy. Changes never rewrite a host field or history.
private struct DictationDraftView: View {
    let entry: DictationHistoryEntry
    @State private var draft: String
    @State private var explanation = ""
    @State private var suggestion: SpokenCorrectionSuggestion?
    @State private var previousDraft: String?
    @State private var undoAfter: String?
    @State private var notice: String?
    @State private var copyNotice: String?

    init(entry: DictationHistoryEntry) {
        self.entry = entry
        _draft = State(initialValue: entry.result ?? entry.transcript)
    }

    var body: some View {
        Form {
            Section("可编辑草稿") {
                TextEditor(text: $draft).frame(minHeight: 160)
                    .accessibilityLabel("语音历史草稿")
                    .onChange(of: draft) { _, _ in suggestion = nil }
                Button("恢复识别原文") { previousDraft = draft; undoAfter = entry.transcript; draft = entry.transcript }
                Button("撤销上次采用或恢复") {
                    if let previousDraft, draft == undoAfter {
                        draft = previousDraft; self.previousDraft = nil; undoAfter = nil
                    }
                }.disabled(previousDraft == nil || draft != undoAfter)
                Button("复制草稿") {
                    UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: draft]],
                        options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                    copyNotice = "草稿已复制到本机剪贴板，五分钟后过期。"
                }.disabled(draft.isEmpty)
                if let copyNotice { Text(copyNotice).font(.caption).foregroundStyle(.secondary) }
                Text("此草稿不会回改其他应用，复制后请自行粘贴。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("口述纠字核对") {
                TextField("例如：小明是黄晓明的晓明", text: $explanation, axis: .vertical)
                    .onChange(of: explanation) { _, _ in suggestion = nil; notice = nil }
                Button("生成候选") {
                    suggestion = SpokenCorrection.suggest(explanation: explanation, draft: draft)
                    notice = suggestion == nil ? "未找到唯一明确的候选，请直接编辑草稿。" : nil
                }.disabled(explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let suggestion, suggestion.original == draft {
                    Text("\(suggestion.target) → \(suggestion.replacement)").font(.headline)
                    Text(suggestion.corrected).textSelection(.enabled)
                    HStack {
                        Button("采用候选") {
                            previousDraft = draft; undoAfter = suggestion.corrected
                            draft = suggestion.corrected; self.suggestion = nil
                        }
                        Button("忽略", role: .cancel) { self.suggestion = nil }
                    }
                }
                if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("核对语音草稿")
    }
}
