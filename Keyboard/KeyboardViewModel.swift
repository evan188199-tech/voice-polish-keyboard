import Foundation
import Combine
import UIKit

@MainActor
final class KeyboardViewModel: ObservableObject {
    @Published private(set) var capture = VoiceKeyboardCapture()
    var isRecording: Bool { capture.isRecording }
    var canSwitchPage: Bool { capture.canSwitchPage }
    @Published private(set) var pendingCount = 0
    @Published private(set) var queueText: String?
    @Published private(set) var needsActivation = true
    @Published private(set) var isConnecting = false
    @Published var statusText = "连接中…"
    @Published var elapsedTime: TimeInterval = 0
    @Published var isConnected = false
    @Published var currentState: BridgeStatus.State = .inactive
    @Published var canRetry = false
    var isProcessing: Bool { pendingCount > 0 }
    /// Optional polish toggle mirrored from the host app via bridge.
    @Published var polishEnabled = true
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
    private let client: any KeyboardBridgeServing
    private var timer: Timer?
    private var recordingStart: Date?
    private var observer: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var visible = false
    @Published private(set) var appearance: UInt64 = 0
    private var submittedHere = Set<UUID>()
    private weak var translationModel: TranslationViewModel?
    private var activeTranslation: TranslationContext?
    private var translationJobs: [UUID: UUID] = [:]
    private var translationDeliveryPending: UUID?
    @Published private(set) var translationRecoveryPending = false
    private var activeDestination: UUID?
    private var jobDestinations: [UUID: UUID] = [:]
    var onCaptureDestination: ((UUID) -> Void)?
    var onDeliverDestination: ((UUID, String) -> Bool)?
    var onAbandonDestination: ((UUID) -> Void)?
    private var bufferedResults: [(UUID?, String, [PlaceNameSuggestion], CorrectionWireDisposition)] = []
    @Published private(set) var correctionMetadataUnknown = false
#if CORRECTION_TEST_FIXTURES
    var testCorrectionDisposition: ((UUID?, String) -> CorrectionWireDisposition)?
#endif
    @Published private(set) var correctionReview: CorrectionReviewState?
    @Published private(set) var correctionReviewID: UUID?
    @Published var correctionEditing = false
    @Published private(set) var correctionManualText = ""
    @Published private(set) var placeReview: PlaceReviewDraft?
    @Published private(set) var heldResult: String?
    /// Called only for jobs committed in the current keyboard appearance.
    /// UITextDocumentProxy has no insertion acknowledgement; retain every result first.
    var onTextReady: ((String) -> Void)?
    var canExplicitlyInsert: (() -> Bool)?
    private let defaults: UserDefaults

    init(client: any KeyboardBridgeServing = KeyboardBridgeClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        lastDeliveredText = defaults.string(forKey: "keyboard_last_result_v1")
        heldResult = defaults.string(forKey: "keyboard_held_result_v1")
        if let original = defaults.string(forKey: "keyboard_correction_review_v1") {
            var review = CorrectionReviewState(); let token = review.begin(original: original)
            _ = review.acceptProposal(CorrectionReviewProposal.make(original: original), token: token)
            correctionReview = review; correctionReviewID = UUID()
            correctionMetadataUnknown = defaults.bool(forKey: "keyboard_correction_unknown_v1")
            correctionManualText = review.proposal?.draft ?? ""
        }
        if let data = defaults.data(forKey: "keyboard_place_review_v1") {
            placeReview = try? JSONDecoder().decode(PlaceReviewDraft.self, from: data)
        }
    }

    func appear() {
        guard !visible else { return }
        visible = true
        appearance &+= 1
        submittedHere.removeAll()
        drainBufferedResults()
    }

    func connect() async {
        guard visible, !isConnecting else { return }
        isConnecting = true
        let epoch = appearance
        defer { if appearance == epoch { isConnecting = false } }
        await cleanup?.value
        guard visible, appearance == epoch else { return }
        statusText = "连接主应用…"
        let ok = await client.connect()
        guard visible, appearance == epoch else { return }
        guard ok else {
            connectionFailed()
            return
        }
        do {
            let response = try await client.send(.ping)
            guard visible, appearance == epoch else { return }
            isConnected = true
            if let status = response.response.status {
                applyHostStatus(status)
            }
            startObserving(epoch: epoch)
            reloadClipboard()
            await syncClipboardToHost()
        } catch {
            guard visible, appearance == epoch else { return }
            connectionFailed()
        }
    }

