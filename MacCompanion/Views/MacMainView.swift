import SwiftUI
import AppKit

struct MacMainView: View {
    @ObservedObject var coordinator: VoiceSessionCoordinator
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: MainUIState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    statusCard
                    modelSection
                    actions
                    if coordinator.lastTranscription != nil || coordinator.lastPolished != nil || coordinator.lastResult != nil {
                        resultCard
                    }
                    usage
                }
                .padding(20)
            }
            .navigationTitle("粤英语音键盘 · macOS")
            .task {
                await coordinator.refreshModelPresence()
                ui.modelReady = await coordinator.isModelReady
                if !ui.modelReady, coordinator.modelFilesPresent {
                    do {
                        try await coordinator.downloadModel()
                        ui.modelReady = await coordinator.isModelReady
                    } catch {}
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按住右 Option 说话，松开后插入到当前光标")
                .font(.title3.bold())
            Text("伴随应用负责麦克风、识别与可选润色。推荐自用：不依赖系统输入法列表，给伴随应用开麦克风+辅助功能后，按住右 Option 说话即可粘贴。系统输入法「粤英语音」是可选增强。")
                .foregroundStyle(.secondary)
        }
    }

    private var statusCard: some View {
        HStack {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.headline)
                if let inputName = coordinator.currentInputName {
                    Text(inputName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message = coordinator.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if !coordinator.isInputReady, coordinator.state != .inactive {
                    Text("麦克风路由恢复中…")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("模型").font(.headline)
            Text(coordinator.modelDisplayName).font(.subheadline).foregroundStyle(.secondary)
            if ui.modelReady {
                Label("模型已就绪", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let progress = coordinator.downloadProgress {
                ProgressView(value: progress) { Text("下载中 \(Int(progress * 100))%") }
            } else if coordinator.modelFilesPresent {
                Button("加载本地模型") {
                    Task {
                        try? await coordinator.downloadModel()
                        ui.modelReady = await coordinator.isModelReady
                    }
                }
            } else {
                Button("下载模型 (约 230 MB)") {
                    Task {
                        try? await coordinator.downloadModel()
                        ui.modelReady = await coordinator.isModelReady
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private var actions: some View {
        HStack {
            if coordinator.state == .inactive || coordinator.state == .error {
                Button {
                    ui.activating = true
                    Task {
                        await coordinator.activate()
                        ui.activating = false
                    }
                } label: {
                    Label("启动语音会话", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(ui.activating)
            } else {
                Button(role: .destructive) {
                    coordinator.deactivate()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
            }
            Spacer()
        }
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近结果 / 可复制").font(.headline)

            resultBlock(
                title: "识别原文",
                text: coordinator.lastTranscription,
                placeholder: "暂无"
            )
            resultBlock(
                title: "润色结果",
                text: coordinator.lastPolished,
                placeholder: polishPlaceholder
            )

            if let finalText = coordinator.lastResult, !finalText.isEmpty {
                Text("最终插入：\(finalText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Button("复制最终结果") {
                    copy(coordinator.lastResult ?? coordinator.lastTranscription ?? "")
                }
                .disabled((coordinator.lastResult ?? coordinator.lastTranscription ?? "").isEmpty)
                Button("复制原文") {
                    copy(coordinator.lastTranscription ?? "")
                }
                .disabled((coordinator.lastTranscription ?? "").isEmpty)
                Button("复制润色") {
                    copy(coordinator.lastPolished ?? "")
                }
                .disabled((coordinator.lastPolished ?? "").isEmpty)
                Button("清除") { coordinator.clearResult() }
            }
        }
    }

    private var polishPlaceholder: String {
        if coordinator.lastPolishFailed {
            return "润色失败，已使用原文"
        }
        if !settings.polishEnabled {
            return "未开启润色"
        }
        if (settings.apiKey ?? "").isEmpty {
            return "未配置 API Key"
        }
        return "未润色"
    }

    private func resultBlock(title: String, text: String?, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text?.isEmpty == false ? text! : placeholder)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(text?.isEmpty == false ? .primary : .secondary)
                .padding()
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var usage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("使用指南").font(.headline)
            Group {
                Text("日常语音（推荐）").font(.subheadline.weight(.semibold))
                Text("1. 菜单栏显示「就绪」，并开启「右 Option 语音监听」。")
                Text("2. 任意文本框：按住右 Option 说话 → 松开插入/粘贴。")
                Text("3. Escape 或菜单「取消当前录音」可中止。")
            }
            Group {
                Text("如何关闭 / 恢复正常输入").font(.subheadline.weight(.semibold))
                Text("• 临时关掉语音：菜单栏关闭「右 Option 语音监听」，或点「停止语音会话」。")
                Text("• 输入法占着切不走：菜单栏选双拼/ABC，或点「关闭输入法 / 恢复正常输入」。")
                Text("• 终端一键：./scripts/disable_ime.sh --stop-companion")
                Text("• 卸载输入法：./scripts/disable_ime.sh --remove ，再到系统设置文本输入里去掉「粤英语音」。")
            }
            Group {
                Text("可选：系统输入法路径").font(.subheadline.weight(.semibold))
                Text("系统设置 → 键盘 → 文本输入 → 添加「粤英语音」后，可走输入法插字；不需要时请不要一直停在该输入源上。")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var label: String {
        switch coordinator.state {
        case .inactive: "未启动"
        case .ready: "就绪"
        case .recording: "录音中"
        case .transcribing: "识别中"
        case .polishing: "润色中"
        case .error: "错误"
        }
    }

    private var symbol: String {
        switch coordinator.state {
        case .inactive: "mic.slash"
        case .ready: "mic"
        case .recording: "mic.fill"
        case .transcribing, .polishing: "waveform"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch coordinator.state {
        case .ready: .green
        case .recording: .red
        case .error: .orange
        default: .secondary
        }
    }
}
