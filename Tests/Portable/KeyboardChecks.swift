import Foundation

actor MockKeyboardBridge: KeyboardBridgeServing {
    private var recording = false
    private var commands: [BridgeCommand] = []
    private var jobs: [(UUID, String?)] = []
    private var startError: BridgeErrorCode?
    private var delayStart = false
    private var delayFinish = false
    private var failFinish = false

    func configure(startError: BridgeErrorCode? = nil, delayStart: Bool = false,
                   delayFinish: Bool = false, failFinish: Bool = false) {
        self.startError = startError
        self.delayStart = delayStart
        self.delayFinish = delayFinish
        self.failFinish = failFinish
    }
    func seedRecording() { recording = true }
    func seedJob(_ text: String) { jobs.append((UUID(), text)) }
    func complete(_ index: Int, text: String) { jobs[index].1 = text }
    func count(_ command: BridgeCommand) -> Int { commands.filter { $0 == command }.count }
    func jobCount() -> Int { jobs.count }
    func connect() -> Bool { true }
    func disconnect() {}
    private func status() -> BridgeStatus {
        BridgeStatus(state: recording ? .recording : (jobs.isEmpty ? .ready : .transcribing),
                     elapsedSeconds: recording ? 3 : nil, jobID: jobs.first?.0,
                     pendingCount: jobs.count)
    }
    func request(_ command: BridgeCommand, polishEnabled: Bool?, polishMode: String?,
                 chineseScript: String?, jobID: UUID?, clipboardEntries: [ClipboardEntry]?) async throws -> WireResponse {
        commands.append(command)
        let response: BridgeResponse
        switch command {
        case .start:
            if delayStart { try await Task.sleep(nanoseconds: 60_000_000) }
            if let error = startError {
                response = .error("启动被拒绝", status: BridgeStatus(state: .error, errorCode: error), code: error)
            } else {
                recording = true
                response = .ok(status: status())
            }
        case .finish:
            if delayFinish { try await Task.sleep(nanoseconds: 60_000_000) }
            if recording {
                recording = false
                let id = UUID()
                jobs.append((id, nil))
                if failFinish { throw URLError(.networkConnectionLost) }
                response = .ok(status: status(), jobID: id)
            } else { response = .error("未录音", code: .notRecording) }
        case .cancel:
            recording = false
            response = .ok(status: status())
        case .status:
            // A later result is ready first; only the head may be consumed.
            if let (id, text) = jobs.first, let text {
                jobs.removeFirst()
                response = .text(text, status: status(), jobID: id)
            } else { response = .ok(status: status()) }
        default:
            response = .ok(status: status())
        }
        return WireResponse(requestID: UUID(), response: response)
    }
}