    func disconnect() {
        // A confirmation belongs to this keyboard appearance. Reconstruct the
        // pending review from the retained received text and invalidate old UI
        // callbacks; the original field is not assumed to remain focused.
        if let old = correctionReview {
            var review = CorrectionReviewState(); let token = review.begin(original: old.restoreOriginal())
            _ = review.acceptProposal(CorrectionReviewProposal.make(original: old.restoreOriginal()), token: token)
            correctionReview = review; correctionReviewID = UUID()
            correctionManualText = review.proposal?.draft ?? ""; correctionEditing = false
        }
        visible = false
        appearance &+= 1
        isConnecting = false
        observer?.cancel()
        let previousObserver = observer
        observer = nil
        let previousCleanup = cleanup
        stopTimer()
        capture.settle(recording: false)
        isConnected = false
        needsActivation = true
        submittedHere.removeAll()
        if let context = activeTranslation { translationModel?.cancel(context.id) }
        activeTranslation = nil
        translationJobs.removeAll()
        if let id = activeDestination { onAbandonDestination?(id) }
        for id in jobDestinations.values { onAbandonDestination?(id) }
        activeDestination = nil; jobDestinations.removeAll()
        translationDeliveryPending = nil
        translationModel?.onVoiceFinished = nil
        translationModel?.onRecoveryResolved = nil
        translationModel?.onRecoveryRequired = nil
        translationRecoveryPending = false
        // Cancel live audio only. The server keeps all committed jobs.
        cleanup = Task {
            await previousCleanup?.value
            _ = try? await client.send(.cancel)
            await client.disconnect()
            await previousObserver?.value
        }
    }

    /// Tap-only in this iteration. A held touch is one button activation, never a second capture.
    func toggleRecording() async {
        guard visible, isConnected, !needsActivation, !capture.isTransitioning else { return }
        if capture.isRecording {
            await finishRecording()
        } else {
            await startRecording()
        }
    }

    func attachTranslation(_ translation: TranslationViewModel) {
        translationModel = translation
        translationRecoveryPending = translation.lastTranslationCanInsert
        translation.onVoiceFinished = { [weak self, weak translation] id in
            guard let self, self.translationDeliveryPending == id else { return }
            self.translationDeliveryPending = nil
            self.translationRecoveryPending = translation?.lastTranslationCanInsert == true
            if self.translationRecoveryPending { self.queueText = "译文待处理 · 后续结果按序等待" }
            self.drainBufferedResults()
        }
        translation.onRecoveryRequired = { [weak self] in
            self?.translationRecoveryPending = true
            self?.queueText = "译文待处理 · 后续结果按序等待"
        }
        translation.onRecoveryResolved = { [weak self] in
            guard let self else { return }
            self.translationRecoveryPending = false
            self.queueText = nil
            self.drainBufferedResults()
        }
    }

    func startTranslation(_ target: TranslationTarget, translation: TranslationViewModel) {
        guard visible, isConnected, !needsActivation, !capture.isTransitioning, !capture.isRecording,
              activeTranslation == nil, let context = translation.prepareVoice(target: target) else { return }
        attachTranslation(translation)
        activeTranslation = context
        Task {
            await startRecording()
            if !capture.isRecording, activeTranslation?.id == context.id {
                translation.cancel(context.id)
                activeTranslation = nil
            }
        }
    }

    private func startRecording() async {
        guard capture.beginStart() else { return }
        if activeTranslation == nil {
            let id = UUID()
            activeDestination = id
            onCaptureDestination?(id)
        }
        let epoch = appearance
        statusText = "正在启动录音…"
        do {
            // The server already retries short microphone-route recovery windows.
            // Do not replay a start whose response might have been lost.
            let response = try await client.send(.start)
            guard visible, appearance == epoch, capture.phase == .starting else { return }
            let status = response.response.status
            if response.response.outcome == .ok, status?.state == .recording {
                capture.settle(recording: true)
                applyHostStatus(status!)
                canRetry = false
            } else {
                capture.settle(recording: false)
                if let id = activeDestination { onAbandonDestination?(id); activeDestination = nil }
                if let status { applyHostStatus(status) }
                needsActivation = response.response.errorCode.map {
                    [BridgeErrorCode.micDenied, .modelNotReady, .companionNotRunning].contains($0)
                } ?? false
                statusText = response.response.message ?? "启动失败，请重试"
                canRetry = true
            }
            drainBufferedResults()
        } catch {
            // A start may have reached the host. Stop it before offering another attempt.
            guard visible, appearance == epoch, capture.phase == .starting else { return }
            _ = try? await client.send(.cancel)
            guard visible, appearance == epoch else { return }
            capture.settle(recording: false)
            if let id = activeDestination { onAbandonDestination?(id); activeDestination = nil }
            connectionFailed()
        }
    }

