import SwiftUI

struct ContentView: View {
    @ObservedObject var coordinator: VoiceSessionCoordinator
    @ObservedObject var settings: AppSettings

    @State private var showSettings = false
    @State private var showVocab = false
    @State private var showGuide = false
    @State private var showClipboard = false
    @State private var showHistory = false
    @State private var modelReady = false
    @State private var activating = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    onboarding
                    statusCard
                    usageStats
                    actionButtons
                    if coordinator.lastTranscription != nil
                        || coordinator.lastPolished != nil
                        || coordinator.lastResult != nil
                        || coordinator.lastCompareText != nil
                        || coordinator.lastCompareError != nil {
                        resultCard
                    }
                    shortcuts
                }
                .padding()
            }
            .navigationTitle("粤英语音键盘")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isSessionLive {
                        Button(role: .destructive) {
                            closeSession()
                        } label: {
                            Label("关闭", systemImage: "xmark.circle.fill")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(settings: settings) }
            .sheet(isPresented: $showVocab) {
                VocabularyView(settings: settings)
            }
            .sheet(isPresented: $showGuide) { KeyboardGuideView() }
            .sheet(isPresented: $showClipboard) {
                ClipboardHistoryView(mirror: ClipboardMirrorStore.shared)
            }
            .sheet(isPresented: $showHistory) {
                DictationHistoryView(store: DictationHistoryStore.shared)
            }
            .task {
                await coordinator.refreshModelPresence()
                modelReady = await coordinator.isModelReady
                // If Mac already seeded files but recognizer not loaded yet, auto-load once.
                if !modelReady, coordinator.modelFilesPresent {
                    do {
                        try await coordinator.downloadModel()
                        modelReady = await coordinator.isModelReady
                    } catch {
                        // statusMessage surfaces the failure
                    }
                }
            }
        }
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("欢迎使用粤英语音键盘", systemImage: "waveform")
                .font(.title2.bold())
            Text("借鉴「说点啥」：按住说话、松开发送、左滑取消。本机 SenseVoice 识别，可选 API 润色。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "下载模型（~230 MB，建议 Wi-Fi）")
                step(2, "配置润色 API（可选）")
                step(3, "授权麦克风并启动语音会话")
                step(4, "系统设置中添加键盘并开完全访问")
            }

            if !modelReady {
                if coordinator.preparePhase == "loading" || (coordinator.modelFilesPresent && coordinator.downloadProgress == nil && coordinator.statusMessage?.contains("加载") == true) {
                    ProgressView("加载本地模型…")
                } else if let progress = coordinator.downloadProgress {
                    ProgressView(value: progress) {
                        Text("下载中 \(Int(progress * 100))%")
                    }
                } else if coordinator.modelFilesPresent {
                    Button("加载本地模型") {
                        Task {
                            do {
                                try await coordinator.downloadModel()
                                modelReady = await coordinator.isModelReady
                            } catch {}
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("下载模型 (约 230 MB)") {
                            Task {
                                do {
                                    try await coordinator.downloadModel()
                                    modelReady = await coordinator.isModelReady
                                } catch {}
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Text("手机直连 Hugging Face 可能很慢或卡在 0%。也可使用 scripts/seed_model_to_device.sh 从开发机预置模型。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    Label("模型已就绪", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                    Spacer()
                    Button("删除模型", role: .destructive) {
                        Task {
                            try? await coordinator.deleteModel()
                            modelReady = await coordinator.isModelReady
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                statusIcon
                VStack(alignment: .leading, spacing: 4) {
                    Text(stateLabel).font(.headline)
                    if let inputName = coordinator.currentInputName, isSessionLive {
                        Label(inputName, systemImage: "mic.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let message = coordinator.statusMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    if !coordinator.isInputReady, isSessionLive {
                        Text("麦克风路由恢复中…")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if let elapsed = coordinator.elapsedSeconds {
                        Text(String(format: "%.1f 秒", elapsed))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if coordinator.state == .ready {
                    Circle().fill(.green).frame(width: 10, height: 10)
                } else if isSessionLive {
                    Circle().fill(.orange).frame(width: 10, height: 10)
                }
            }

            if isSessionLive {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.orange)
                    Text("语音会话运行中：麦克风与桥接已开启。\(idleSessionHint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("关闭", role: .destructive) {
                        closeSession()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var usageStats: some View {
        let stats = DictationHistoryStore.shared.statistics
        return HStack(spacing: 12) {
            statItem("记录", "\(stats.totalCount)")
            statItem("识别中位", stats.medianTranscriptionLatencyMs.map { "\($0) ms" } ?? "—")
            statItem("润色中位", stats.medianPolishingLatencyMs.map { "\($0) ms" } ?? "—")
            statItem("失败", "\(Int((stats.failureRate * 100).rounded()))%")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusIcon: some View {
        Group {
            switch coordinator.state {
            case .inactive:
                Image(systemName: "mic.slash").foregroundStyle(.secondary)
            case .ready:
                Image(systemName: "mic").foregroundStyle(.green)
            case .recording:
                Image(systemName: "mic.fill").foregroundStyle(.red)
            case .transcribing, .polishing:
                ProgressView()
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var stateLabel: String {
        switch coordinator.state {
        case .inactive: "未启动"
        case .ready: "会话就绪"
        case .recording: "录音中"
        case .transcribing: "识别中"
        case .polishing: "润色中"
        case .error: "错误"
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button { showHistory = true } label: {
                Label("语音历史", systemImage: "waveform")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            HStack(spacing: 12) {
                switch coordinator.state {
                case .inactive, .error:
                    Button {
                        activating = true
                        Task {
                            await coordinator.activate()
                            activating = false
                        }
                    } label: {
                        Label("启动语音会话", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(activating)

                case .ready, .recording, .transcribing, .polishing:
                    // Keep a single button identity across states so the hold gesture
                    // is not destroyed; processing no longer blocks the next recording.
                    VStack(spacing: 8) {
                        if coordinator.state == .transcribing || coordinator.state == .polishing {
                            if let message = coordinator.statusMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ProgressView("处理中…")
                            }
                        }
                        HoldMicButton(
                            level: coordinator.inputLevel,
                            isRecording: coordinator.state == .recording,
                            onPress: {
                                if coordinator.state != .inactive && coordinator.state != .recording {
                                    coordinator.startRecording()
                                }
                            },
                            onRelease: {
                                Task {
                                    // Enqueue quickly; wait for ordered result off the mic path.
                                    if let jobID = await coordinator.finishRecordingAndEnqueue() {
                                        _ = await coordinator.waitForJobResult(jobID)
                                    }
                                }
                            },
                            onCancel: { coordinator.cancelRecording() }
                        )
                        .id("holdMicButton")
                    }
                }
            }

            if isSessionLive {
                Button(role: .destructive) {
                    closeSession()
                } label: {
                    Label("关闭语音会话", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(activating)
            }
        }
    }

    private var idleSessionHint: String {
        if settings.sessionIdleTimeoutEnabled {
            let minutes = max(1, Int(settings.sessionIdleTimeoutSeconds) / 60)
            return "约 \(minutes) 分钟无按住说话会自动关闭。"
        }
        return "不用时请手动关闭。"
    }

    private var isSessionLive: Bool {
        coordinator.state != .inactive
    }

    private func closeSession() {
        activating = false
        coordinator.deactivate()
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近结果").font(.headline)

            if settings.compareWithSystemDictation {
                compareResultSection
            } else {
                resultBlock(
                    title: "识别原文",
                    text: coordinator.lastTranscription,
                    placeholder: "暂无"
                )
            }

            resultBlock(
                title: "润色结果",
                text: coordinator.lastPolished,
                placeholder: polishPlaceholder
            )

            if let finalText = coordinator.lastResult, !finalText.isEmpty {
                Text("最终插入：\(finalText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("清除") {
                coordinator.clearResult()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var compareResultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ASR 对照")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 10) {
                compareColumn(
                    title: "SenseVoice",
                    text: coordinator.lastTranscription,
                    latencyMs: coordinator.lastPrimaryLatencyMs,
                    error: nil,
                    placeholder: "暂无"
                )
                compareColumn(
                    title: coordinator.compareEngineDisplayName,
                    text: coordinator.lastCompareText,
                    latencyMs: coordinator.lastCompareLatencyMs,
                    error: coordinator.lastCompareError,
                    placeholder: "暂无对照结果"
                )
            }

            if let locale = coordinator.compareLocaleIdentifier, !locale.isEmpty {
                Text("系统听写 locale：\(locale)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if settings.compareWithSystemDictation {
                Text("系统听写 locale：识别后显示（优先 zh-HK）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func compareColumn(
        title: String,
        text: String?,
        latencyMs: Int?,
        error: String?,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if let latencyMs {
                Text("\(latencyMs) ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                    .padding(10)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text(text?.isEmpty == false ? text! : placeholder)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                    .foregroundStyle(text?.isEmpty == false ? .primary : .secondary)
                    .padding(10)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(text?.isEmpty == false ? .primary : .secondary)
                .padding()
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var shortcuts: some View {
        VStack(spacing: 12) {
            Button { showClipboard = true } label: {
                Label("剪切板历史", systemImage: "list.clipboard")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Button { showVocab = true } label: {
                Label("专有词词表", systemImage: "book.pages")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Button { showGuide = true } label: {
                Label("键盘安装指引", systemImage: "keyboard")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
            Text(text)
        }
        .font(.subheadline)
    }
}

/// BiBi-style hold mic control for the main app test surface.
struct HoldMicButton: View {
    let level: Float
    let isRecording: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    let onCancel: () -> Void

    @State private var dragX: CGFloat = 0
    @State private var didPress = false
    private let cancelThreshold: CGFloat = -60

    var body: some View {
        VStack(spacing: 10) {
            if isRecording {
                WaveformBars(level: level)
                    .frame(height: 28)
                    .padding(.horizontal, 8)
            }

            HStack {
                if isRecording {
                    Text("← 取消")
                        .font(.caption)
                        .foregroundStyle(dragX < cancelThreshold / 2 ? .red : .secondary)
                        .frame(width: 56, alignment: .leading)
                }

                Circle()
                    .fill(isRecording ? Color.red : Color.accentColor)
                    .frame(width: 72, height: 72)
                    .overlay {
                        Image(systemName: "mic.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                    .scaleEffect(isRecording ? 1.08 : 1.0)
                    .offset(x: isRecording ? min(0, dragX) : 0)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !didPress {
                                    didPress = true
                                    onPress()
                                }
                                dragX = value.translation.width
                            }
                            .onEnded { value in
                                let wasPressed = didPress
                                defer {
                                    dragX = 0
                                    didPress = false
                                }
                                guard wasPressed else { return }
                                if value.translation.width < cancelThreshold {
                                    onCancel()
                                } else {
                                    onRelease()
                                }
                            }
                    )

                if isRecording {
                    Text("松手识别")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct WaveformBars: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            let count = 24
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    let phase = abs(sin(Double(index) + Double(level) * 12))
                    let height = max(4, CGFloat(0.15 + phase * Double(max(level, 0.08))) * geo.size.height)
                    Capsule()
                        .fill(Color.red.opacity(0.75))
                        .frame(width: 3, height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }
}
