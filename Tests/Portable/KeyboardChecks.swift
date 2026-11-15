import Foundation

actor MockKeyboardBridge: KeyboardBridgeServing {
    private var recording = false
    private var commands: [BridgeCommand] = []
    private var jobs: [(UUID, String?)] = []
    private var jobFailures: [UUID: String] = [:]
    private var startError: BridgeErrorCode?
    private var delayStart = false
    private var delayFinish = false
    private var failFinish = false
    private var placeSuggestions = false
    private var clipboardEnabled: Bool?
    private var failConnection = false
    private var rejectPing = false
    private var delayPing = false

    func setClipboardEnabled(_ enabled: Bool?) { clipboardEnabled = enabled }
    func configureClipboardConnection(fail: Bool = false, rejectPing: Bool = false, delayPing: Bool = false) {
        failConnection = fail; self.rejectPing = rejectPing; self.delayPing = delayPing
    }

    func configure(startError: BridgeErrorCode? = nil, delayStart: Bool = false,
                   delayFinish: Bool = false, failFinish: Bool = false, placeSuggestions: Bool = false) {
        self.startError = startError
        self.delayStart = delayStart
        self.delayFinish = delayFinish
        self.failFinish = failFinish
        self.placeSuggestions = placeSuggestions
    }
    func seedRecording() { recording = true }
    func seedJob(_ text: String) { jobs.append((UUID(), text)) }
    func seedFailure(_ message: String) {
        let id = UUID(); jobs.append((id, nil)); jobFailures[id] = message
    }
    func complete(_ index: Int, text: String) { jobs[index].1 = text }
    func fail(_ index: Int, message: String) { jobFailures[jobs[index].0] = message }
    func count(_ command: BridgeCommand) -> Int { commands.filter { $0 == command }.count }
    func jobCount() -> Int { jobs.count }
    func connect() -> Bool { !failConnection }
    func disconnect() {}
    private func status() -> BridgeStatus {
        BridgeStatus(state: recording ? .recording : (jobs.isEmpty ? .ready : .transcribing),
                     elapsedSeconds: recording ? 3 : nil, jobID: jobs.first?.0,
                     pendingCount: jobs.count, clipboardHistoryEnabled: clipboardEnabled)
    }
    func request(_ command: BridgeCommand, polishEnabled: Bool?, polishMode: String?,
                 chineseScript: String?, jobID: UUID?, clipboardEntries: [ClipboardEntry]?) async throws -> WireResponse {
        commands.append(command)
        if command == .ping && delayPing { try await Task.sleep(nanoseconds: 80_000_000) }
        let response: BridgeResponse
        switch command {
        case .ping where rejectPing:
            response = .unauthorized
        case .start:
            if delayStart { try await Task.sleep(nanoseconds: 60_000_000) }
            if let error = startError {
                response = .error("启动被拒绝", status: BridgeStatus(state: .error, errorCode: error), code: error)
            } else {
                recording = true
                response = .ok(status: status())
            }
        case .finish, .finishTranslation:
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
            if let (id, _) = jobs.first, let failure = jobFailures.removeValue(forKey: id) {
                jobs.removeFirst()
                response = .error(failure, status: status(), code: .unknown, jobID: id)
            } else if let (id, text) = jobs.first, let text {
                jobs.removeFirst()
                let candidates = placeSuggestions ? PlaceNameMatcher.suggestions(in: text,
                    entries: [PlaceNameEntry(name: "桂林", aliases: ["贵林"])], script: .simplified) : []
                response = .text(text, status: status(), jobID: id, placeSuggestions: candidates)
            } else { response = .ok(status: status()) }
        default:
            response = .ok(status: status())
        }
        return WireResponse(requestID: UUID(), response: response)
    }
}