    private func finishRecording() async {
        guard capture.beginFinish() else { return }
        let epoch = appearance
        stopTimer()
        statusText = "正在提交…"
        do {
            let response = try await client.send(activeTranslation == nil ? .finish : .finishTranslation)
            guard visible, appearance == epoch else { return }
            capture.settle(recording: false)
            if let status = response.response.status { applyHostStatus(status) }
            switch response.response.outcome {
            case .ok:
                if let id = response.response.jobID {
                    submittedHere.insert(id)
                    if let context = activeTranslation { translationJobs[id] = context.id }
                    if let destination = activeDestination { jobDestinations[id] = destination }
                } else {
                    if let context = activeTranslation { translationModel?.cancel(context.id) }
                    if let destination = activeDestination { onAbandonDestination?(destination) }
                }
                activeTranslation = nil; activeDestination = nil
                statusText = readyPrompt
                drainBufferedResults()
            case .text:
                // Compatibility with an older bridge; this command is never replayed.
                if let context = activeTranslation {
                    translationModel?.cancel(context.id)
                    activeTranslation = nil
                    if let text = response.response.text { holdForRecovery(text) }
                } else if let text = response.response.text {
                    // Legacy immediate text has no job-bound metadata. Quarantine.
                    if let destination = activeDestination { onAbandonDestination?(destination) }
                    activeDestination = nil
                    bufferedResults.append((response.response.jobID, text, [], .unknown))
                }
            case .error, .unauthorized:
                if let context = activeTranslation { translationModel?.cancel(context.id); activeTranslation = nil }
                if let id = activeDestination { onAbandonDestination?(id); activeDestination = nil }
                statusText = response.response.message ?? "提交失败，可到主应用历史恢复"
                canRetry = true
            }
            drainBufferedResults()
        } catch {
            // Never retry finish: it may already be enqueued. Discovery polling recovers it.
            guard visible, appearance == epoch else { return }
            _ = try? await client.send(.cancel)
            guard visible, appearance == epoch else { return }
            capture.settle(recording: false)
            connectionFailed()
            if let context = activeTranslation { translationModel?.cancel(context.id); activeTranslation = nil }
            if let id = activeDestination { onAbandonDestination?(id); activeDestination = nil }
            statusText = "连接中断 · 已提交结果可从历史恢复"
        }
    }

    func cancelRecording() async {
        guard capture.beginCancel() else { return }
        if let context = activeTranslation { translationModel?.cancel(context.id); activeTranslation = nil }
        if let id = activeDestination { onAbandonDestination?(id); activeDestination = nil }
        let epoch = appearance
        stopTimer()
        statusText = "正在取消本段…"
        do {
            let response = try await client.send(.cancel)
            guard visible, appearance == epoch else { return }
            capture.settle(recording: false)
            if let status = response.response.status { applyHostStatus(status) }
            statusText = "本段已取消 · 已提交队列保留"
            drainBufferedResults()
        } catch {
            guard visible, appearance == epoch else { return }
            capture.settle(recording: false)
            connectionFailed()
            statusText = "取消未确认 · 请打开主应用检查"
        }
    }

    func copyLastDeliveredText() {
        guard let text = lastDeliveredText, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        statusText = "已复制最近结果"
    }

    private func receiveResult(_ text: String, autoInsert: Bool) {
        guard !text.isEmpty else { return }
        lastDeliveredText = text
        defaults.set(text, forKey: "keyboard_last_result_v1")
        if autoInsert, visible {
            onTextReady?(text)
        } else {
            statusText = "结果已保留 · 可在更多操作中插入或复制"
        }
    }

