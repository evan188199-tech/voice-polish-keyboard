import Foundation
import Combine

@MainActor
final class KeyboardViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var statusText = "连接中…"
    @Published var elapsedTime: TimeInterval = 0
    @Published var isConnected = false
    @Published var currentState: BridgeStatus.State = .inactive
    @Published var canRetry = false
    @Published var isBusy = false
    /// True while any remote job is still in flight (does not lock the mic).
    var isProcessing: Bool {
        switch currentState {
        case .transcribing, .polishing:
            return true
        default:
            return false
        }
    }
    /// Optional polish toggle mirrored from the host app via bridge.
    @Published var polishEnabled = true
    /// Active polish mode mirrored from host app.
    @Published var polishMode: PolishMode = .default
    /// Chinese script preference mirrored from host app.
    @Published var chineseScript: ChineseScriptPreference = .default

    private let client = KeyboardBridgeClient()
    private var timer: Timer?
    private var recordingStart: Date?
    private var lastFailed = false
    /// Finger-down hold lifecycle so a quick release cannot outrun async start.
    private enum HoldStartState {
        case idle
        case scheduled
        case running
        case finished
    }
    private var holdStartState: HoldStartState = .idle

    func connect() async {
        statusText = "连接主应用…"
        let ok = await client.connect()
        isConnected = ok
        if ok {
            // Probe session
            do {
                let response = try await client.send(.ping)
                if let status = response.response.status {
                    currentState = status.state
                    applyPolishFlag(from: status)
                    applyScriptFlag(from: status)
                } else {
                    currentState = .ready
                }
                statusText = readyPrompt
            } catch {
                isConnected = false
                currentState = .inactive
                statusText = "请打开主应用并启动语音会话"
            }
        } else {
            currentState = .inactive
            statusText = "请打开主应用并启动语音会话"
        }
    }

    func disconnect() {
        stopTimer()
        Task { await client.disconnect() }
        isConnected = false
    }

    // MARK: - BiBi-style hold-to-record

    /// Call synchronously from the gesture before kicking off `onPressDown()`.
    func noteHoldBegan() {
        guard !isRecording else { return }
        holdStartState = .scheduled
    }

    func onPressDown() async {
        guard holdStartState == .scheduled, !isRecording else {
            if holdStartState == .scheduled {
                holdStartState = .finished
            }
            return
        }
        holdStartState = .running
        defer {
            if holdStartState == .running {
                holdStartState = .finished
            }
        }

        if !isConnected {
            await connect()
            guard isConnected else {
                holdStartState = .finished
                return
            }
        }

        do {
            var response = try await client.send(.start)
            // Retry transient busy while previous segment is still submitting PCM.
            for _ in 0..<5 {
                if response.response.outcome == .ok { break }
                if response.response.outcome == .unauthorized { break }
                let code = response.response.errorCode
                if code == .companionNotRunning || code == .micDenied || code == .modelNotReady {
                    break
                }
                try? await Task.sleep(nanoseconds: 40_000_000)
                response = try await client.send(.start)
            }

            switch response.response.outcome {
            case .ok:
                // Mark recording even if the finger already lifted; release handlers
                // wait on holdStartState and will finish/cancel immediately after.
                isRecording = true
                currentState = .recording
                statusText = "松开发送 · 左滑取消"
                recordingStart = Date()
                startTimer()
                canRetry = false
                lastFailed = false
            case .error, .unauthorized:
                statusText = response.response.message ?? "启动失败"
                // Keep processing state visible when only the new start failed.
                if currentState != .transcribing && currentState != .polishing {
                    currentState = .error
                }
                canRetry = true
            case .text:
                break
            }
        } catch {
            isConnected = false
            currentState = .inactive
            statusText = "请打开主应用并启动语音会话"
        }
        holdStartState = .finished
    }

    func onPressUp() async -> String? {
        // Wait for an in-flight/scheduled start so a quick release still ends recording.
        if !(await waitForHoldStartToSettle()) {
            holdStartState = .idle
            return nil
        }
        guard isRecording else {
            holdStartState = .idle
            return nil
        }
        stopTimer()
        isRecording = false
        currentState = .transcribing
        statusText = "识别中…"
        holdStartState = .idle

        do {
            let response = try await client.send(.finish)
            switch response.response.outcome {
            case .text:
                // Legacy servers may still return text on finish.
                currentState = .ready
                statusText = readyPrompt
                canRetry = false
                return response.response.text
            case .error:
                currentState = .error
                statusText = response.response.message ?? "识别失败"
                canRetry = true
                lastFailed = true
                return nil
            case .ok:
                let jobID = response.response.jobID ?? response.response.status?.jobID
                return await pollForResult(jobID: jobID)
            case .unauthorized:
                currentState = .error
                statusText = "鉴权失败"
                canRetry = true
                return nil
            }
        } catch {
            currentState = .error
            statusText = "通信失败"
            canRetry = true
            isConnected = false
            return nil
        }
    }

    func onSwipeCancel() async {
        _ = await waitForHoldStartToSettle()
        defer { holdStartState = .idle }
        guard isRecording else {
            // Start may have failed; just reset local UI.
            stopTimer()
            isRecording = false
            currentState = isConnected ? .ready : .inactive
            statusText = isConnected ? "已取消 · 按住说话" : "请打开主应用并启动语音会话"
            return
        }
        stopTimer()
        isRecording = false
        _ = try? await client.send(.cancel)
        currentState = .ready
        statusText = "已取消 · 按住说话"
        canRetry = false
    }

    /// Wait until a scheduled/running start attempt settles.
    /// Returns true only when the server-side recording actually started.
    private func waitForHoldStartToSettle() async -> Bool {
        if isRecording { return true }
        guard holdStartState == .scheduled || holdStartState == .running else {
            return isRecording
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if holdStartState == .finished || holdStartState == .idle {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return isRecording
    }

    func togglePolishEnabled() async {
        await setPolishEnabled(!polishEnabled)
    }

    func toggleChineseScript() async {
        await setChineseScript(chineseScript == .simplified ? .traditionalHK : .simplified)
    }

    func setChineseScript(_ pref: ChineseScriptPreference) async {
        guard !isRecording else { return }
        if !isConnected {
            await connect()
            guard isConnected else { return }
        }
        do {
            let response = try await client.send(.setChineseScript, chineseScript: pref.rawValue)
            switch response.response.outcome {
            case .ok:
                if let status = response.response.status {
                    currentState = status.state
                    applyScriptFlag(from: status)
                } else {
                    chineseScript = pref
                }
                if !isRecording, !isBusy {
                    statusText = response.response.message ?? readyPrompt
                }
            case .error, .unauthorized:
                statusText = response.response.message ?? "繁简切换失败"
            case .text:
                break
            }
        } catch {
            isConnected = false
            currentState = .inactive
            statusText = "请打开主应用并启动语音会话"
        }
    }

    /// Select a mode (enables polish). Tapping the active mode again turns polish off.
    func selectPolishMode(_ mode: PolishMode) async {
        guard !isRecording else { return }
        if polishEnabled, polishMode == mode {
            await setPolishEnabled(false)
            return
        }
        await setPolishMode(mode)
    }

    func setPolishMode(_ mode: PolishMode) async {
        guard !isRecording else { return }
        if !isConnected {
            await connect()
            guard isConnected else { return }
        }
        do {
            let response = try await client.send(.setPolishMode, polishMode: mode.rawValue)
            switch response.response.outcome {
            case .ok:
                if let status = response.response.status {
                    currentState = status.state
                    applyPolishFlag(from: status)
                } else {
                    polishEnabled = true
                    polishMode = mode
                }
                if !isRecording, !isBusy {
                    statusText = response.response.message ?? readyPrompt
                }
            case .error, .unauthorized:
                statusText = response.response.message ?? "模式切换失败"
            case .text:
                break
            }
        } catch {
            isConnected = false
            currentState = .inactive
            statusText = "请打开主应用并启动语音会话"
        }
    }

    func setPolishEnabled(_ enabled: Bool) async {
        guard !isRecording else { return }
        if !isConnected {
            await connect()
            guard isConnected else { return }
        }
        do {
            let response = try await client.send(.setPolishEnabled, polishEnabled: enabled)
            switch response.response.outcome {
            case .ok:
                if let status = response.response.status {
                    currentState = status.state
                    applyPolishFlag(from: status)
                } else {
                    polishEnabled = enabled
                }
                if !isRecording, !isBusy {
                    statusText = response.response.message ?? readyPrompt
                }
            case .error, .unauthorized:
                statusText = response.response.message ?? "润色开关失败"
            case .text:
                break
            }
        } catch {
            isConnected = false
            currentState = .inactive
            statusText = "请打开主应用并启动语音会话"
        }
    }

    func cyclePolishMode() async {
        guard !isRecording else { return }
        if !isConnected {
            await connect()
            guard isConnected else { return }
        }
        do {
            let response = try await client.send(.cyclePolishMode)
            switch response.response.outcome {
            case .ok:
                if let status = response.response.status {
                    currentState = status.state
                    applyPolishFlag(from: status)
                }
                if !isRecording, !isBusy {
                    statusText = response.response.message ?? readyPrompt
                }
            case .error, .unauthorized:
                statusText = response.response.message ?? "模式切换失败"
            case .text:
                break
            }
        } catch {
            isConnected = false
            currentState = .inactive
            statusText = "请打开主应用并启动语音会话"
        }
    }

    func retryTranscription() async {
        canRetry = false
        lastFailed = false
        await connect()
        statusText = readyPrompt
        currentState = isConnected ? .ready : .inactive
    }

    // MARK: - Private

    private var readyPrompt: String {
        let script = chineseScript.shortLabel
        return polishEnabled
            ? "按住说话 · \(polishMode.shortLabel) \(script)"
            : "按住说话 · 润色关 \(script)"
    }

    private func applyPolishFlag(from status: BridgeStatus) {
        if let enabled = status.polishEnabled {
            polishEnabled = enabled
        }
        if let mode = PolishMode.fromWire(status.polishMode) {
            polishMode = mode
        }
    }

    private func applyScriptFlag(from status: BridgeStatus) {
        if let raw = status.chineseScript,
           let pref = ChineseScriptPreference(rawValue: raw) {
            chineseScript = pref
        }
    }

    private func pollForResult(jobID: UUID?) async -> String? {
        // Allow long multi-segment queues: ~60s total (240 * 250ms).
        for _ in 0..<240 {
            do {
                let response = try await client.send(.status, jobID: jobID)
                switch response.response.outcome {
                case .text:
                    // Do not clobber an in-progress second capture / later waiter UI.
                    if !isRecording {
                        currentState = .ready
                        statusText = readyPrompt
                    }
                    canRetry = false
                    return response.response.text
                case .error:
                    // Job-specific failure (e.g. empty ASR) — do not hard-lock the keyboard.
                    if let status = response.response.status {
                        applyPolishFlag(from: status)
                        applyScriptFlag(from: status)
                        if status.state == .ready || status.state == .transcribing || status.state == .polishing {
                            currentState = status.state == .ready ? .ready : status.state
                            statusText = status.message ?? readyPrompt
                            return nil
                        }
                    }
                    currentState = .error
                    statusText = response.response.message ?? "识别失败"
                    canRetry = true
                    lastFailed = true
                    return nil
                case .ok:
                    if let status = response.response.status {
                        applyPolishFlag(from: status)
                        applyScriptFlag(from: status)
                        if !isRecording {
                            currentState = status.state == .recording ? .ready : status.state
                            switch status.state {
                            case .polishing:
                                statusText = status.message
                                    ?? (polishMode == .askLLM ? "生成中…" : "润色中…")
                            case .transcribing:
                                statusText = status.message ?? "识别中…"
                            case .ready:
                                statusText = status.message ?? readyPrompt
                            case .error:
                                statusText = status.message ?? "失败"
                            case .inactive:
                                statusText = "请打开主应用并启动语音会话"
                            case .recording:
                                break
                            }
                        }
                    }
                case .unauthorized:
                    statusText = "鉴权失败"
                    return nil
                }
            } catch {
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if !isRecording {
            currentState = .error
            statusText = "超时"
            canRetry = true
        }
        return nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStart else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsedTime = 0
        recordingStart = nil
    }
}
