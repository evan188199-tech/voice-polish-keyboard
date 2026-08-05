import SwiftUI

struct TestInputView: View {
    @ObservedObject var coordinator: VoiceSessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("主应用测试区")
                .font(.headline)
            Text("可直接在这里按住麦克风测试端载识别，无需切换键盘。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let text = coordinator.lastResult ?? coordinator.lastTranscription {
                Text(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ContentUnavailableView(
                    "暂无结果",
                    systemImage: "text.alignleft",
                    description: Text("启动语音会话后按住麦克风说话。")
                )
                .frame(minHeight: 120)
            }
        }
    }
}
