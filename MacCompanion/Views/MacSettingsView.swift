import SwiftUI

struct MacSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var coordinator: VoiceSessionCoordinator
    @ObservedObject var draft: SettingsDraftModel

    private var normalizedDraftURL: String {
        PolishingSettings.normalizeBaseURL(draft.draftBaseURL)
    }

    private var isDirty: Bool {
        let savedKey = settings.apiKey ?? ""
        let activeName = settings.activePolishProfile?.name ?? ""
        return draft.draftName.trimmingCharacters(in: .whitespacesAndNewlines) != activeName
            || normalizedDraftURL != settings.baseURL
            || draft.draftModelName.trimmingCharacters(in: .whitespacesAndNewlines) != settings.modelName
            || draft.draftAPIKey != savedKey
    }

    private var polishModeGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(PolishMode.gridOrder, id: \.self) { mode in
                let selected = settings.polishMode == mode
                Button {
                    settings.polishMode = mode
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: mode.symbolName)
                        Text(mode.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(selected ? Color.orange.opacity(0.7) : Color.clear, lineWidth: 1.5)
                    )
                    .foregroundStyle(selected ? Color.orange : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var canTest: Bool {
        !isDirty
            && !(settings.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.isTesting
    }

    var body: some View {
        Form {
            Section("繁简输出") {
                Picker("输出字体", selection: $settings.chineseScript) {
                    ForEach(ChineseScriptPreference.allCases, id: \.self) { pref in
                        Text(pref.settingsDescription).tag(pref)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("润色 API（可选）") {
                Toggle("启用润色", isOn: $settings.polishEnabled)

                if settings.polishEnabled {
                    polishModeGrid
                    Text(settings.polishMode.settingsDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("输入法菜单可直接单选；键盘右侧为 2×2 模式格。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if settings.polishProfiles.count > 1 {
                    Picker("当前配置", selection: Binding(
                        get: { settings.activePolishProfileID },
                        set: { newID in
                            settings.selectPolishProfile(id: newID)
                            loadDraftFromSettings()
                        }
                    )) {
                        ForEach(settings.polishProfiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                } else if let only = settings.polishProfiles.first {
                    HStack {
                        Text("当前配置")
                        Spacer()
                        Text(only.name)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("配置名称", text: $draft.draftName)
                TextField("Base URL", text: $draft.draftBaseURL)
                TextField("Model", text: $draft.draftModelName)
                SecureField("API Key", text: $draft.draftAPIKey)

                HStack {
                    Button("保存当前") { saveCurrent() }
                        .disabled(!isDirty)
                    Button("另存为新配置") { saveAsNew() }
                    Button("测试模型") {
                        Task { await runTest() }
                    }
                    .disabled(!canTest)
                    if draft.isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                }

                if settings.polishProfiles.count > 1 {
                    Button("删除当前配置", role: .destructive) {
                        let id = settings.activePolishProfileID
                        settings.deletePolishProfile(id: id)
                        loadDraftFromSettings()
                        draft.saveBanner = "已切换到 \(settings.activePolishProfile?.name ?? "配置")"
                    }
                }

                if let saveBanner = draft.saveBanner {
                    Text(saveBanner)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isDirty {
                    Text("有未保存的修改，请先保存再测试 / 切换才会用到。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let testMessage = draft.testMessage {
                    Text(testMessage)
                        .font(.caption)
                        .foregroundStyle(draft.testSucceeded == true ? .green : .orange)
                }

                Text("可保存多套配置并切换。Base URL 支持根地址或带 /v1 的反代。OpenCode Go 上 mimo-v2-omni 目前 chat 不可用，建议 mimo-v2.5。当前选用配置用于润色与测试。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("录音") {
                Stepper(value: $settings.maxRecordingDuration, in: 10...AppConstants.absoluteMaxRecordingDuration, step: 5) {
                    HStack {
                        Text("最长录音")
                        Spacer()
                        Text("\(Int(settings.maxRecordingDuration)) 秒")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("启动与语音监听") {
                Toggle("登录时启动伴随应用", isOn: $settings.launchAtLogin)
                Toggle("右 Option 语音监听", isOn: $settings.rightOptionHotkeyEnabled)
                Text("关闭「右 Option 语音监听」后，普通输入法切换与打字不受影响；需要语音时再打开。伴随应用不是系统输入法本身。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("输入法卡住时") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. 菜单栏点输入法图标，切换到双拼 / ABC（快捷键常见为 Control+空格）。")
                    Text("2. 菜单栏「粤英语音」→ 关闭输入法 / 恢复正常输入。")
                    Text("3. 终端执行：./scripts/disable_ime.sh --stop-companion")
                    Text("4. 彻底删除输入法：./scripts/disable_ime.sh --remove")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("词表") {
                TextEditor(text: $settings.customVocabulary)
                    .font(.body)
                    .frame(minHeight: 100)
                Text("每行一个专有词，用于本地整理与可选润色。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { loadDraftFromSettings() }
        .navigationTitle("设置")
    }

    private func loadDraftFromSettings() {
        draft.draftName = settings.activePolishProfile?.name ?? settings.modelName
        draft.draftBaseURL = settings.baseURL
        draft.draftModelName = settings.modelName
        draft.draftAPIKey = settings.apiKey ?? ""
        draft.testMessage = nil
        draft.testSucceeded = nil
    }

    private func saveCurrent() {
        settings.saveActivePolishProfile(
            name: draft.draftName,
            baseURL: draft.draftBaseURL,
            modelName: draft.draftModelName,
            apiKey: draft.draftAPIKey
        )
        loadDraftFromSettings()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        draft.saveBanner = "已保存当前配置 \(formatter.string(from: Date()))"
    }

    private func saveAsNew() {
        let profile = settings.saveAsNewPolishProfile(
            name: draft.draftName,
            baseURL: draft.draftBaseURL,
            modelName: draft.draftModelName,
            apiKey: draft.draftAPIKey
        )
        loadDraftFromSettings()
        draft.saveBanner = "已新建并选用：\(profile.name)"
    }

    @MainActor
    private func runTest() async {
        guard canTest else { return }
        draft.isTesting = true
        draft.testMessage = nil
        draft.testSucceeded = nil
        defer { draft.isTesting = false }

        let probe = PolishingSettings(
            baseURL: settings.baseURL,
            modelName: settings.modelName,
            apiKey: settings.apiKey ?? "",
            timeout: AppConstants.polishingProbeTimeout
        )
        let result = await APITextPolisher().testAvailability(settings: probe)
        draft.testMessage = result.message
        draft.testSucceeded = result.isSuccess
    }
}
