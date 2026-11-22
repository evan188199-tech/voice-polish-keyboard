import Foundation
import Combine
import UIKit

@MainActor
final class KeyboardViewModel: ObservableObject {
    @Published var hostReturnIsSend = false
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
    @Published private(set) var isChangingPolishMode = false
    /// Active polish mode mirrored from host app.
    @Published var polishMode: PolishMode = .default
    /// Chinese script preference mirrored from host app.
    @Published var chineseScript: ChineseScriptPreference = .default
    /// Prior ask answer exists for serial follow-up.
    @Published var askFollowUpAvailable = false
    /// Next ask capture will include conversation history.
    @Published var askFollowUpArmed = false
    /// Local clipboard history (keyboard-authoritative).
    @Published var clipboardEntries: [ClipboardEntry] = []
    /// Retained locally so a host text field that rejects insertion never loses speech.
    @Published private(set) var lastDeliveredText: String?
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
                    applyAskFollowUpFlags(from: status)
                    if status.state == .recording {
                        // The keyboard process may have been recreated after a
                        // missed touch-up. Never adopt an orphaned remote capture.
                        _ = try? await client.send(.cancel)
                        isRecording = false
                        currentState = .ready
                    }
                } else {
                    currentState = .ready
                }
                statusText = readyPrompt
                await syncClipboardToHost()
            } catch {
                isConnected = false
                currentState = .inactive
                statusText = "请打开主应用并启动语音会话"
            }
        } else {
            currentState = .inactive
            statusText = "请打开主应用并启动语音会话"
        }
        reloadClipboard()
    }

    func disconnect() {
        stopTimer()
        holdStartState = .idle
        isRecording = false
        isConnected = false
        Task {
            // Dismissing or switching keyboards can cancel UIKit tracking
            // without a normal touch-up. Always clean up the remote capture
            // before closing the bridge; cancel is safe when already idle.
            _ = try? await client.send(.cancel)
            await client.disconnect()
        }
    }

    // MARK: - BiBi-style hold-to-record

    /// Call synchronously from the gesture before kicking off `onPressDown()`.
    func noteHoldBegan() -> Bool {
        guard !isRecording, !isChangingPolishMode else { return false }
        holdStartState = .scheduled
        return true
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
            // Retry transient busy while previous segment is still submitting PCM,
            // and briefly wait out microphone route recovery after headset changes.
            for attempt in 0..<12 {
                if response.response.outcome == .ok { break }
                if response.response.outcome == .unauthorized { break }
                let code = response.response.errorCode
                if code == .companionNotRunning || code == .micDenied || code == .modelNotReady {
                    break
                }
                let delay: UInt64 = (code == .inputSessionInvalid) ? 120_000_000 : 40_000_000
                try? await Task.sleep(nanoseconds: delay)
                response = try await client.send(.start)
                _ = attempt
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
            // The start command may have reached the companion even when its
            // response was lost. Cancellation is idempotent and prevents an
            // invisible recording from surviving the failed request.
            _ = try? await client.send(.cancel)
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
                lastDeliveredText = response.response.text
                return response.response.text
            case .error:
                if response.response.status?.state == .recording {
                    _ = try? await client.send(.cancel)
                }
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
            _ = try? await client.send(.cancel)
            currentState = .error
            statusText = "通信失败"
            canRetry = true
            isConnected = false
            return nil
        }
    }

    func copyLastDeliveredText() {
        guard let text = lastDeliveredText, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        statusText = "已复制最近结果"
    }

    func onSwipeCancel() async {
        _ = await waitForHoldStartToSettle()
        defer { holdStartState = .idle }
        stopTimer()
        isRecording = false
        // Always cancel remotely. Local state can be false when a start reply
        // was lost, which is precisely when an orphaned capture must be stopped.
        do {
            let response = try await client.send(.cancel)
            isConnected = true
            currentState = response.response.status?.state == .inactive ? .inactive : .ready
            statusText = currentState == .ready
                ? "已取消 · 按住说话"
                : "请打开主应用并启动语音会话"
            canRetry = false
        } catch {
            isConnected = false
            currentState = .inactive
            statusText = "取消失败 · 请打开主应用"
            canRetry = true
        }
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
                    applyAskFollowUpFlags(from: status)
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

    /// A nil mode selects local transcription only.
    func selectPolishMode(_ mode: PolishMode?) {
        guard isConnected, !isRecording, holdStartState == .idle, !isChangingPolishMode,
              mode != (polishEnabled ? polishMode : nil) else { return }
        isChangingPolishMode = true
        Task {
            defer { isChangingPolishMode = false }
            do {
                let response: WireResponse
                if let mode {
                    response = try await client.send(.setPolishMode, polishMode: mode.rawValue)
                } else {
                    response = try await client.send(.setPolishEnabled, polishEnabled: false)
                }
                switch response.response.outcome {
                case .ok:
                    if let status = response.response.status {
                        currentState = status.state
                        applyPolishFlag(from: status)
                        applyAskFollowUpFlags(from: status)
                    } else {
                        polishEnabled = mode != nil
                        if let mode { polishMode = mode }
                        askFollowUpAvailable = false
                        askFollowUpArmed = false
                    }
                    if !isBusy {
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
                    applyAskFollowUpFlags(from: status)
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
        // A failed start/finish can leave the companion recording even though the
        // keyboard has already shown an error.  Retrying must first terminate
        // that orphaned capture; merely reconnecting leaves the microphone on.
        holdStartState = .idle
        stopTimer()
        isRecording = false
        await connect()
        guard isConnected else {
            currentState = .inactive
            return
        }

        do {
            let response = try await client.send(.cancel)
            if let status = response.response.status {
                applyPolishFlag(from: status)
                applyScriptFlag(from: status)
                applyAskFollowUpFlags(from: status)
                currentState = status.state == .recording ? .error : status.state
            } else {
                currentState = .ready
            }
            statusText = currentState == .ready ? readyPrompt : (response.response.message ?? "重试失败")
            canRetry = currentState != .ready
        } catch {
            isConnected = false
            currentState = .inactive
            statusText = "请打开主应用并启动语音会话"
            canRetry = true
        }
    }

    // MARK: - Private

    private var readyPrompt: String {
        let script = chineseScript.shortLabel
        if polishEnabled, polishMode == .askLLM, askFollowUpArmed {
            return "追问已就绪 · 按住说话 · \(script)"
        }
        if polishEnabled, polishMode == .askLLM, askFollowUpAvailable {
            return "按住说话 · 问答 \(script) · 可追问"
        }
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

    private func applyAskFollowUpFlags(from status: BridgeStatus) {
        if let available = status.askFollowUpAvailable {
            askFollowUpAvailable = available
        }
        if let armed = status.askFollowUpArmed {
            askFollowUpArmed = armed
        }
        if polishMode != .askLLM || !polishEnabled {
            askFollowUpAvailable = false
            askFollowUpArmed = false
        }
    }

    func armAskFollowUp() async {
        guard isConnected, !isRecording else { return }
        do {
            let response = try await client.send(.armAskFollowUp)
            switch response.response.outcome {
            case .ok:
                if let status = response.response.status {
                    applyPolishFlag(from: status)
                    applyScriptFlag(from: status)
                    applyAskFollowUpFlags(from: status)
                    currentState = status.state == .recording ? .ready : status.state
                }
                askFollowUpArmed = true
                statusText = response.response.message ?? readyPrompt
            case .error, .unauthorized:
                statusText = response.response.message ?? "无法追问"
            case .text:
                break
            }
        } catch {
            statusText = "请打开主应用并启动语音会话"
            isConnected = false
        }
    }

    func clearAskConversation() async {
        guard isConnected, !isRecording else { return }
        do {
            let response = try await client.send(.clearAskConversation)
            if let status = response.response.status {
                applyPolishFlag(from: status)
                applyScriptFlag(from: status)
                applyAskFollowUpFlags(from: status)
            }
            askFollowUpAvailable = false
            askFollowUpArmed = false
            statusText = response.response.message ?? readyPrompt
        } catch {
            statusText = "请打开主应用并启动语音会话"
            isConnected = false
        }
    }

    // MARK: - Clipboard history

    func reloadClipboard() {
        clipboardEntries = ClipboardHistoryStore.load()
    }

    func deleteClipboardEntry(id: String) {
        let updated = ClipboardHistoryStore.remove(id: id, from: ClipboardHistoryStore.load())
        ClipboardHistoryStore.save(updated)
        clipboardEntries = updated
        Task { await syncClipboardToHost() }
    }

    func clearClipboard() {
        ClipboardHistoryStore.clear()
        clipboardEntries = []
        Task { await syncClipboardToHost(clearing: true) }
    }

    /// Push the local snapshot to the host app mirror. Best-effort.
    private func syncClipboardToHost(clearing: Bool = false) async {
        guard isConnected else { return }
        do {
            if clearing {
                _ = try await client.send(.clearClipboardHistory)
                return
            }
            let snapshot = ClipboardHistoryStore.load()
            let response = try await client.send(.syncClipboardHistory, clipboardEntries: snapshot)
            if let visible = response.response.clipboardEntries {
                ClipboardHistoryStore.save(visible)
                clipboardEntries = visible
            }
        } catch {
            // Non-fatal: clipboard works fully offline from the keyboard's own store.
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
                    if let status = response.response.status {
                        applyPolishFlag(from: status)
                        applyScriptFlag(from: status)
                        applyAskFollowUpFlags(from: status)
                    }
                    if !isRecording {
                        currentState = .ready
                        statusText = readyPrompt
                    }
                    canRetry = false
                    lastDeliveredText = response.response.text
                    return response.response.text
                case .error:
                    if response.response.errorCode == .discarded {
                        // Newer capture superseded this job; leave UI alone.
                        if !isRecording {
                            currentState = .ready
                            statusText = readyPrompt
                        }
                        canRetry = false
                        return nil
                    }
                    // Always surface the job-specific message; do not mask it as ready.
                    if let status = response.response.status {
                        applyPolishFlag(from: status)
                        applyScriptFlag(from: status)
                        applyAskFollowUpFlags(from: status)
                    }
                    if !isRecording {
                        currentState = .error
                        statusText = response.response.message ?? "识别失败"
                        canRetry = true
                        lastFailed = true
                    }
                    return nil
                case .ok:
                    if let status = response.response.status {
                        applyPolishFlag(from: status)
                        applyScriptFlag(from: status)
                        applyAskFollowUpFlags(from: status)
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