actor PortableTranslationProvider: TextTranslating {
    let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    var capability: TranslationCapability { get async {
        TranslationCapability(serviceID: "fixture", serviceLabel: "mock", isAvailable: true,
            supportedTargets: [.english], orderedTargets: [.english], failure: nil)
    } }
    func translate(_ request: TranslationRequest) async throws -> TranslationEvent {
        try await Task.sleep(nanoseconds: 350_000_000)
        if fail { throw TranslationFailure.offline }
        return TranslationEvent(context: request.context, source: request.source,
                                translation: "Translated.", failure: nil)
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
    @MainActor static func makeModel(_ bridge: MockKeyboardBridge, defaults: UserDefaults? = nil) async -> KeyboardViewModel {
        let defaults = defaults ?? UserDefaults(suiteName: "keyboard-check-\(UUID())")!
        let model = KeyboardViewModel(client: bridge, defaults: defaults)
        model.canExplicitlyInsert = { true }
        model.onCaptureDestination = { _ in }
        model.onDeliverDestination = { [weak model] _, text in
            guard let insert = model?.onTextReady else { return false }
            insert(text); return true
        }
        model.appear()
        await model.connect()
        return model
    }
    @MainActor static func main() async {
        let failedAskBridge = MockKeyboardBridge()
        await failedAskBridge.seedFailure("问答不可用：请在主应用设置 API 密钥；识别原文已保存在历史")
        let failedAskModel = await makeModel(failedAskBridge)
        var failedAskInserted = false
        failedAskModel.onTextReady = { _ in failedAskInserted = true }
        await pause(350)
        check(failedAskModel.queueText?.contains("问答不可用") == true && failedAskModel.canRetry && !failedAskInserted,
              "failed ask shows a visible recoverable error rather than inserting its question")
        failedAskModel.disconnect()
        for setting: Bool? in [nil, false, true] {
            let clipboardBridge = MockKeyboardBridge()
            await clipboardBridge.setClipboardEnabled(setting)
            let clipboardModel = KeyboardViewModel(client: clipboardBridge)
            var samples = 0
            clipboardModel.onClipboardCapture = { samples += 1 }
            clipboardModel.appear()
            await clipboardModel.connect()
            await clipboardModel.connect()
            check(samples == (setting == true ? 1 : 0), "clipboard sampling requires an explicit current host opt-in and occurs once")
            clipboardModel.disconnect()
        }
        for rejected in [false, true] {
            let clipboardBridge = MockKeyboardBridge()
            await clipboardBridge.setClipboardEnabled(true)
            await clipboardBridge.configureClipboardConnection(fail: !rejected, rejectPing: rejected)
            let clipboardModel = KeyboardViewModel(client: clipboardBridge)
            var samples = 0
            clipboardModel.onClipboardCapture = { samples += 1 }
            clipboardModel.appear()
            await clipboardModel.connect()
            check(samples == 0 && !clipboardModel.isConnected, "clipboard is not sampled on connection failure or rejected ping")
            clipboardModel.disconnect()
        }
        let delayedBridge = MockKeyboardBridge()
        await delayedBridge.setClipboardEnabled(true)
        await delayedBridge.configureClipboardConnection(delayPing: true)
        let delayedModel = KeyboardViewModel(client: delayedBridge)
        var delayedSamples = 0
        delayedModel.onClipboardCapture = { delayedSamples += 1 }
        delayedModel.appear()
        let connecting = Task { await delayedModel.connect() }
        await pause(10)
        delayedModel.disconnect()
        await connecting.value
        check(delayedSamples == 0, "late host setting cannot trigger clipboard sampling after disappearance")
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

        let reviewBridge = MockKeyboardBridge()
        await reviewBridge.configure(placeSuggestions: true)
        let reviewModel = await makeModel(reviewBridge)
        var reviewInsertions: [String] = []
        reviewModel.onTextReady = { reviewInsertions.append($0) }
        await reviewModel.toggleRecording(); await reviewModel.toggleRecording()
        await reviewModel.toggleRecording(); await reviewModel.toggleRecording()
        await reviewBridge.complete(0, text: "明天去贵林")
        await reviewBridge.complete(1, text: "第二段")
        await pause(650)
        let waiting = await reviewBridge.jobCount()
        check(reviewModel.placeReview != nil && reviewInsertions.isEmpty && waiting == 1, "candidate review pauses ordered delivery without inserting a guess")
        reviewModel.confirmPlace(reviewModel.placeReview!.suggestions[0].id)
        reviewModel.canExplicitlyInsert = { false }
        reviewModel.insertPlaceDraft()
        check(reviewModel.placeReview != nil && reviewInsertions.isEmpty && reviewModel.statusText.contains("已保留"), "unavailable input field preserves the reviewed place draft")
        reviewModel.canExplicitlyInsert = { true }
        reviewModel.onTextReady = nil
        reviewModel.insertPlaceDraft()
        check(reviewModel.placeReview != nil && reviewInsertions.isEmpty, "missing insertion callback preserves the reviewed place draft")
        reviewModel.onTextReady = { reviewInsertions.append($0) }
        reviewModel.insertPlaceDraft()
        reviewModel.insertPlaceDraft()
        await pause()
        check(reviewInsertions == ["明天去桂林", "第二段"], "confirmed draft inserts once before next queued result")
        reviewModel.disconnect()

        let retainedBridge = MockKeyboardBridge()
        await retainedBridge.configure(placeSuggestions: true)
        let retainedDefaults = UserDefaults(suiteName: "retained-place-\(UUID())")!
        let retainedModel = await makeModel(retainedBridge, defaults: retainedDefaults)
        var retainedInsertions: [String] = []
        retainedModel.onTextReady = { retainedInsertions.append($0) }
        await retainedModel.toggleRecording(); await retainedModel.toggleRecording()
        await retainedModel.toggleRecording(); await retainedModel.toggleRecording()
        await retainedBridge.complete(0, text: "明天去贵林")
        await retainedBridge.complete(1, text: "下一段")
        await pause(650)
        retainedModel.confirmPlace(retainedModel.placeReview!.suggestions[0].id)
        let reviewBeforeRetain = retainedModel.placeReview!
        retainedModel.retainPlaceDraftWithoutInsertion()
        await pause(350)
        let retainedWaiting = await retainedBridge.jobCount()
        check(retainedModel.heldResult == "明天去桂林" && retainedInsertions.isEmpty && retainedWaiting == 1,
              "deferred place draft remains recoverable and blocks later segments")
        let restoredRetained = KeyboardViewModel(client: retainedBridge, defaults: retainedDefaults)
        check(restoredRetained.heldResult == "明天去桂林", "deferred place draft survives keyboard reconstruction")
        retainedDefaults.set(try! JSONEncoder().encode(reviewBeforeRetain), forKey: "keyboard_place_review_v1")
        let interruptedRetain = KeyboardViewModel(client: retainedBridge, defaults: retainedDefaults)
        check(interruptedRetain.heldResult == "明天去桂林" && interruptedRetain.placeReview == nil,
              "interrupted transition does not restore the same place draft twice")
        retainedModel.insertHeldResult()
        await pause(350)
        check(retainedInsertions == ["明天去桂林", "下一段"], "explicitly recovered place draft precedes later segments")
        retainedModel.disconnect()
        let skipDefaults = UserDefaults(suiteName: "skip-held-\(UUID())")!
        skipDefaults.set("待跳过结果", forKey: "keyboard_held_result_v1")
        let skipBridge = MockKeyboardBridge()
        await skipBridge.seedJob("后续待处理")
        let skipModel = await makeModel(skipBridge, defaults: skipDefaults)
        await pause(300)
        let skipWaiting = await skipBridge.jobCount()
        check(skipWaiting == 1, "held result prevents later job consumption before explicit skip")
        skipModel.discardHeldResult()
        check(skipModel.heldResult == nil && skipDefaults.string(forKey: "keyboard_held_result_v1") == nil,
              "explicit skip clears only the held delivery")
        await pause(350)
        check(skipModel.heldResult == "后续待处理", "explicit skip releases the next result for recovery")
        skipModel.disconnect()

        let mixedBridge = MockKeyboardBridge()
        let mixed = await makeModel(mixedBridge)
        let translation = TranslationViewModel(service: PortableTranslationProvider(),
            defaults: UserDefaults(suiteName: "integration-\(UUID())")!)
        var mixedInsertions: [String] = []
        mixed.onTextReady = { mixedInsertions.append($0) }
        translation.onInsert = { mixedInsertions.append($0) }
        translation.onAutomaticInsert = { [weak translation] _, text in guard let insert = translation?.onInsert else { return false }; insert(text); return true }
        await translation.appear(hasFullAccess: true, hostSessionID: UUID())
        mixed.startTranslation(.english, translation: translation)
        await pause(100)
        check(mixed.isRecording, "translation selection starts one actual mock recording")
        await mixed.toggleRecording()
        let translationFinishCount = await mixedBridge.count(.finishTranslation)
        check(translationFinishCount == 1, "translation capture is committed with its own bridge command")
        await mixed.toggleRecording(); await mixed.toggleRecording()
        await mixedBridge.complete(0, text: "你好")
        await mixedBridge.complete(1, text: "下一段")
        await pause(300)
        check(mixedInsertions.isEmpty, "normal dictation waits while earlier translation is processing")
        await pause(650)
        check(mixedInsertions == ["Translated.", "下一段"], "translated result and dictation insert once in original order")
        check(translation.lastEvent?.source == "你好", "translation retains ASR source for recovery")
        translation.disappear(); mixed.disconnect()

        let failedBridge = MockKeyboardBridge()
        let failedModel = await makeModel(failedBridge)
        let failedTranslation = TranslationViewModel(service: PortableTranslationProvider(fail: true),
            defaults: UserDefaults(suiteName: "integration-fail-\(UUID())")!)
        var failureInsertions: [String] = []
        failedModel.onTextReady = { failureInsertions.append($0) }
        failedTranslation.onInsert = { failureInsertions.append($0) }
        failedTranslation.onAutomaticInsert = { [weak failedTranslation] _, text in guard let insert = failedTranslation?.onInsert else { return false }; insert(text); return true }
        await failedTranslation.appear(hasFullAccess: true, hostSessionID: UUID())
        failedModel.startTranslation(.english, translation: failedTranslation)
        await pause(100); await failedModel.toggleRecording()
        await failedModel.toggleRecording(); await failedModel.toggleRecording()
        await failedBridge.complete(0, text: "需要保留原文")
        await failedBridge.complete(1, text: "后续听写")
        await pause(1000)
        check(failureInsertions == ["后续听写"], "failed translation preserves ordering without inserting source as translation")
        check(failedTranslation.lastEvent?.source == "需要保留原文" && failedTranslation.lastEvent?.failure == .offline,
              "failed translation keeps source and reports the failure")
        failedTranslation.disappear(); failedModel.disconnect()

        let asrFailBridge = MockKeyboardBridge()
        let asrFailModel = await makeModel(asrFailBridge)
        let asrFailTranslation = TranslationViewModel(service: PortableTranslationProvider(),
            defaults: UserDefaults(suiteName: "integration-asr-fail-\(UUID())")!)
        var afterFailure: [String] = []
        asrFailModel.onTextReady = { afterFailure.append($0) }
        await asrFailTranslation.appear(hasFullAccess: true, hostSessionID: UUID())
        asrFailModel.startTranslation(.english, translation: asrFailTranslation)
        await pause(100); await asrFailModel.toggleRecording()
        await asrFailModel.toggleRecording(); await asrFailModel.toggleRecording()
        await asrFailBridge.fail(0, message: "语音识别失败")
        await asrFailBridge.complete(1, text: "后续听写")
        await pause(700)
        check(asrFailTranslation.message == "语音识别失败" && afterFailure == ["后续听写"],
              "failed translation ASR reports its error and releases later dictation")
        asrFailTranslation.disappear(); asrFailModel.disconnect()

        let cancelledBridge = MockKeyboardBridge()
        let cancelledModel = await makeModel(cancelledBridge)
        let cancelledTranslation = TranslationViewModel(service: PortableTranslationProvider(),
            defaults: UserDefaults(suiteName: "integration-cancel-\(UUID())")!)
        var cancelledInsertions: [String] = []
        cancelledTranslation.onInsert = { cancelledInsertions.append($0) }
        cancelledTranslation.onAutomaticInsert = { [weak cancelledTranslation] _, text in guard let insert = cancelledTranslation?.onInsert else { return false }; insert(text); return true }
        await cancelledTranslation.appear(hasFullAccess: true, hostSessionID: UUID())
        cancelledModel.startTranslation(.english, translation: cancelledTranslation)
        await pause(100); await cancelledModel.cancelRecording()
        let cancelledCount = await cancelledBridge.count(.finishTranslation)
        check(cancelledCount == 0 && cancelledInsertions.isEmpty, "cancelled voice translation never commits or inserts")
        cancelledTranslation.disappear(); cancelledModel.disconnect()

        let staleBridge = MockKeyboardBridge()
        let staleModel = await makeModel(staleBridge)
        let staleTranslation = TranslationViewModel(service: PortableTranslationProvider(),
            defaults: UserDefaults(suiteName: "integration-stale-\(UUID())")!)
        var staleInsertions: [String] = []
        staleTranslation.onInsert = { staleInsertions.append($0) }
        staleTranslation.onAutomaticInsert = { [weak staleTranslation] _, text in guard let insert = staleTranslation?.onInsert else { return false }; insert(text); return true }
        await staleTranslation.appear(hasFullAccess: true, hostSessionID: UUID())
        staleModel.startTranslation(.english, translation: staleTranslation)
        await pause(100); await staleModel.toggleRecording()
        await staleBridge.complete(0, text: "旧会话原文")
        await pause(300)
        staleTranslation.disappear(); staleModel.disconnect()
        await pause(500)
        check(staleInsertions.isEmpty, "late translation after keyboard disappearance cannot insert")
        check(staleTranslation.lastEvent?.source == "旧会话原文", "disappearing keyboard retains submitted translation source")

        let focusBridge = MockKeyboardBridge()
        let focusDefaults = UserDefaults(suiteName: "focus-keyboard-\(UUID())")!
        let focusModel = await makeModel(focusBridge, defaults: focusDefaults)
        var focusGuard = TranslationDeliveryGuard()
        let initialField = UUID(), otherField = UUID()
        var currentField: UUID? = initialField
        var focusResults: [String] = []
        focusModel.onTextReady = { focusResults.append($0) }
        focusModel.onCaptureDestination = { id in
            focusGuard.capture(id, document: currentField, visible: true, connected: true, continuityVerified: true)
        }
        focusModel.onDeliverDestination = { id, text in
            guard focusGuard.consume(id, document: currentField, visible: true, connected: true) else { return false }
            focusResults.append(text); return true
        }
        await focusModel.toggleRecording(); await focusModel.toggleRecording()
        await focusModel.toggleRecording(); await focusModel.toggleRecording()
        currentField = otherField; focusGuard.invalidate()
        await focusBridge.complete(0, text: "旧字段语音")
        await focusBridge.complete(1, text: "后一段语音")
        await pause(400)
        let heldJobs = await focusBridge.jobCount()
        check(focusResults.isEmpty && focusModel.heldResult == "旧字段语音" && heldJobs == 1,
              "ordinary dictation holds old-field result and does not consume the next segment")
        check(focusModel.queueText?.contains("插入保留结果") == true,
              "held result remains visibly actionable after status polls")
        let reconstructedKeyboard = KeyboardViewModel(client: focusBridge, defaults: focusDefaults)
        check(reconstructedKeyboard.heldResult == "旧字段语音", "held dictation survives keyboard reconstruction")
        focusModel.canExplicitlyInsert = { false }
        focusModel.insertHeldResult()
        check(focusModel.heldResult == "旧字段语音" && focusResults.isEmpty, "unavailable foreground keeps held dictation intact")
        await pause(400)
        check(focusModel.queueText?.contains("当前输入框不可用") == true, "blocked explicit insertion remains visible across status polling")
        focusModel.canExplicitlyInsert = { true }
        focusModel.insertHeldResult()
        await pause(400)
        check(focusResults == ["旧字段语音"] && focusModel.heldResult == "后一段语音",
              "explicit recovery releases the next held segment in order")
        focusModel.insertHeldResult()
        check(focusResults == ["旧字段语音", "后一段语音"], "explicit recovery preserves segment order")
        focusModel.disconnect()

        let blockedBridge = MockKeyboardBridge()
        let blockedModel = await makeModel(blockedBridge)
        let blockedTranslation = TranslationViewModel(service: PortableTranslationProvider(),
            defaults: UserDefaults(suiteName: "integration-blocked-\(UUID())")!)
        var blockedResults: [String] = []
        blockedModel.onTextReady = { blockedResults.append($0) }
        blockedTranslation.onInsert = { blockedResults.append($0) }
        blockedTranslation.canExplicitlyInsert = { true }
        blockedTranslation.onAutomaticInsert = { _, _ in false }
        await blockedTranslation.appear(hasFullAccess: true, hostSessionID: UUID())
        blockedModel.startTranslation(.english, translation: blockedTranslation)
        await pause(100); await blockedModel.toggleRecording()
        await blockedModel.toggleRecording(); await blockedModel.toggleRecording()
        await blockedBridge.complete(0, text: "第一段原文")
        await blockedBridge.complete(1, text: "下一段普通听写")
        await pause(1000)
        let pendingBehindTranslation = await blockedBridge.jobCount()
        check(blockedResults.isEmpty && blockedModel.translationRecoveryPending && pendingBehindTranslation == 1,
              "blocked translation pauses later dictation until an explicit decision")
        blockedTranslation.insertLastTranslation()
        await pause(400)
        check(blockedResults == ["Translated.", "下一段普通听写"],
              "translation recovery releases following dictation in order")
        blockedTranslation.disappear(); blockedModel.disconnect()

        var cursor = OrderedDeliveryCursor()
        check(!cursor.canDeliver(sequence: 2) && cursor.canDeliver(sequence: 1), "production ordered cursor blocks second result")
        cursor.advance()
        check(cursor.canDeliver(sequence: 2), "production cursor releases next result")
        let legacy = #"{"state":"ready"}"#.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(BridgeStatus.self, from: legacy)
        check(decoded.errorCode == nil && decoded.inputReady == nil && decoded.clipboardHistoryEnabled == nil, "bridge optional availability fields decode legacy snapshots")
        await ContentChecks.run()
        await PlaceChecks.run()
        await MaterialChecks.run()
        print("Keyboard logic checks completed (Apple frameworks replaced; no iOS UI/audio validation).")
    }
}