    private func correctionDisposition(_ response: BridgeResponse, text: String) -> CorrectionWireDisposition {
        guard response.jobID != nil else { return .unknown }
#if CORRECTION_TEST_FIXTURES
        if let fixture = testCorrectionDisposition { return fixture(response.jobID, text) }
#endif
        // Current wire type drops unknown fields. Re-encoding therefore fails
        // closed until Mac's actual Codable protocol diff is integrated.
        return CorrectionWireDisposition.classify(jobID: response.jobID, text: text,
                                                    encodedResponse: try? JSONEncoder().encode(response))
    }

    private func drainBufferedResults() {
        guard !capture.isTransitioning, correctionReview == nil, placeReview == nil, heldResult == nil, !translationRecoveryPending, translationDeliveryPending == nil else { return }
        let results = bufferedResults
        bufferedResults.removeAll()
        for (id, text, suggestions, disposition) in results {
            if correctionReview != nil || placeReview != nil || heldResult != nil || translationRecoveryPending || translationDeliveryPending != nil {
                bufferedResults.append((id, text, suggestions, disposition))
                continue
            }
            if disposition == .translationSource { holdForRecovery(text); continue }
            if let id, let contextID = translationJobs.removeValue(forKey: id) {
                _ = submittedHere.remove(id)
                if let translationModel {
                    translationDeliveryPending = contextID
                    translationModel.receiveVoiceSource(text, contextID: contextID)
                } else { holdForRecovery(text) }
                continue
            }
            let autoInsert = id.map { submittedHere.remove($0) != nil } ?? false
            if disposition != .normal {
                if let id, let destination = jobDestinations.removeValue(forKey: id) { onAbandonDestination?(destination) }
                let reviewText: String
                switch disposition {
                case .review(let raw): reviewText = raw; correctionMetadataUnknown = false
                case .unknown: reviewText = text; correctionMetadataUnknown = true
                case .normal, .translationSource: reviewText = text; correctionMetadataUnknown = true
                }
                var review = CorrectionReviewState(); let token = review.begin(original: reviewText)
                _ = review.acceptProposal(CorrectionReviewProposal.make(original: reviewText), token: token)
                correctionReview = review; correctionReviewID = UUID()
                correctionManualText = review.proposal?.draft ?? ""; correctionEditing = false
                defaults.set(reviewText, forKey: "keyboard_correction_review_v1")
                defaults.set(correctionMetadataUnknown, forKey: "keyboard_correction_unknown_v1")
                queueText = correctionMetadataUnknown ? "结果信息不完整 · 请核对" : "纠字待核对 · 后续结果按序等待"
            } else if !suggestions.isEmpty {
                if let id, let destination = jobDestinations.removeValue(forKey: id) { onAbandonDestination?(destination) }
                placeReview = PlaceReviewDraft(original: text, suggestions: suggestions)
                persistPlaceReview()
                receiveResult(text, autoInsert: false)
                queueText = "地名候选待确认 · 后续结果按序等待"
            } else if autoInsert, let id, let destination = jobDestinations.removeValue(forKey: id) {
                let allowed = onDeliverDestination?(destination, text) == true
                receiveResult(text, autoInsert: false)
                if !allowed {
                    holdForRecovery(text)
                }
            } else { holdForRecovery(text) }
        }
    }

