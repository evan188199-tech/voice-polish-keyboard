import AppKit
import InputMethodKit

/// InputMethodKit controller: right Option push-to-talk via companion bridge.
@MainActor
@objc(VoicePolishInputController)
final class VoicePolishInputController: IMKInputController {
    private var machine = RightOptionStateMachine()
    private let bridge = BridgeSessionClient()
    private var activeClient: (any IMKTextInput)?
    private var sessionID = UUID()
    /// Number of jobs waiting for ordered delivery/insert.
    private var pendingJobs = 0
    /// Keep multi-segment inserts strictly ordered even if polls complete close together.
    private var deliverChain: Task<Void, Never>?
    private var pendingText: String?
    private var polishEnabled = true
    private var polishMode: PolishMode = .default
    /// Cancels a recording if Right Option "up" is lost (stuck PTT).
    private var recordingWatchdog: DispatchWorkItem?

    override func recognizedEvents(_ sender: Any!) -> Int {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        return Int(mask.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        // Always remember the current client for session binding.
        if let client = sender as? any IMKTextInput {
            activeClient = client
        }

        // Never intercept input-source switching / system shortcuts.
        // Control+Space / Cmd+Space / Globe must remain available so users can leave this IME.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown {
            let isSpace = event.keyCode == 49
            if isSpace && (mods.contains(.control) || mods.contains(.command)) {
                return false
            }
            // Caps Lock / Fn-only events are irrelevant; keep passthrough default below.
        }

        let action: RightOptionStateMachine.Action
        switch event.type {
        case .flagsChanged:
            let flags = mods
            // Distinguish left/right Option via keyCode when available.
            let keyCode = event.keyCode
            var right = machine.rightOptionDown
            var left = machine.leftOptionDown
            if keyCode == MacKeyCode.rightOption {
                right = flags.contains(.option)
            } else if keyCode == MacKeyCode.leftOption {
                left = flags.contains(.option)
            } else if flags.contains(.option) {
                // Ambiguous: do not invent a right Option press from generic option bit alone.
            } else {
                // Option fully released.
                right = false
                left = false
            }
            action = machine.handle(.optionFlags(rightDown: right, leftDown: left))
        case .keyDown:
            action = machine.handle(.keyDown(keyCode: event.keyCode, isRepeat: event.isARepeat))
            // Escape while recording is consumed.
            if event.keyCode == MacKeyCode.escape, action == .cancel || machine.phase == .recording {
                if action != .none {
                    Task { @MainActor in await self.perform(action) }
                }
                return action != .none
            }
            // Never steal non-Option keys (typing + input source hotkeys).
            if event.keyCode != MacKeyCode.rightOption
                && event.keyCode != MacKeyCode.leftOption
                && event.keyCode != MacKeyCode.escape {
                return false
            }
        case .keyUp:
            action = machine.handle(.keyUp(keyCode: event.keyCode))
            if event.keyCode != MacKeyCode.rightOption && event.keyCode != MacKeyCode.leftOption {
                return false
            }
        default:
            return false
        }

        if action != .none {
            Task { @MainActor in await self.perform(action) }
            // Consume right Option edges and Escape cancel so the host app does not also see them as input.
            return true
        }

        // Passthrough everything else (including left Option).
        return false
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "粤英语音")
        let stateTitle = polishEnabled ? "模式：\(polishMode.shortLabel)" : "模式：关"
        let cycleItem = NSMenuItem(
            title: stateTitle,
            action: #selector(cyclePolishFromMenu(_:)),
            keyEquivalent: ""
        )
        cycleItem.target = self
        menu.addItem(cycleItem)

        let modeSub = NSMenu(title: "处理模式")
        let offItem = NSMenuItem(
            title: "润色关",
            action: #selector(setPolishOffFromMenu(_:)),
            keyEquivalent: ""
        )
        offItem.target = self
        offItem.state = polishEnabled ? .off : .on
        modeSub.addItem(offItem)
        for mode in PolishMode.cycleOrder {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(selectPolishModeFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (polishEnabled && polishMode == mode) ? .on : .off
            modeSub.addItem(item)
        }
        let modesRoot = NSMenuItem(title: "选择模式", action: nil, keyEquivalent: "")
        modesRoot.submenu = modeSub
        menu.addItem(modesRoot)

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(
            title: "刷新连接状态",
            action: #selector(refreshConnectionFromMenu(_:)),
            keyEquivalent: ""
        )
        refreshItem.target = self
        menu.addItem(refreshItem)
        return menu
    }

    @objc private func cyclePolishFromMenu(_ sender: Any?) {
        Task { @MainActor in await cyclePolishMode() }
    }

    @objc private func setPolishOffFromMenu(_ sender: Any?) {
        Task { @MainActor in await setPolishEnabled(false) }
    }

