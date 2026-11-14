import SwiftUI

/// Standalone review surface. Not wired to recording or keyboard delivery yet.
struct CorrectionReviewView: View {
    @State private var state: CorrectionReviewState
    @State private var manualText: String
    let onUse: (String) -> Void
    let onCancel: () -> Void

    init(original: String, onUse: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        var initial = CorrectionReviewState()
        let token = initial.begin(original: original)
        let proposal = CorrectionReviewProposal.make(original: original)
        _ = initial.acceptProposal(proposal, token: token)
        _state = State(initialValue: initial)
        _manualText = State(initialValue: proposal.draft ?? "")
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
                    Text("也可以手动输入完整结果。")
                    TextEditor(text: $manualText).frame(minHeight: 100)
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
