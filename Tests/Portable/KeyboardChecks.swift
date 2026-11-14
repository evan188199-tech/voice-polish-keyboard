import Foundation

actor MockKeyboardBridge: KeyboardBridgeServing {
    private var recording = false
    private var commands: [BridgeCommand] = []
    private var jobs: [(UUID, String?)] = []
    private var startError: BridgeErrorCode?
    private var delayStart = false
    private var delayFinish = false
    private var delayCancel = false
    private var failFinish = false
    private var placeSuggestions = false
    private var legacyText: String?

    func configure(startError: BridgeErrorCode? = nil, delayStart: Bool = false,
                   delayFinish: Bool = false, delayCancel: Bool = false, failFinish: Bool = false, placeSuggestions: Bool = false,
                   legacyText: String? = nil) {
        self.startError = startError
        self.delayStart = delayStart
        self.delayFinish = delayFinish
        self.delayCancel = delayCancel
        self.failFinish = failFinish
        self.placeSuggestions = placeSuggestions
        self.legacyText = legacyText
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
        case .finish, .finishTranslation:
            if delayFinish { try await Task.sleep(nanoseconds: 60_000_000) }
            if recording {
                recording = false
                if let legacyText {
                    response = .text(legacyText, status: status())
                } else {
                    let id = UUID()
                    jobs.append((id, nil))
                    if failFinish { throw URLError(.networkConnectionLost) }
                    response = .ok(status: status(), jobID: id)
                }
            } else { response = .error("未录音", code: .notRecording) }
        case .cancel:
            if delayCancel { try await Task.sleep(nanoseconds: 200_000_000) }
            recording = false
            response = .ok(status: status())
        case .status:
            // A later result is ready first; only the head may be consumed.
            if let (id, text) = jobs.first, let text {
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

        let pendingCancelBridge = MockKeyboardBridge()
        await pendingCancelBridge.configure(delayStart: true, delayCancel: true)
        let pendingCancelModel = await makeModel(pendingCancelBridge)
        let pendingStart = Task { await pendingCancelModel.toggleRecording() }
        await pause(10)
        let pendingCancel = Task { await pendingCancelModel.cancelRecording() }
        await pause(90)
        check(pendingCancelModel.capture.phase == .cancelling && !pendingCancelModel.isRecording,
              "late start acknowledgement cannot overwrite pending cancellation")
        await pendingStart.value; await pendingCancel.value
        check(!pendingCancelModel.isRecording && pendingCancelModel.capture.phase == .idle,
              "cancel after pending start settles without committing")
        pendingCancelModel.disconnect()

        let legacyBridge = MockKeyboardBridge()
        await legacyBridge.configure(legacyText: "旧协议结果")
        let legacyModel = await makeModel(legacyBridge)
        var legacyInserted: [String] = []
        legacyModel.onTextReady = { legacyInserted.append($0) }
        legacyModel.onDeliverDestination = { _, _ in false }
        await legacyModel.toggleRecording(); await legacyModel.toggleRecording()
        check(legacyInserted.isEmpty && legacyModel.heldResult == "旧协议结果",
              "legacy immediate result is held when target cannot be verified")
        legacyModel.insertHeldResult()
        check(legacyInserted == ["旧协议结果"], "legacy result requires explicit recovery")
        legacyModel.disconnect()

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
        reviewModel.insertPlaceDraft()
        reviewModel.insertPlaceDraft()
        await pause()
        check(reviewInsertions == ["明天去桂林", "第二段"], "confirmed draft inserts once before next queued result")
        reviewModel.disconnect()

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
        mixed.startTranslation(.english, translation: translation)
        await pause(100)
        check(mixed.isRecording, "translation selection starts one actual mock recording")
        let translationStarts = await mixedBridge.count(.start)
        let prematureFinishes = await mixedBridge.count(.finishTranslation)
        check(translationStarts == 1 && prematureFinishes == 0, "translation selection/release starts exactly once and never stops capture")
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
        let reconstructedKeyboard = KeyboardViewModel(client: focusBridge, defaults: focusDefaults)
        check(reconstructedKeyboard.heldResult == "旧字段语音", "held dictation survives keyboard reconstruction")
        focusModel.canExplicitlyInsert = { false }
        focusModel.insertHeldResult()
        check(focusModel.heldResult == "旧字段语音" && focusResults.isEmpty, "unavailable foreground keeps held dictation intact")
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

        let verifiedDictationBridge = MockKeyboardBridge()
        let verifiedDictation = await makeModel(verifiedDictationBridge)
        var dictationGuard = TranslationDeliveryGuard()
        let dictationField = UUID()
        var verifiedDictationResults: [String] = []
        verifiedDictation.onCaptureDestination = { id in
            dictationGuard.capture(id, document: dictationField, visible: true, connected: true, continuityVerified: true)
        }
        verifiedDictation.onDeliverDestination = { id, text in
            guard dictationGuard.consume(id, document: dictationField, visible: true, connected: true) else { return false }
            verifiedDictationResults.append(text); return true
        }
        await verifiedDictation.toggleRecording(); await verifiedDictation.toggleRecording()
        await verifiedDictationBridge.complete(0, text: "虚构整理结果")
        await pause(650)
        check(verifiedDictationResults == ["虚构整理结果"], "verified mock target receives dictation directly once")
        await pause(300)
        check(verifiedDictationResults.count == 1, "verified mock dictation is not reinserted")
        verifiedDictation.disconnect()

        // Simulate a future host that supplies trustworthy continuity evidence.
        // This exercises the real guard with the full keyboard/mock voice flow;
        // UIKit currently does not claim or enable that evidence.
        let verifiedBridge = MockKeyboardBridge()
        let verifiedKeyboard = await makeModel(verifiedBridge)
        let verifiedTranslation = TranslationViewModel(service: PortableTranslationProvider(),
            defaults: UserDefaults(suiteName: "verified-voice-\(UUID())")!)
        var verifiedGuard = TranslationDeliveryGuard()
        let verifiedFieldA = UUID(), verifiedFieldB = UUID()
        var verifiedCurrentField = verifiedFieldA
        var verifiedInserted: [String] = []
        verifiedTranslation.onInsert = { verifiedInserted.append($0) }
        verifiedTranslation.canExplicitlyInsert = { true }
        verifiedTranslation.onCaptureTarget = { id in
            verifiedGuard.capture(id, document: verifiedCurrentField, visible: true, connected: true, continuityVerified: true)
        }
        verifiedTranslation.onAutomaticInsert = { id, text in
            guard verifiedGuard.consume(id, document: verifiedCurrentField, visible: true, connected: true) else { return false }
            verifiedInserted.append(text); return true
        }
        verifiedTranslation.onAbandonTarget = { id in verifiedGuard.abandon(id) }
        await verifiedTranslation.appear(hasFullAccess: true, hostSessionID: UUID())
        verifiedKeyboard.startTranslation(.english, translation: verifiedTranslation)
        await pause(100); await verifiedKeyboard.toggleRecording()
        await verifiedBridge.complete(0, text: "同一输入框")
        await pause(950)
        check(verifiedInserted == ["Translated."], "verified mock target receives voice translation directly exactly once")
        await pause(300)
        check(verifiedInserted.count == 1, "verified target does not redeliver an acknowledged result")
        verifiedKeyboard.startTranslation(.english, translation: verifiedTranslation)
        await pause(100); await verifiedKeyboard.toggleRecording()
        verifiedCurrentField = verifiedFieldB
        verifiedGuard.invalidate()
        await verifiedBridge.complete(0, text: "旧字段原文")
        await pause(950)
        check(verifiedInserted == ["Translated."] && verifiedTranslation.lastTranslationCanInsert,
              "changed mock target quarantines voice translation rather than inserting")
        verifiedTranslation.insertLastTranslation()
        check(verifiedInserted == ["Translated.", "Translated."], "explicit recovery inserts into currently selected mock field")
        verifiedTranslation.disappear(); verifiedKeyboard.disconnect()

        var cursor = OrderedDeliveryCursor()
        check(!cursor.canDeliver(sequence: 2) && cursor.canDeliver(sequence: 1), "production ordered cursor blocks second result")
        cursor.advance()
        check(cursor.canDeliver(sequence: 2), "production cursor releases next result")
        let legacy = #"{"state":"ready"}"#.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(BridgeStatus.self, from: legacy)
        check(decoded.errorCode == nil && decoded.inputReady == nil, "bridge optional availability fields decode legacy snapshots")
        await ContentChecks.run()
        await PlaceChecks.run()
        await MaterialChecks.run()
        await PrivateIndexChecks.run()
        await NotionPreviewChecks.run()
        print("Keyboard logic checks completed (Apple frameworks replaced; no iOS UI/audio validation).")
    }
}