    @objc private func selectPolishModeFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String,
              let mode = PolishMode(rawValue: raw) else { return }
        Task { @MainActor in await setPolishMode(mode) }
    }

    @objc private func refreshConnectionFromMenu(_ sender: Any?) {
        Task { @MainActor in
            let connected = await bridge.ensureConnected(launchCompanionIfNeeded: true)
            if connected {
                await refreshPolishFlag()
                StatusOverlayController.shared.show(
                    polishEnabled ? "已连接 · \(polishMode.shortLabel)" : "已连接 · 润色关"
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    StatusOverlayController.shared.hide()
                }
            } else {
                StatusOverlayController.shared.show("请先打开粤英语音伴随应用", isError: true)
            }
        }
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        if let client = sender as? any IMKTextInput {
            activeClient = client
            sessionID = UUID()
        }
        Task { @MainActor in
            let connected = await bridge.ensureConnected(launchCompanionIfNeeded: true)
            if connected {
                await refreshPolishFlag()
            }
        }
    }

    override func deactivateServer(_ sender: Any!) {
        super.deactivateServer(sender)
        // Invalidate insertion target if focus leaves while a request is in flight.
        activeClient = nil
        cancelRecordingWatchdog()
        if machine.phase == .recording {
            _ = machine.handle(.connectionLost)
            Task { @MainActor in
                _ = try? await bridge.send(.cancel)
                StatusOverlayController.shared.hide()
            }
        } else {
            StatusOverlayController.shared.hide()
        }
    }

    private func refreshPolishFlag() async {
        do {
            let response = try await bridge.send(.ping)
            applyPolishState(from: response.response.status)
        } catch {
            // Keep last known value when ping fails.
        }
    }

    private func applyPolishState(from status: BridgeStatus?) {
        guard let status else { return }
        if let enabled = status.polishEnabled {
            polishEnabled = enabled
        }
        if let mode = PolishMode.fromWire(status.polishMode) {
            polishMode = mode
        }
    }

    private func cyclePolishMode() async {
        let connected = await bridge.ensureConnected(launchCompanionIfNeeded: true)
        guard connected else {
            await MainActor.run {
                StatusOverlayController.shared.show("请先打开粤英语音伴随应用", isError: true)
            }
            return
        }
        do {
            let response = try await bridge.send(.cyclePolishMode)
            switch response.response.outcome {
            case .ok:
                applyPolishState(from: response.response.status)
                let msg = response.response.message
                    ?? (polishEnabled ? "模式：\(polishMode.shortLabel)" : "模式：关")
                await MainActor.run {
                    StatusOverlayController.shared.show(msg)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        StatusOverlayController.shared.hide()
                    }
                }
            case .error, .unauthorized:
                let msg = response.response.message ?? "模式切换失败"
                await MainActor.run {
                    StatusOverlayController.shared.show(msg, isError: true)
                }
            case .text:
                break
            }
        } catch {
            await MainActor.run {
                StatusOverlayController.shared.show("伴随应用未连接", isError: true)
            }
        }
    }

    private func setPolishEnabled(_ enabled: Bool) async {
        let connected = await bridge.ensureConnected(launchCompanionIfNeeded: true)
        guard connected else {
            await MainActor.run {
                StatusOverlayController.shared.show("请先打开粤英语音伴随应用", isError: true)
            }
            return
        }
        do {
            let response = try await bridge.send(.setPolishEnabled, polishEnabled: enabled)
            switch response.response.outcome {
            case .ok:
                applyPolishState(from: response.response.status)
                let msg = response.response.message
                    ?? (enabled ? "已开启润色" : "已关闭润色")
                await MainActor.run {
                    StatusOverlayController.shared.show(msg)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        StatusOverlayController.shared.hide()
                    }
                }
            case .error, .unauthorized:
                let msg = response.response.message ?? "润色开关失败"
                await MainActor.run {
                    StatusOverlayController.shared.show(msg, isError: true)
                }
            case .text:
                break
            }
        } catch {
            await MainActor.run {
                StatusOverlayController.shared.show("伴随应用未连接", isError: true)
            }
        }
    }

    private func setPolishMode(_ mode: PolishMode) async {
        let connected = await bridge.ensureConnected(launchCompanionIfNeeded: true)
        guard connected else {
            await MainActor.run {
                StatusOverlayController.shared.show("请先打开粤英语音伴随应用", isError: true)
            }
            return
        }
        do {
            let response = try await bridge.send(.setPolishMode, polishMode: mode.rawValue)
            switch response.response.outcome {
            case .ok:
                applyPolishState(from: response.response.status)
                let msg = response.response.message ?? "已切换到\(mode.displayName)"
                await MainActor.run {
                    StatusOverlayController.shared.show(msg)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        StatusOverlayController.shared.hide()
                    }
                }
            case .error, .unauthorized:
                let msg = response.response.message ?? "模式切换失败"
                await MainActor.run {
                    StatusOverlayController.shared.show(msg, isError: true)
                }
            case .text:
                break
            }
        } catch {
            await MainActor.run {
                StatusOverlayController.shared.show("伴随应用未连接", isError: true)
            }
        }
    }

    private func perform(_ action: RightOptionStateMachine.Action) async {
        switch action {
        case .none:
            return
        case .start:
            let boundSession = sessionID
            armRecordingWatchdog()
            await MainActor.run { StatusOverlayController.shared.show("录音中…") }
            let connected = await bridge.ensureConnected(launchCompanionIfNeeded: true)
            guard connected else {
                cancelRecordingWatchdog()
                _ = machine.handle(.reset)
                await MainActor.run {
                    StatusOverlayController.shared.show("请先打开粤英语音伴随应用", isError: true)
                }
                return
            }
            do {
                let response = try await bridge.send(.start)
                switch response.response.outcome {
                case .ok:
                    await MainActor.run { StatusOverlayController.shared.show("录音中…") }
                case .error, .unauthorized:
                    cancelRecordingWatchdog()
                    _ = machine.handle(.reset)
                    let msg = response.response.message ?? "无法开始录音"
                    await MainActor.run {
                        StatusOverlayController.shared.show(msg, isError: true)
                    }
                case .text:
                    break
                }
            } catch {
                cancelRecordingWatchdog()
                _ = machine.handle(.reset)
                await MainActor.run {
                    StatusOverlayController.shared.show("伴随应用未连接", isError: true)
                }
            }
            _ = boundSession
        case .finish:
            cancelRecordingWatchdog()
            let boundSession = sessionID
            let clientAtStart = activeClient
            pendingJobs += 1
            await MainActor.run { StatusOverlayController.shared.show("识别中…") }
            do {
                let response = try await bridge.send(.finish)
                switch response.response.outcome {
                case .text:
                    let text = response.response.text ?? ""
                    await deliver(text: text, boundSession: boundSession, client: clientAtStart)
                case .error, .unauthorized:
                    let msg = response.response.message ?? "识别失败"
                    await MainActor.run {
                        StatusOverlayController.shared.show(msg, isError: true)
                    }
                case .ok:
                    let jobID = response.response.jobID ?? response.response.status?.jobID
                    if let text = await pollResult(jobID: jobID) {
                        await deliver(text: text, boundSession: boundSession, client: clientAtStart)
                    } else if pendingJobs <= 1 {
                        await MainActor.run {
                            StatusOverlayController.shared.show("无识别结果", isError: true)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    StatusOverlayController.shared.show("通信失败", isError: true)
                }
            }
            pendingJobs = max(0, pendingJobs - 1)
        case .cancel:
            cancelRecordingWatchdog()
            _ = try? await bridge.send(.cancel)
            await MainActor.run {
                StatusOverlayController.shared.show("已取消", autoHideAfter: 0.8)
            }
        }
    }

    private func armRecordingWatchdog() {
        cancelRecordingWatchdog()
        // Hard safety: if Right Option up is lost, auto-cancel after absolute max + buffer.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.machine.phase == .recording else { return }
                _ = self.machine.handle(.reset)
                _ = try? await self.bridge.send(.cancel)
                StatusOverlayController.shared.show("录音超时已取消，可切换输入法后重试", isError: true)
            }
        }
        recordingWatchdog = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AppConstants.absoluteMaxRecordingDuration + 2,
            execute: work
        )
    }

    private func cancelRecordingWatchdog() {
        recordingWatchdog?.cancel()
        recordingWatchdog = nil
    }

    private func pollResult(jobID: UUID?) async -> String? {
        for _ in 0..<240 {
            do {
                let response = try await bridge.send(.status, jobID: jobID)
                if response.response.outcome == .text {
                    return response.response.text
                }
                if response.response.outcome == .error {
                    return nil
                }
                if let status = response.response.status {
                    applyPolishState(from: status)
                    switch status.state {
                    case .polishing:
                        StatusOverlayController.shared.show(
                            status.message ?? (polishMode == .askLLM ? "生成中…" : "润色中…")
                        )
                    case .transcribing:
                        StatusOverlayController.shared.show(status.message ?? "识别中…")
                    default:
                        break
                    }
                }
            } catch {
                return nil
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    private func deliver(text: String, boundSession: UUID, client: (any IMKTextInput)?) async {
        let previous = deliverChain
        let task = Task { @MainActor in
            _ = await previous?.value
            await self.deliverNow(text: text, boundSession: boundSession, client: client)
        }
        deliverChain = task
        await task.value
    }

    private func deliverNow(text: String, boundSession: UUID, client: (any IMKTextInput)?) async {
        guard !text.isEmpty else {
            StatusOverlayController.shared.show("无识别结果", isError: true)
            return
        }
        // Only insert into the original session/client.
        let sameSession = boundSession == sessionID
        let target = client ?? activeClient
        if sameSession, let target {
            target.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            StatusOverlayController.shared.hide()
        } else {
            pendingText = text
            StatusOverlayController.shared.show("焦点已切换，结果保留在伴随应用", isError: true)
        }
    }
}
