import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var draftName = ""
    @State private var draftBaseURL = ""
    @State private var draftModelName = ""
    @State private var draftAPIKey = ""
    @State private var saveBanner: String?
    @State private var testMessage: String?
    @State private var testSucceeded: Bool?
    @State private var isTesting = false
    @FocusState private var focus: Field?

    enum Field: Hashable { case name, url, model, key }

    private var normalizedDraftURL: String {
        PolishingSettings.normalizeBaseURL(draftBaseURL)
    }

    private var isDirty: Bool {
        let savedKey = settings.apiKey ?? ""
        let activeName = settings.activePolishProfile?.name ?? ""
        return draftName.trimmingCharacters(in: .whitespacesAndNewlines) != activeName
            || normalizedDraftURL != settings.baseURL
            || draftModelName.trimmingCharacters(in: .whitespacesAndNewlines) != settings.modelName
            || draftAPIKey != savedKey
    }

    private var polishModeGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: PolishMode.allCases.count)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(PolishMode.allCases, id: \.self) { mode in
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
                    .frame(maxWidth: .infinity, minHeight: 52)
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
            && !isTesting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("繁简输出") {
                    Picker("输出字体", selection: $settings.chineseScript) {
                        ForEach(ChineseScriptPreference.allCases, id: \.self) { pref in
                            Text(pref.settingsDescription).tag(pref)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle("启用润色", isOn: $settings.polishEnabled)

                    if settings.polishEnabled {
                        polishModeGrid
                        Text(settings.polishMode.settingsDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("键盘语音页点「原文」可关闭润色。")
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

                    TextField("配置名称", text: $draftName)
                        .focused($focus, equals: .name)
                    TextField("https://api.openai.com", text: $draftBaseURL)
                        .focused($focus, equals: .url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("gpt-4o-mini / mimo-v2.5", text: $draftModelName)
                        .focused($focus, equals: .model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("sk-...", text: $draftAPIKey)
                        .focused($focus, equals: .key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Button("保存当前") { saveCurrent() }
                            .disabled(!isDirty)
                        Button("另存为新配置") { saveAsNew() }
                            .disabled(draftModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      && draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if settings.polishProfiles.count > 1 {
                        Button("删除当前配置", role: .destructive) {
                            let id = settings.activePolishProfileID
                            settings.deletePolishProfile(id: id)
                            loadDraftFromSettings()
                            saveBanner = "已切换到 \(settings.activePolishProfile?.name ?? "配置")"
                        }
                    }

                    if let saveBanner {
                        Text(saveBanner)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await runTest() }
                    } label: {
                        if isTesting {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("测试模型")
                        }
                    }
                    .disabled(!canTest)

                    if isDirty {
                        Text("有未保存的修改，请先保存再测试 / 切换才会用到。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if let testMessage {
                        Text(testMessage)
                            .font(.caption)
                            .foregroundStyle(testSucceeded == true ? .green : .orange)
                    }
                } header: {
                    Text("润色 API（可选）")
                } footer: {
                    Text("可保存多套配置并切换。Base URL 支持根地址或带 /v1 的反代（如 https://opencode.ai/zen/go/v1）。OpenCode Go 上 mimo-v2-omni 目前 chat 不可用，建议用 mimo-v2.5 等文本模型。关闭润色或留空 Key 时仅本地转写。")
                }

                Section {
                    NavigationLink {
                        StyleProfilesView(settings: settings)
                    } label: {
                        HStack {
                            Text("当前风格")
                            Spacer()
                            Text(settings.activeStyleProfile?.name ?? "自然润色")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("输入风格")
                } footer: {
                    Text("内置纠错、自然润色与结构化提示词；可创建仅存本机的自定义整理风格。")
                }



                Section {
                    Toggle("对照测试 · 系统听写", isOn: $settings.compareWithSystemDictation)
                } header: {
                    Text("ASR 对照（主 App）")
                } footer: {
                    Text("开启后，主 App 录音会并行跑 SenseVoice 与系统端侧听写并排展示。键盘插字仍只用 SenseVoice。需要系统语音识别权限，且设备需支持对应语言的离线听写。")
                }

                Section {
                    Toggle("自动记下剪切板", isOn: $settings.clipboardHistoryEnabled)
                } header: {
                    Text("剪切板历史")
                } footer: {
                    Text("开启后，键盘每次唤出时会自动读一次当前剪切板并记入历史（最多 50 条，7 天后自动清理）。iOS 限制：键盘在后台无法监听剪切板，所以复制后需要让键盘弹出一次才能入库；读剪切板时系统可能弹出“粘贴自 XX”提示，属于系统隐私机制，无法完全消除。")
                }

                Section {
                    Stepper(
                        value: $settings.maxRecordingDuration,
                        in: 10...AppConstants.absoluteMaxRecordingDuration,
                        step: 5
                    ) {
                        HStack {
                            Text("最长录音")
                            Spacer()
                            Text("\(Int(settings.maxRecordingDuration)) 秒")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("空闲自动关闭", isOn: $settings.sessionIdleTimeoutEnabled)
                    if settings.sessionIdleTimeoutEnabled {
                        Stepper(
                            value: $settings.sessionIdleTimeoutSeconds,
                            in: AppConstants.minimumSessionIdleTimeoutSeconds...AppConstants.absoluteMaxSessionIdleTimeoutSeconds,
                            step: 60
                        ) {
                            HStack {
                                Text("空闲超时")
                                Spacer()
                                Text(idleTimeoutLabel)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("录音与会话")
                } footer: {
                    Text("超过设定时间没有按住说话，将自动关闭语音会话，释放麦克风并停止桥接。快捷指令启动会话后同样生效。")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("设置 > 通用 > 键盘 > 键盘", systemImage: "1.circle")
                        Label("添加「粤英语音键盘」", systemImage: "2.circle")
                        Label("开启「允许完全访问」", systemImage: "3.circle")
                    }
                    .font(.subheadline)
                    Button("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } header: {
                    Text("键盘安装")
                }

                Section {
                    NavigationLink {
                        FeedbackView(appVersion: appVersion)
                    } label: {
                        Label("反馈与进度", systemImage: "bubble.left.and.bubble.right")
                    }
                }

                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } header: {
                    Text("关于")
                }
            }
            .navigationTitle("设置")
            .onAppear { loadDraftFromSettings() }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focus = nil }
                }
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }

    private var idleTimeoutLabel: String {
        let minutes = Int(settings.sessionIdleTimeoutSeconds) / 60
        if minutes <= 0 {
            return "\(Int(settings.sessionIdleTimeoutSeconds)) 秒"
        }
        return "\(minutes) 分钟"
    }

    private func loadDraftFromSettings() {
        draftName = settings.activePolishProfile?.name ?? settings.modelName
        draftBaseURL = settings.baseURL
        draftModelName = settings.modelName
        draftAPIKey = settings.apiKey ?? ""
        testMessage = nil
        testSucceeded = nil
    }

    private func saveCurrent() {
        settings.saveActivePolishProfile(
            name: draftName,
            baseURL: draftBaseURL,
            modelName: draftModelName,
            apiKey: draftAPIKey
        )
        loadDraftFromSettings()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        saveBanner = "已保存当前配置 \(formatter.string(from: Date()))"
        focus = nil
    }

    private func saveAsNew() {
        let profile = settings.saveAsNewPolishProfile(
            name: draftName,
            baseURL: draftBaseURL,
            modelName: draftModelName,
            apiKey: draftAPIKey
        )
        loadDraftFromSettings()
        saveBanner = "已新建并选用：\(profile.name)"
        focus = nil
    }

    @MainActor
    private func runTest() async {
        guard canTest else { return }
        isTesting = true
        testMessage = nil
        testSucceeded = nil
        defer { isTesting = false }

        let probe = PolishingSettings(
            baseURL: settings.baseURL,
            modelName: settings.modelName,
            apiKey: settings.apiKey ?? "",
            timeout: AppConstants.polishingProbeTimeout
        )
        let result = await APITextPolisher().testAvailability(settings: probe)
        testMessage = result.message
        testSucceeded = result.isSuccess
    }
}


private struct FeedbackView: View {
    let appVersion: String

    private static let issuesURL = URL(string: "https://github.com/evan188199-tech/voice-polish-keyboard/issues")!
    private static let bugURL = URL(string: "https://github.com/evan188199-tech/voice-polish-keyboard/issues/new?template=bug-report.yml")!
    private static let suggestionURL = URL(string: "https://github.com/evan188199-tech/voice-polish-keyboard/issues/new?template=feature-request.yml")!

    var body: some View {
        Form {
            Section {
                Link(destination: Self.bugURL) {
                    Label("报告问题", systemImage: "exclamationmark.bubble")
                }
                Link(destination: Self.suggestionURL) {
                    Label("提出建议", systemImage: "lightbulb")
                }
            } header: {
                Text("提交反馈")
            } footer: {
                Text("在 GitHub 登录后提交，不需要 API Key。反馈默认公开，请勿填写账号密钥、真实聊天内容或个人资料。App 不会自动附上录音、转写或日志。")
            }

            Section {
                Link(destination: Self.issuesURL) {
                    Label("查看反馈与进度", systemImage: "list.bullet.rectangle")
                }
            } footer: {
                Text("可以先搜相似反馈，再决定是否新建。提交后保存 Issue 链接，或在 GitHub 订阅更新。")
            }

            Section("报告问题时可填") {
                LabeledContent("App 版本", value: appVersion)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("反馈与进度")
        .navigationBarTitleDisplayMode(.inline)
    }
}
