import SwiftUI

/// Local review surface. The caller decides how to use an explicitly confirmed draft.
struct CorrectionReviewView: View {
    @State private var state: CorrectionReviewState
    @State private var manualText: String
    @State private var beforePunctuation: String?
    private let vocabulary: String
    let onUse: (String) -> Void
    let onCancel: () -> Void

    init(original: String, vocabulary: String = "", onUse: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        var initial = CorrectionReviewState()
        let token = initial.begin(original: original)
        let proposal = CorrectionReviewProposal.make(original: original)
        _ = initial.acceptProposal(proposal, token: token)
        _state = State(initialValue: initial)
        _manualText = State(initialValue: proposal.draft ?? original)
        self.vocabulary = vocabulary
        self.onUse = onUse; self.onCancel = onCancel
    }

    var body: some View {
        Form {
            Section("原始转写") { Text(state.restoreOriginal()).textSelection(.enabled) }
            if state.phase == .reviewing, let proposal = state.proposal {
                Section("核对纠错") {
                    Text(proposal.hint).font(.caption)
                    if let draft = proposal.draft { Text("待核对草稿：\(draft)") }
                    ForEach(proposal.candidates, id: \.self) { candidate in
                        Button("选择：\(candidate)") { _ = state.confirm(candidate: candidate) }
                    }
                    ForEach(PlaceNameMatcher.vocabularySuggestions(in: manualText, vocabulary: vocabulary, script: .simplified)) { suggestion in
                        Button("候选：\(suggestion.original) → \(suggestion.replacement)") {
                            var draft = PlaceReviewDraft(original: manualText, suggestions: [suggestion])
                            if draft.confirm(suggestion.id) { manualText = draft.text }
                        }
                    }
                    Text("音近不等于正确；请选择字形，或手动编辑完整结果。拆字说明识别错时不会猜测删除。")
                    Text("这是本地核对，不会调用云端润色。没有停顿或标点依据时不会猜测句中断句；可在下方手动补逗号和句号，原文始终保留。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $manualText).frame(minHeight: 100)
                    if let draft = FaithfulTextFormatter.punctuationDraft(manualText) {
                        Button("补句末标点（需核对）") {
                            beforePunctuation = manualText
                            manualText = draft
                        }
                    }
                    if let previous = beforePunctuation, manualText == previous + "。" {
                        Button("撤销句末标点") { manualText = previous; beforePunctuation = nil }
                    }
                    Button("确认手动结果") { _ = state.confirmManual(manualText) }
                        .disabled(manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("保留原始转写") { _ = state.keepOriginal() }
                }
            }
            if state.phase == .confirmed, let result = state.finalText {
                Section("待使用结果") {
                    Text(result).textSelection(.enabled)
                    Button("返回修改") { _ = state.undo() }
                    Button("使用此结果") { if let text = state.consumeConfirmed() { onUse(text) } }
                }
            }
            if state.phase != .delivered { Button("取消", role: .cancel) { state.cancel(); onCancel() } }
        }
    }
}
