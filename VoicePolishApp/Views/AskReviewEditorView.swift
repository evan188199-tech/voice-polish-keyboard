import SwiftUI

struct AskReviewEditorView: View {
    @ObservedObject var coordinator: VoiceSessionCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var jobID: UUID?
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("识别文字").font(.headline)
                Text("请检查并修改识别内容。只有点击确认后才会发送给模型。")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .accessibilityIdentifier("ask.editor")
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("确认后请回到原应用，在键盘中插入回答。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("核对提问")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("稍后") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认提问") {
                        guard let jobID, coordinator.confirmAskReview(jobID: jobID, text: text) else {
                            error = "内容为空、过长或任务已变化，请返回键盘重新核对。"
                            return
                        }
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 12_000)
                }
            }
            .onAppear {
                guard let review = coordinator.askReview else { error = "待确认的问题已失效。"; return }
                jobID = review.jobID
                text = review.text
            }
        }
    }
}
