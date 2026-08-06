import AppIntents

struct VoicePolishShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ActivateVoiceSessionIntent(),
            phrases: [
                "启动\(.applicationName)语音会话",
                "开始\(.applicationName)语音",
                "Start \(.applicationName) voice session"
            ],
            shortTitle: "启动语音会话",
            systemImageName: "mic.fill"
        )
    }
}