    func startCorrectionEdit(reviewID: UUID) {
        guard correctionReviewID == reviewID, correctionReview?.phase == .reviewing else { return }
        correctionEditing = true
    }
    func appendCorrectionText(_ text: String) { guard correctionEditing, correctionReviewID != nil else { return }; correctionManualText += text }
    func deleteCorrectionText() { guard correctionEditing, correctionReviewID != nil, !correctionManualText.isEmpty else { return }; correctionManualText.removeLast() }
    func finishCorrectionEdit(reviewID: UUID) { guard correctionReviewID == reviewID else { return }; correctionEditing = false }
    func chooseCorrection(_ candidate: String, reviewID: UUID) { guard correctionReviewID == reviewID else { return }; correctionEditing = false; _ = correctionReview?.confirm(candidate: candidate) }
    func chooseCorrectionOriginal(reviewID: UUID) { guard correctionReviewID == reviewID else { return }; correctionEditing = false; _ = correctionReview?.keepOriginal() }
    func chooseCorrectionManual(_ text: String, reviewID: UUID) { guard correctionReviewID == reviewID else { return }; correctionEditing = false; _ = correctionReview?.confirmManual(text) }
    func undoCorrection(reviewID: UUID) { guard correctionReviewID == reviewID else { return }; _ = correctionReview?.undo() }
    func useCorrection(reviewID: UUID) {
        guard correctionReviewID == reviewID, visible, canExplicitlyInsert?() == true, let insert = onTextReady,
              let text = correctionReview?.consumeConfirmed() else { return }
        // Explicit insertion targets the currently selected field, not a claim
        // that the original field is still focused. Never replay automatically.
        correctionReview = nil; correctionReviewID = nil; correctionEditing = false; correctionManualText = ""
        defaults.removeObject(forKey: "keyboard_correction_review_v1"); defaults.removeObject(forKey: "keyboard_correction_unknown_v1")
        insert(text); receiveResult(text, autoInsert: false)
        queueText = nil; drainBufferedResults()
    }
    func cancelCorrection(reviewID: UUID) {
        guard correctionReviewID == reviewID, correctionReview != nil else { return }
        correctionReview?.cancel(); correctionReview = nil; correctionReviewID = nil; correctionEditing = false; correctionManualText = ""
        defaults.removeObject(forKey: "keyboard_correction_review_v1"); defaults.removeObject(forKey: "keyboard_correction_unknown_v1")
        queueText = nil; drainBufferedResults()
    }

    private func holdForRecovery(_ text: String) {
        guard !text.isEmpty else { return }
        receiveResult(text, autoInsert: false)
        heldResult = text
        defaults.set(text, forKey: "keyboard_held_result_v1")
        statusText = "输入位置无法确认 · 结果已保留，请主动恢复"
        queueText = "待处理保留结果 · 后续结果按序等待"
    }

    func insertHeldResult() {
        guard visible, canExplicitlyInsert?() == true, let text = heldResult, let insert = onTextReady else { return }
        heldResult = nil
        defaults.removeObject(forKey: "keyboard_held_result_v1")
        insert(text) // Explicit user action inserts into the current field, which may differ.
        queueText = nil
        drainBufferedResults()
    }

    func confirmPlace(_ id: UUID) { _ = placeReview?.confirm(id); persistPlaceReview() }
    func rejectPlace(_ id: UUID) { placeReview?.reject(id); persistPlaceReview() }
    func undoPlace() { placeReview?.undo(); persistPlaceReview() }
    func insertPlaceDraft() {
        guard let draft = placeReview, visible else { return }
        receiveResult(draft.text, autoInsert: true)
        placeReview = nil
        persistPlaceReview()
        drainBufferedResults()
    }
    func retainPlaceDraftWithoutInsertion() {
        guard let draft = placeReview else { return }
        receiveResult(draft.text, autoInsert: false)
        placeReview = nil
        persistPlaceReview()
        drainBufferedResults()
    }
    private func persistPlaceReview() {
        if let draft = placeReview, let data = try? JSONEncoder().encode(draft) {
            defaults.set(data, forKey: "keyboard_place_review_v1")
        } else { defaults.removeObject(forKey: "keyboard_place_review_v1") }
    }

    private func connectionFailed() {
        isConnected = false
        needsActivation = true
        currentState = .inactive
        canRetry = true
        stopTimer()
        capture.settle(recording: false)
        statusText = "需要打开主应用 · 检查权限与模型"
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
                    applyAskFollowUpFlags(from: status)
                } else {
                    chineseScript = pref
                }
                if !isRecording, !capture.isTransitioning {
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
                    applyAskFollowUpFlags(from: status)
                } else {
                    polishEnabled = true
                    polishMode = mode
                    askFollowUpAvailable = false
                    askFollowUpArmed = false
                }
                if !isRecording, !capture.isTransitioning {
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
                    applyAskFollowUpFlags(from: status)
                } else {
                    polishEnabled = enabled
                    if !enabled {
                        askFollowUpAvailable = false
                        askFollowUpArmed = false
                    }
                }
                if !isRecording, !capture.isTransitioning {
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
                    applyAskFollowUpFlags(from: status)
                }
                if !isRecording, !capture.isTransitioning {
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
        // Reconcile with the host; never resubmit a committed recording.
        canRetry = false
        await connect()
    }

    // MARK: - Private

