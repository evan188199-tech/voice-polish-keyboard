import SwiftUI
import AppKit
import ApplicationServices

struct MenuBarContent: View {
    @ObservedObject var coordinator: VoiceSessionCoordinator
    @ObservedObject var settings: AppSettings
    @ObservedObject var menuModel: MenuBarModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusLine)
                .font(.headline)
            if let message = coordinator.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(accessibilityLine)
                .font(.caption2)
                .foregroundStyle(AXIsProcessTrusted() ? Color.secondary : Color.orange)
            Text(hotkeyHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Divider()
            Toggle("右 Option 语音监听", isOn: $settings.rightOptionHotkeyEnabled)
            HStack {
                Text("繁简输出")
                    .font(.body)
                Spacer()
                Button {
                    let next: ChineseScriptPreference = settings.chineseScript == .simplified ? .traditionalHK : .simplified
                    settings.chineseScript = next
                } label: {
                    Text(settings.chineseScript.shortLabel)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.orange.opacity(0.18))
                        )
                        .foregroundStyle(Color.orange)
                }
                .buttonStyle(.plain)
            }
            Toggle("启用润色", isOn: $settings.polishEnabled)
            if settings.polishEnabled {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(PolishMode.gridOrder, id: \.self) { mode in
                        let selected = settings.polishMode == mode
                        Button {
                            settings.polishMode = mode
                        } label: {
                            Text(mode.shortLabel)
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(selected ? Color.orange.opacity(0.22) : Color.secondary.opacity(0.12))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(selected ? Color.orange.opacity(0.7) : Color.clear, lineWidth: 1)
                                )
                                .foregroundStyle(selected ? Color.orange : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(settings.polishMode.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button("打开主窗口") { openWindow(id: "main") }
            Button("设置…") { openSettings() }
            Button("打开键盘设置…") { openKeyboardSettings() }
            if !AXIsProcessTrusted() {
                Button("打开辅助功能设置…") {
                    RightOptionHotkeyService.shared.ensureAccessibilityPrompt()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Divider()
            if coordinator.state == .recording {
                Button("取消当前录音", role: .destructive) {
                    coordinator.cancelRecording()
                }
            }
            if coordinator.state == .inactive || coordinator.state == .error {
                Button("启动语音会话") {
                    Task { await coordinator.activate() }
                }
            } else {
                Button("停止语音会话") {
                    coordinator.deactivate()
                }
            }
            Button("关闭输入法 / 恢复正常输入") {
                disableIMEQuick()
            }
            if let text = coordinator.lastResult ?? coordinator.lastTranscription, !text.isEmpty {
                Divider()
                Text("最近结果")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(text)
                    .lineLimit(4)
                    .font(.callout)
                Button("复制结果") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            Divider()
            Button("退出伴随应用") {
                settings.rightOptionHotkeyEnabled = false
                coordinator.deactivate()
                RightOptionHotkeyService.shared.stop()
                NSApp.terminate(nil)
            }
        }
        .padding(4)
        .frame(minWidth: 260)
    }

    private var statusLine: String {
        switch coordinator.state {
        case .inactive: return "未启动"
        case .ready: return "就绪"
        case .recording: return "录音中"
        case .transcribing: return "识别中"
        case .polishing: return "润色中"
        case .error: return "错误"
        }
    }

    private var accessibilityLine: String {
        AXIsProcessTrusted()
            ? "辅助功能：已授权"
            : "辅助功能：未授权（右 Option 全局监听需要）"
    }

    private var hotkeyHint: String {
        if settings.rightOptionHotkeyEnabled {
            return "按住右 Option 说话（伴生 App 直控模式）"
        }
        return "右 Option 监听已关闭（普通打字不受影响）"
    }

    private func openKeyboardSettings() {
        // macOS Ventura+ keyboard text input pane; fall back to general keyboard prefs.
        let candidates = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    /// Best-effort local recovery without requiring Terminal.
    private func disableIMEQuick() {
        // 1) Stop listening / recording so keys feel normal again.
        if coordinator.state == .recording {
            coordinator.cancelRecording()
        }
        settings.rightOptionHotkeyEnabled = false
        RightOptionHotkeyService.shared.stop()

        // 2) Kill IME process if it is stuck as the active source host.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["VoicePolishInputMethod"]
        try? task.run()
        task.waitUntilExit()

        // 3) Open keyboard settings so user can uncheck / switch source.
        openKeyboardSettings()

        let alert = NSAlert()
        alert.messageText = "已尝试关闭粤英语音输入法"
        alert.informativeText = """
        已停止右 Option 监听，并结束输入法进程。

        请在菜单栏输入法图标中切换到「双拼 / ABC」。
        若仍卡住：系统设置 → 键盘 → 文本输入 → 编辑… → 去掉「粤英语音」。

        终端一键恢复：
        ./scripts/disable_ime.sh --stop-companion
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