@main struct KeyboardChecks {
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: \(label)") }
        print("PASS: \(label)")
    }
    @MainActor static func pause(_ milliseconds: UInt64 = 320) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
    @MainActor static func makeModel(_ bridge: MockKeyboardBridge) async -> KeyboardViewModel {
        let defaults = UserDefaults(suiteName: "keyboard-check-\(UUID())")!
        let model = KeyboardViewModel(client: bridge, defaults: defaults)
        model.appear()
        await model.connect()
        return model
    }
    @MainActor static func main() async {
        var capture = VoiceKeyboardCapture()
        check(capture.beginStart() && !capture.beginStart(), "only one start transition")
        capture.observe(recording: false)
        check(capture.phase == .starting && !capture.isRecording, "stale poll cannot create fake recording or undo start")
        capture.settle(recording: true)
        check(!VoiceKeyboardSwipe.shouldSwitch(horizontal: -120, vertical: 0, capture: capture), "no swipe/cancel collision during recording")
        check(capture.beginFinish() && !capture.beginFinish(), "finish transition is claimed once")
        capture.settle(recording: false)
        check(VoiceKeyboardSwipe.shouldSwitch(horizontal: 80, vertical: 10, capture: capture), "horizontal swipe switches idle page")
        check(!VoiceKeyboardSwipe.shouldSwitch(horizontal: 50, vertical: 120, capture: capture), "upward drag is not a page or translation command")

        for error in [BridgeErrorCode.micDenied, .modelNotReady, .companionNotRunning] {
            let bridge = MockKeyboardBridge()
            await bridge.configure(startError: error)
            let model = await makeModel(bridge)
            await model.toggleRecording()
            check(!model.isRecording && model.needsActivation, "\(error): no waveform or timer")
            model.disconnect()
        }

        let bridge = MockKeyboardBridge()
        await bridge.configure(delayStart: true, delayFinish: true)
        let model = await makeModel(bridge)
        var inserted: [String] = []
        model.onTextReady = { inserted.append($0) }
        let start = Task { await model.toggleRecording() }
        await pause(10)
        await model.toggleRecording()
        await start.value
        let startCount = await bridge.count(.start)
        check(startCount == 1 && model.isRecording, "rapid taps during start produce one capture")
        let finish = Task { await model.toggleRecording() }
        await pause(10)
        await model.toggleRecording()
        await finish.value
        let finishCount = await bridge.count(.finish)
        check(finishCount == 1 && !model.isRecording, "rapid taps during finish commit once")
        await model.toggleRecording()
        check(model.isRecording, "pending ASR does not lock next recording")
        await model.cancelRecording()
        let preserved = await bridge.jobCount()
        check(preserved == 1, "explicit cancel preserves committed queue")
        await model.toggleRecording()
        await model.toggleRecording()
        await bridge.complete(1, text: "第二段")
        await pause()
        check(inserted.isEmpty, "later ready result waits for earlier job")
        await bridge.complete(0, text: "第一段")
        await pause(650)
        check(inserted == ["第一段", "第二段"], "single consumer inserts once in speaking order")
        await pause()
        check(inserted.count == 2 && model.lastDeliveredText == "第二段", "no duplicate poll insertion; recovery text retained")
        model.copyLastDeliveredText()
        model.disconnect()
        await pause()

        let restoredBridge = MockKeyboardBridge()
        await restoredBridge.seedRecording()
        let restored = await makeModel(restoredBridge)
        let cancels = await restoredBridge.count(.cancel)
        check(restored.isRecording && cancels == 0, "reconnect adopts host recording without guessing/cancelling")
        restored.disconnect()
        await pause()
        let hideCancels = await restoredBridge.count(.cancel)
        check(hideCancels == 1, "hiding keyboard cancels live capture")

        let oldBridge = MockKeyboardBridge()
        await oldBridge.seedJob("旧宿主结果")
        let old = await makeModel(oldBridge)
        var oldInsertions = 0
        old.onTextReady = { _ in oldInsertions += 1 }
        await pause()
        check(oldInsertions == 0 && old.lastDeliveredText == "旧宿主结果", "previous appearance result requires explicit insertion")
        old.disconnect()

        let lostBridge = MockKeyboardBridge()
        await lostBridge.configure(failFinish: true)
        let lost = await makeModel(lostBridge)
        await lost.toggleRecording()
        await lost.toggleRecording()
        await lost.retryTranscription()
        let attempts = await lostBridge.count(.finish)
        let queued = await lostBridge.jobCount()
        check(attempts == 1 && queued == 1, "lost finish reply never resubmits committed audio")
        lost.disconnect()

        var cursor = OrderedDeliveryCursor()
        check(!cursor.canDeliver(sequence: 2) && cursor.canDeliver(sequence: 1), "production ordered cursor blocks second result")
        cursor.advance()
        check(cursor.canDeliver(sequence: 2), "production cursor releases next result")
        let legacy = #"{"state":"ready"}"#.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(BridgeStatus.self, from: legacy)
        check(decoded.errorCode == nil && decoded.inputReady == nil, "bridge optional availability fields decode legacy snapshots")
        print("Keyboard logic checks completed (Apple frameworks replaced; no iOS UI/audio validation).")
    }
}