    private var readyPrompt: String {
        let script = chineseScript.shortLabel
        if polishEnabled, polishMode == .askLLM, askFollowUpArmed {
            return "追问已就绪 · 点击说话 · \(script)"
        }
        if polishEnabled, polishMode == .askLLM, askFollowUpAvailable {
            return "点击说话 · 问答 \(script) · 可追问"
        }
        return polishEnabled
            ? "点击说话 · \(polishMode.shortLabel) \(script)"
            : "点击说话 · 润色关 \(script)"
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

    /// One consumer owns ordered delivery, including jobs left by a previous appearance.
    private func startObserving(epoch: UInt64) {
        guard observer == nil else { return }
        observer = Task { [weak self] in
            guard let self else { return }
            defer { if self.appearance == epoch { self.observer = nil } }
            while !Task.isCancelled, self.visible, self.appearance == epoch {
                do {
                    let knownTranslationJobs = Set(self.translationJobs.keys)
                    let response = try await self.client.send(self.correctionReview == nil && self.placeReview == nil && self.heldResult == nil && !self.translationRecoveryPending && self.translationDeliveryPending == nil ? .status : .ping)
                    if response.response.outcome == .text, let text = response.response.text {
                        let id = response.response.jobID
                        let disposition = self.correctionDisposition(response.response, text: text)
                        let item = (id, text, response.response.placeSuggestions ?? [], disposition)
                        if self.visible, self.appearance == epoch {
                            self.bufferedResults.append(item); self.drainBufferedResults()
                        } else if let id, knownTranslationJobs.contains(id) {
                            // This is a translation source, never a translated result.
                            if self.heldResult == nil { self.holdForRecovery(text) }
                            else { self.bufferedResults.append((id, text, response.response.placeSuggestions ?? [], .translationSource)) }
                        } else {
                            // A consumed late dictation must retain its metadata
                            // and be classified before any explicit recovery.
                            self.bufferedResults.append(item); self.drainBufferedResults()
                        }
                    }
                    guard !Task.isCancelled, self.visible, self.appearance == epoch else { return }
                    if let status = response.response.status { self.applyHostStatus(status) }
                    if response.response.outcome == .error {
                        self.queueText = response.response.message ?? "本段处理失败 · 查看历史"
                        self.canRetry = true
                    } else if response.response.outcome == .unauthorized {
                        self.connectionFailed()
                        self.statusText = "鉴权失败 · 请重新安装配套主应用与键盘"
                        return
                    }
                } catch {
                    guard self.visible, self.appearance == epoch else { return }
                    if !self.capture.canSwitchPage {
                        _ = try? await self.client.send(.cancel)
                    }
                    guard self.visible, self.appearance == epoch else { return }
                    self.connectionFailed()
                    self.statusText = "连接中断 · 请打开主应用检查录音状态"
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func applyHostStatus(_ status: BridgeStatus) {
        applyPolishFlag(from: status)
        applyScriptFlag(from: status)
        applyAskFollowUpFlags(from: status)
        currentState = status.state
        pendingCount = status.pendingCount ?? 0
        needsActivation = status.state == .inactive || status.errorCode == .micDenied || status.errorCode == .modelNotReady
        // Queue progress must never masquerade as microphone activity.
        if placeReview != nil {
            queueText = "地名候选待确认 · 后续结果按序等待"
        } else if pendingCount > 0 {
            switch status.state {
            case .polishing: queueText = "润色中 · 待交付 \(pendingCount) 段"
            case .ready: queueText = "等待插入 · \(pendingCount) 段"
            default: queueText = "处理队列 · \(pendingCount) 段"
            }
        } else if !canRetry {
            queueText = status.resultNotice
        }
        capture.observe(recording: status.state == .recording)
        if capture.isRecording {
            // Only host-confirmed recording gets a waveform and timer.
            recordingStart = Date().addingTimeInterval(-(status.elapsedSeconds ?? 0))
            elapsedTime = status.elapsedSeconds ?? 0
            startTimer()
            statusText = "正在录音 · 再次点击完成"
        } else if !capture.isTransitioning {
            stopTimer()
            statusText = needsActivation ? "需要打开主应用 · 检查权限与模型" : readyPrompt
            if status.state == .error {
                statusText = status.message ?? "会话异常，请重试"
                canRetry = true
            }
        }
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
