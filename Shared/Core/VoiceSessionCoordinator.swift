import Foundation
import Combine
import AVFoundation

@MainActor
final class VoiceSessionCoordinator: ObservableObject {
    @Published private(set) var state: BridgeStatus.State = .inactive
    @Published private(set) var elapsedSeconds: TimeInterval?
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastTranscription: String?
    /// Polished text when polish succeeds; nil when disabled/failed/skipped.
    @Published private(set) var lastPolished: String?
    /// Final insert text: polished if available, otherwise local transcription.
    @Published private(set) var lastResult: String?
    /// True when polish was attempted and failed (user sees original).
    @Published private(set) var lastPolishFailed = false
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var preparePhase: String?
    @Published private(set) var modelFilesPresent = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var lastErrorCode: BridgeErrorCode?
    /// Submitted jobs not yet consumed by a client.
    @Published private(set) var pendingCount: Int = 0
    /// Human-readable system input name, e.g. "AirPods 麦克风".
    @Published private(set) var currentInputName: String?
    /// False while the audio route is rebuilding after a device change.
    @Published private(set) var isInputReady: Bool = false

    // MARK: - Optional A/B compare (iOS main app; default off)
    @Published private(set) var lastCompareText: String?
    @Published private(set) var lastCompareError: String?
    @Published private(set) var lastPrimaryLatencyMs: Int?
    @Published private(set) var lastCompareLatencyMs: Int?
    @Published private(set) var compareEngineDisplayName: String = AppleSpeechLocaleSelector.displayName(for: nil)
    @Published private(set) var compareLocaleIdentifier: String?

    private let recorder = AudioRecorder()
    private var transcriber: SenseVoiceTranscriber?
#if os(iOS)
    private var appleTranscriber: AppleOnDeviceTranscriber?
#endif
    private let polisher: TextPolishing = APITextPolisher()
    private var bridgeServer: KeyboardBridgeServer?
    private var settings: AppSettings?
    private var audioTask: Task<Void, Never>?
    /// Optional Apple A/B task; never blocks SenseVoice insert return.
    private var comparePipelineTask: Task<Void, Never>?
    /// Bumped on every start/finish/cancel so a late `beginRecording` cannot reopen capture.
    private var captureEpoch: UInt64 = 0
    /// Bumped on deactivate to abandon in-memory jobs.
    private var pipelineGeneration: UInt64 = 0
    /// True while PCM is being pulled from the recorder after a release.
    /// New starts must wait so we never false-OK a second hold against the previous capture.
    private var isFinalizingCapture = false

    // MARK: - Async multi-segment job pipeline
    private var jobs: [UUID: VoiceJob] = [:]
    private var jobOrder: [UUID] = []
    private var nextSequence: UInt64 = 1
    private var deliveryCursor = OrderedDeliveryCursor()
    private var asrQueue: [UUID] = []
    private var asrWorkerRunning = false
    private var polishQueue: [UUID] = []
    private var polishInFlight = 0
    /// Retains auto-skipped / pruned terminal outcomes until the owner polls once.
    private var retainedOutcomes: [UUID: JobOutcome] = [:]

    // MARK: - Ask-mode multi-turn follow-up
    private var askConversation: [AskConversationTurn] = []
    private var askFollowUpArmed = false
    private let askHistoryLimit = 6

    var askFollowUpAvailable: Bool {
        !askConversation.isEmpty
            && (settings?.polishMode == .askLLM)
            && (settings?.polishEnabled ?? false)
    }

    var isAskFollowUpArmed: Bool {
        askFollowUpArmed && askFollowUpAvailable
    }

    private struct JobSnapshot {
        let vocabulary: String
        let polishEnabled: Bool
        let polishMode: PolishMode
        let baseURL: String
        let modelName: String
        let apiKey: String
        let chineseScript: ChineseScriptPreference
        let compareWithSystemDictation: Bool
        let voiceCandidateReviewEnabled: Bool
        /// Prior ask turns when this job is an armed follow-up.
        let askHistory: [AskConversationTurn]
    }

    private final class VoiceJob {
        let id: UUID
        let sequence: UInt64
        let pcmData: Data
        let snapshot: JobSnapshot
        let generation: UInt64

        var phase: VoiceJobPhase = .queuedASR
        var localText: String?
        var polishedText: String?
        var finalText: String?
        var polishFailed = false
        var draft: VoiceDraft?
        var errorMessage: String?
        var primaryLatencyMs: Int?
        var delivered = false

        init(id: UUID, sequence: UInt64, pcmData: Data, snapshot: JobSnapshot, generation: UInt64) {
            self.id = id
            self.sequence = sequence
            self.pcmData = pcmData
            self.snapshot = snapshot
            self.generation = generation
        }
    }

    var currentStatus: BridgeStatus {
        BridgeStatus(
            state: state,
            elapsedSeconds: elapsedSeconds,
            message: statusMessage,
            polishEnabled: settings?.polishEnabled,
            polishMode: settings?.polishMode.rawValue,
            pendingCount: pendingCount,
            chineseScript: settings?.chineseScript.rawValue,
            askFollowUpAvailable: askFollowUpAvailable,
            askFollowUpArmed: isAskFollowUpArmed
        )
    }

    var isPolishEnabled: Bool {
        settings?.polishEnabled ?? true
    }

    var currentPolishMode: PolishMode {
        settings?.polishMode ?? .default
    }

    /// Update polish toggle from keyboard / input method bridge.
    @discardableResult
    func setPolishEnabled(_ enabled: Bool) -> Bool {
        guard let settings else { return false }
        settings.polishEnabled = enabled
        if !enabled {
            clearAskConversation()
        }
        return true
    }

    /// Set polish mode and ensure polish is enabled.
    @discardableResult
    func setPolishMode(_ mode: PolishMode) -> Bool {
        guard let settings else { return false }
        let previous = settings.polishMode
        settings.polishMode = mode
        settings.polishEnabled = true
        if mode != .askLLM || previous != mode {
            // Leaving ask, or switching into ask from elsewhere: start a fresh thread.
            if previous == .askLLM || mode == .askLLM {
                clearAskConversation()
            }
        }
        return true
    }

    /// Set Chinese script preference from keyboard / input method bridge.
    @discardableResult
    func setChineseScript(_ pref: ChineseScriptPreference) -> Bool {
        guard let settings else { return false }
        settings.chineseScript = pref
        return true
    }

    /// Arm the next ask-mode capture as a serial follow-up using prior turns.
    @discardableResult
    func armAskFollowUp() -> Bool {
        guard askFollowUpAvailable else {
            askFollowUpArmed = false
            return false
        }
        askFollowUpArmed = true
        if state != .recording {
            statusMessage = "追问已就绪 · 按住说话"
        }
        return true
    }

    /// Drop ask conversation history and disarm follow-up.
    func clearAskConversation() {
        askConversation.removeAll()
        askFollowUpArmed = false
    }

    /// Cycle: off → 纠错 → 代码 → 润色 → 问答 → off.
    @discardableResult
    func cyclePolishMode() -> Bool {
        guard let settings else { return false }
        if !settings.polishEnabled {
            settings.polishEnabled = true
            settings.polishMode = .correctOnly
            return true
        }
        let order = PolishMode.cycleOrder
        guard let idx = order.firstIndex(of: settings.polishMode) else {
            settings.polishMode = .correctOnly
            return true
        }
        if idx + 1 < order.count {
            let next = order[idx + 1]
            if settings.polishMode == .askLLM || next == .askLLM {
                clearAskConversation()
            }
            settings.polishMode = next
        } else {
            if settings.polishMode == .askLLM {
                clearAskConversation()
            }
            settings.polishEnabled = false
        }
        return true
    }

    /// Human-readable polish state for bridge messages / UI.
    var polishStateSummary: String {
        guard let settings else { return "润色关" }
        if !settings.polishEnabled { return "润色关" }
        return settings.polishMode.shortLabel
    }

    func setup(settings: AppSettings) {
        self.settings = settings
        if transcriber == nil {
            transcriber = SenseVoiceTranscriber()
        }
#if os(iOS)
        if appleTranscriber == nil {
            appleTranscriber = AppleOnDeviceTranscriber()
        }
#endif
        Task { await refreshModelPresence() }
    }

    func refreshModelPresence() async {
        modelFilesPresent = await transcriber?.hasModelFiles ?? false
        if await isModelReady {
            modelFilesPresent = true
        }
    }

    func activate() async {
        guard state == .inactive || state == .error else { return }
        statusMessage = "正在启动..."

        let micOK = await MicrophonePermission.request()
        lastErrorCode = nil
        guard micOK else {
            state = .error
            statusMessage = "需要麦克风权限"
            lastErrorCode = .micDenied
            return
        }

        do {
            if let transcriber, await !transcriber.isReady {
                if await !transcriber.hasModelFiles {
                    // Allow explicit download flow from UI; do not silently pull ~230MB here.
                    state = .error
                    statusMessage = "模型未就绪，请先下载"
                    lastErrorCode = .modelNotReady
                    return
                }
                statusMessage = "加载模型..."
                try await transcriber.prepareModel()
            }
            try await recorder.startSession()
            bindRecorderRouteCallbacks()
            currentInputName = recorder.currentInputName
            isInputReady = recorder.isInputReady
            bridgeServer = KeyboardBridgeServer(coordinator: self)
            await bridgeServer?.start()
            state = .ready
            statusMessage = readyMessage()
        } catch {
            state = .error
            statusMessage = "启动失败: \(error.localizedDescription)"
            lastErrorCode = .unknown
            currentInputName = nil
            isInputReady = false
        }
    }

    func deactivate() {
        // Invalidate any in-flight capture so late callbacks cannot reopen the mic.
        captureEpoch &+= 1
        pipelineGeneration &+= 1
        isFinalizingCapture = false
        audioTask?.cancel()
        comparePipelineTask?.cancel()
        audioTask = nil
        comparePipelineTask = nil
        clearAllJobs()

        let server = bridgeServer
        bridgeServer = nil

        Task {
            recorder.cancelRecording()
            await recorder.stopSession()
            await server?.stop()
        }

        state = .inactive
        elapsedSeconds = nil
        lastResult = nil
        lastTranscription = nil
        lastPolished = nil
        lastPolishFailed = false
        clearCompareFields()
        inputLevel = 0
        lastErrorCode = nil
        currentInputName = nil
        isInputReady = false
        clearRecorderRouteCallbacks()
        statusMessage = "已关闭 · 麦克风与桥接已停止"
    }

    func downloadModel() async throws {
        guard let transcriber else { throw TranscriberError.notReady }
        let filesPresent = await transcriber.hasModelFiles
        modelFilesPresent = filesPresent
        preparePhase = filesPresent ? "loading" : "downloading"
        statusMessage = filesPresent ? "加载本地模型..." : "下载模型中..."
        downloadProgress = filesPresent ? nil : 0

        // Observe progress while prepareModel downloads / loads.
        let progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let phase = await self.transcriber?.preparePhase
                let progress = await self.transcriber?.downloadProgress
                self.preparePhase = phase
                if let progress {
                    self.downloadProgress = progress
                    self.statusMessage = "下载中 \(Int(progress * 100))%"
                } else if phase == "loading" {
                    self.downloadProgress = nil
                    self.statusMessage = "加载本地模型..."
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        do {
            try await transcriber.prepareModel()
            progressTask.cancel()
            downloadProgress = 1
            preparePhase = nil
            modelFilesPresent = true
            statusMessage = "模型就绪"
        } catch {
            progressTask.cancel()
            downloadProgress = nil
            preparePhase = nil
            statusMessage = "模型准备失败: \(error.localizedDescription)"
            lastErrorCode = .modelNotReady
            throw error
        }
    }

    var isModelReady: Bool {
        get async { await transcriber?.isReady ?? false }
    }

    var hasModelFiles: Bool {
        get async { await transcriber?.hasModelFiles ?? false }
    }

    var modelDisplayName: String {
        transcriber?.modelDisplayName ?? AppConstants.senseVoiceModelDisplayName
    }

    // MARK: - Hold-to-record

    /// Begin a new capture. Returns true only when the session entered `.recording`.
    @discardableResult
    func startRecording() -> Bool {
        // Recording is independent of pending ASR/polish jobs.
        guard state != .inactive else { return false }
        if state == .error, let code = lastErrorCode, code == .micDenied || code == .modelNotReady {
            return false
        }
        // Previous release is still securing PCM — callers should brief-retry.
        if isFinalizingCapture {
            return false
        }
        if recorder.isRecoveringInput || !recorder.isInputReady {
            _ = recorder.ensureInputReadyForRecording()
        }
        if AudioRouteRecoveryPolicy.shouldRejectStart(
            isRecovering: recorder.isRecoveringInput,
            isInputReady: recorder.isInputReady
        ) {
            lastErrorCode = .inputSessionInvalid
            statusMessage = "麦克风切换中，请稍后再试"
            // Keep ready/error state so UI can show recovery; do not enter recording.
            if state != .error {
                state = .ready
            }
            return false
        }
        guard state != .recording else { return true }

        captureEpoch &+= 1
        let epoch = captureEpoch
        state = .recording
        elapsedSeconds = 0
        inputLevel = 0
        statusMessage = "录音中 · 松开发送"
        lastErrorCode = nil
        recorder.beginRecording()

        let maxDur = settings?.maxRecordingDuration ?? AppConstants.defaultMaxRecordingDuration
        audioTask?.cancel()
        audioTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let elapsed = await self.recorder.elapsed
                let level = await self.recorder.latestLevel
                await MainActor.run {
                    self.elapsedSeconds = elapsed
                    self.inputLevel = level
                    if elapsed >= maxDur {
                        Task { _ = await self.finishRecordingAndEnqueue() }
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return true
    }

    /// Capture audio, enqueue async processing, and free the mic immediately.
    @discardableResult
    func finishRecordingAndEnqueue() async -> UUID? {
        guard state == .recording, !isFinalizingCapture else { return nil }
        isFinalizingCapture = true
        captureEpoch &+= 1
        audioTask?.cancel()
        audioTask = nil
        elapsedSeconds = nil
        inputLevel = 0

        guard let snapshot = makeSnapshot() else {
            isFinalizingCapture = false
            state = .error
            statusMessage = "主应用设置不可用"
            lastErrorCode = .unknown
            return nil
        }

        // Leave `.recording` before the actor hop so a concurrent bridge `start`
        // cannot false-OK against the previous capture.
        state = .transcribing
        statusMessage = "提交中…"

        let data = recorder.finishRecording()
        let jobID = UUID()
        let sequence = nextSequence
        nextSequence &+= 1
        let job = VoiceJob(
            id: jobID,
            sequence: sequence,
            pcmData: data,
            snapshot: snapshot,
            generation: pipelineGeneration
        )
        jobs[jobID] = job
        jobOrder.append(jobID)
        asrQueue.append(jobID)
        isFinalizingCapture = false
        refreshProcessingStatus()
        kickASRWorker()
        return jobID
    }

    /// Compatibility helper: enqueue then wait for that job's ordered result.
    @discardableResult
    func finishRecordingAndWait() async -> String? {
        guard let jobID = await finishRecordingAndEnqueue() else {
            return lastResult
        }
        return await waitForJobResult(jobID)
    }

    /// Wait until a specific job becomes deliverable (in speaking order), then consume it.
    func waitForJobResult(_ jobID: UUID) async -> String? {
        while !Task.isCancelled {
            if pipelineGenerationInvalidated(for: jobID) && jobs[jobID] == nil && retainedOutcomes[jobID] == nil {
                return nil
            }
            if let outcome = takeJobOutcome(jobID: jobID) {
                switch outcome {
                case .draft:
                    // This compatibility helper has no review UI.  Leave the
                    // job pending until an interactive keyboard confirms it.
                    return nil
                case .text(let text):
                    return text
                case .failed:
                    return nil
                case .pending:
                    break
                }
            } else if jobs[jobID] == nil, retainedOutcomes[jobID] == nil {
                // Unknown / already consumed without payload.
                return nil
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    /// Left-swipe / Escape: discard only the in-progress capture.
    func cancelRecording() {
        // Do not abort a release that already secured PCM and is enqueuing.
        if isFinalizingCapture {
            return
        }
        captureEpoch &+= 1
        audioTask?.cancel()
        audioTask = nil
        Task { recorder.cancelRecording() }
        elapsedSeconds = nil
        inputLevel = 0
        refreshProcessingStatus(defaultMessage: "已取消 · 按住说话")
    }

    /// Cancel only the live capture after a microphone route change.
    private func cancelRecordingForRouteChange() {
        if isFinalizingCapture {
            // PCM already secured for a job; leave the pipeline alone.
            return
        }
        guard state == .recording else { return }
        captureEpoch &+= 1
        audioTask?.cancel()
        audioTask = nil
        recorder.cancelRecording()
        elapsedSeconds = nil
        inputLevel = 0
        lastErrorCode = .inputSessionInvalid
        // Do not treat as a hard error — recovery may complete shortly.
        state = .ready
        statusMessage = "麦克风已切换，本段已取消"
    }

    func clearResult() {
        lastResult = nil
        lastTranscription = nil
        lastPolished = nil
        lastPolishFailed = false
        clearCompareFields()
    }

    // MARK: - Bridge job queries

    enum JobOutcome: Equatable {
        case pending
        case draft(VoiceDraft)
        case text(String)
        case failed(String)
    }

    /// Consume a deliverable job result. `jobID == nil` returns the oldest deliverable job.
    func takeJobOutcome(jobID: UUID?) -> JobOutcome? {
        if let jobID {
            if let retained = retainedOutcomes.removeValue(forKey: jobID) {
                return retained
            }
            guard let job = jobs[jobID] else { return nil }
            if job.delivered {
                // Already consumed or auto-skipped without a retained payload.
                return nil
            }
            guard deliveryCursor.canDeliver(sequence: job.sequence) else {
                return .pending
            }
            if job.phase == .awaitingReview, let draft = job.draft {
                return .draft(draft)
            }
            return consumeIfTerminal(job)
        }

        // Legacy: oldest undelivered terminal job at the delivery cursor.
        while let job = jobAtDeliveryCursor() {
            if let outcome = consumeIfTerminal(job) {
                if case .pending = outcome {
                    return .pending
                }
                return outcome
            }
            // Non-terminal at cursor: still processing.
            return .pending
        }
        return nil
    }

    func statusForJob(_ jobID: UUID?) -> BridgeStatus {
        if let jobID, let job = jobs[jobID] {
            let message: String
            if job.delivered {
                message = statusMessage ?? "就绪 · 按住说话"
            } else {
                message = VoiceJobStatusText.processingMessage(
                    phase: job.phase,
                    polishMode: job.snapshot.polishMode,
                    pendingCount: pendingCount
                )
            }
            let reportedState: BridgeStatus.State
            if stateIsRecording() {
                reportedState = .recording
            } else {
                switch job.phase {
                case .queuedASR, .transcribing:
                    reportedState = .transcribing
                case .queuedPolish, .polishing:
                    reportedState = .polishing
                case .awaitingReview, .ready:
                    reportedState = .ready
                case .failed:
                    reportedState = .error
                }
            }
            return BridgeStatus(
                state: reportedState,
                elapsedSeconds: elapsedSeconds,
                message: message,
                polishEnabled: settings?.polishEnabled,
                polishMode: settings?.polishMode.rawValue,
                jobID: jobID,
                pendingCount: pendingCount,
                chineseScript: settings?.chineseScript.rawValue,
                askFollowUpAvailable: askFollowUpAvailable,
                askFollowUpArmed: isAskFollowUpArmed
            )
        }
        return currentStatus
    }

    private func consumeIfTerminal(_ job: VoiceJob) -> JobOutcome? {
        guard deliveryCursor.canDeliver(sequence: job.sequence) else {
            return .pending
        }
        switch job.phase {
        case .ready:
            let text = job.finalText ?? ""
            markDelivered(job)
            if text.isEmpty {
                return .failed(job.errorMessage ?? "无识别结果")
            }
            return .text(text)
        case .failed:
            let message = job.errorMessage ?? "识别失败"
            markDelivered(job)
            return .failed(message)
        default:
            return .pending
        }
    }

    private func markDelivered(_ job: VoiceJob) {
        guard !job.delivered else { return }
        job.delivered = true
        if job.phase == .ready {
            publishLatest(from: job)
        }
        deliveryCursor.advance()
        pruneDeliveredPrefix()
        skipFailedAtCursor()
        if let next = jobAtDeliveryCursor(), next.phase == .ready {
            publishLatest(from: next)
        }
        refreshProcessingStatus()
    }

    /// Failed segments auto-skip so later jobs are never stuck waiting for a dead poller.
    private func skipFailedAtCursor() {
        while let job = jobAtDeliveryCursor(), job.phase == .failed, !job.delivered {
            retainOutcome(.failed(job.errorMessage ?? "识别失败"), for: job.id)
            job.delivered = true
            deliveryCursor.advance()
            pruneDeliveredPrefix()
        }
    }

    private func retainOutcome(_ outcome: JobOutcome, for jobID: UUID) {
        retainedOutcomes[jobID] = outcome
    }

    private func jobAtDeliveryCursor() -> VoiceJob? {
        jobs.values
            .filter { !$0.delivered }
            .sorted { $0.sequence < $1.sequence }
            .first { deliveryCursor.canDeliver(sequence: $0.sequence) }
    }

    private func pruneDeliveredPrefix() {
        while let first = jobOrder.first, let job = jobs[first], job.delivered {
            jobOrder.removeFirst()
            jobs[first] = nil
        }
        updatePendingCount()
    }

    private func clearAllJobs() {
        jobs.removeAll()
        jobOrder.removeAll()
        asrQueue.removeAll()
        polishQueue.removeAll()
        polishInFlight = 0
        asrWorkerRunning = false
        retainedOutcomes.removeAll()
        nextSequence = 1
        deliveryCursor.reset()
        updatePendingCount()
    }

    private func updatePendingCount() {
        pendingCount = jobs.values.filter { !$0.delivered }.count
    }

    private func stateIsRecording() -> Bool {
        state == .recording
    }

    private func pipelineGenerationInvalidated(for jobID: UUID) -> Bool {
        guard let job = jobs[jobID] else { return true }
        return job.generation != pipelineGeneration
    }

    private func makeSnapshot() -> JobSnapshot? {
        guard let settings else { return nil }
        var history: [AskConversationTurn] = []
        if settings.polishEnabled, settings.polishMode == .askLLM {
            if askFollowUpArmed, !askConversation.isEmpty {
                history = askConversation
                // Consume the arm so a later non-follow-up recording starts fresh.
                askFollowUpArmed = false
            } else {
                // Fresh ask question: drop previous thread.
                clearAskConversation()
            }
        }
        return JobSnapshot(
            vocabulary: settings.customVocabulary,
            polishEnabled: settings.polishEnabled,
            polishMode: settings.polishMode,
            baseURL: settings.baseURL,
            modelName: settings.modelName,
            apiKey: settings.apiKey ?? "",
            chineseScript: settings.chineseScript,
            compareWithSystemDictation: settings.compareWithSystemDictation,
            voiceCandidateReviewEnabled: settings.voiceCandidateReviewEnabled,
            askHistory: history
        )
    }

    /// Accept a keyboard-reviewed draft and continue optional cloud polishing.
    /// A duplicate confirmation is successful once the job has already moved on.
    @discardableResult
    func confirmDraft(jobID: UUID, text: String) -> Bool {
        guard let job = jobs[jobID], job.generation == pipelineGeneration else { return false }
        guard job.phase == .awaitingReview else {
            return job.phase == .queuedPolish || job.phase == .polishing || job.phase == .ready
        }
        let revised = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revised.isEmpty else {
            failJob(job, message: "候选词确认内容为空")
            return false
        }
        job.localText = revised
        job.draft = nil
        let shouldPolish = job.snapshot.polishEnabled && !job.snapshot.apiKey.isEmpty
        if shouldPolish {
            job.phase = .queuedPolish
            polishQueue.append(jobID)
            refreshProcessingStatus()
            pumpPolishQueue()
        } else {
            completeJob(job, finalText: revised, polished: nil, polishFailed: false)
        }
        return true
    }

    /// The keyboard lost its host text session. Keep the raw marked text and
    /// release the delivery cursor; never let a late polish overwrite a new
    /// cursor or document.
    @discardableResult
    func abandonDraft(jobID: UUID) -> Bool {
        guard let job = jobs[jobID], job.phase == .awaitingReview else { return false }
        let raw = job.draft?.text ?? job.localText ?? ""
        guard !raw.isEmpty else { return false }
        job.draft = nil
        job.localText = raw
        completeJob(job, finalText: raw, polished: nil, polishFailed: false)
        _ = takeJobOutcome(jobID: jobID)
        return true
    }

    private func clearCompareFields() {
        lastCompareText = nil
        lastCompareError = nil
        lastPrimaryLatencyMs = nil
        lastCompareLatencyMs = nil
        compareLocaleIdentifier = nil
        compareEngineDisplayName = AppleSpeechLocaleSelector.displayName(for: nil)
    }

    // MARK: - Status while recording vs processing

    private func refreshProcessingStatus(defaultMessage: String? = nil) {
        updatePendingCount()
        if state == .recording {
            return
        }
        if state == .inactive {
            return
        }

        // Prefer the oldest undelivered non-terminal job for global status.
        let active = jobs.values
            .filter { !$0.delivered }
            .sorted { $0.sequence < $1.sequence }

        if let job = active.first(where: {
            switch $0.phase {
            case .queuedASR, .transcribing, .queuedPolish, .polishing, .awaitingReview:
                return true
            default:
                return false
            }
        }) {
            switch job.phase {
            case .queuedASR, .transcribing:
                state = .transcribing
            case .queuedPolish, .polishing:
                state = .polishing
            case .awaitingReview:
                state = .ready
            default:
                break
            }
            statusMessage = VoiceJobStatusText.processingMessage(
                phase: job.phase,
                polishMode: job.snapshot.polishMode,
                pendingCount: pendingCount
            )
            return
        }

        if let ready = active.first(where: { $0.phase == .ready || $0.phase == .awaitingReview }) {
            state = .ready
            statusMessage = VoiceJobStatusText.processingMessage(
                phase: ready.phase,
                polishMode: ready.snapshot.polishMode,
                pendingCount: pendingCount
            )
            return
        }

        state = .ready
        if recorder.isRecoveringInput || !recorder.isInputReady {
            statusMessage = defaultMessage ?? "麦克风切换中…"
            lastErrorCode = .inputSessionInvalid
        } else {
            statusMessage = defaultMessage ?? readyMessage()
            lastErrorCode = nil
        }
    }

    private func readyMessage() -> String {
        if let name = currentInputName, !name.isEmpty {
            return "就绪 · \(name) · 按住说话"
        }
        return "就绪 · 按住说话"
    }

    private func bindRecorderRouteCallbacks() {
        recorder.onCaptureInterruptedByRouteChange = { [weak self] in
            self?.cancelRecordingForRouteChange()
        }
        recorder.onInputNameChange = { [weak self] name in
            guard let self else { return }
            self.currentInputName = name
            if self.state == .ready, self.recorder.isInputReady, !self.recorder.isRecoveringInput {
                self.statusMessage = self.readyMessage()
            }
        }
        recorder.onInputRecoveryStarted = { [weak self] in
            guard let self else { return }
            self.isInputReady = false
            self.lastErrorCode = .inputSessionInvalid
            if self.state == .recording {
                self.cancelRecordingForRouteChange()
            } else if self.state != .inactive {
                self.statusMessage = "麦克风切换中…"
            }
        }
        recorder.onInputRecoverySucceeded = { [weak self] name in
            guard let self else { return }
            self.currentInputName = name
            self.isInputReady = true
            if self.lastErrorCode == .inputSessionInvalid {
                self.lastErrorCode = nil
            }
            if self.state == .error, self.lastErrorCode == nil || self.lastErrorCode == .inputSessionInvalid {
                self.state = .ready
            }
            if self.state == .ready || self.state == .transcribing || self.state == .polishing {
                if self.state == .ready {
                    self.statusMessage = self.readyMessage()
                }
            }
        }
        recorder.onInputRecoveryFailed = { [weak self] error in
            guard let self else { return }
            self.isInputReady = false
            self.lastErrorCode = .inputSessionInvalid
            // Stay usable for later route events; surface a diagnostic message.
            if self.state != .inactive && self.state != .recording {
                self.state = .error
                self.statusMessage = "麦克风不可用: \(error.localizedDescription)"
            }
        }
    }

    private func clearRecorderRouteCallbacks() {
        recorder.onCaptureInterruptedByRouteChange = nil
        recorder.onInputNameChange = nil
        recorder.onInputRecoveryStarted = nil
        recorder.onInputRecoverySucceeded = nil
        recorder.onInputRecoveryFailed = nil
    }

    // MARK: - ASR worker (FIFO, concurrency 1)

    private func kickASRWorker() {
        guard !asrWorkerRunning else { return }
        asrWorkerRunning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while true {
                guard let jobID = self.asrQueue.first else { break }
                self.asrQueue.removeFirst()
                await self.processASR(jobID: jobID)
            }
            self.asrWorkerRunning = false
            // A job may have been enqueued while the loop was exiting.
            if !self.asrQueue.isEmpty {
                self.kickASRWorker()
            }
        }
    }

    private func processASR(jobID: UUID) async {
        guard let job = jobs[jobID], !job.delivered else { return }
        guard job.generation == pipelineGeneration else { return }
        job.phase = .transcribing
        refreshProcessingStatus()

        guard let transcriber else {
            failJob(job, message: "模型未加载")
            return
        }

        maybeLaunchCompare(for: job)
        #if os(iOS)
        let candidateTask = makeCandidateTask(for: job)
        #endif

        do {
            let started = ContinuousClock.now
            let raw = try await transcriber.transcribe(job.pcmData, vocabulary: job.snapshot.vocabulary)
            guard job.generation == pipelineGeneration, jobs[jobID] != nil else { return }
            job.primaryLatencyMs = elapsedMilliseconds(since: started)
            lastPrimaryLatencyMs = job.primaryLatencyMs

            let cleaned = LocalTextProcessor.process(raw, vocabulary: job.snapshot.vocabulary)
            let local = applyScript(cleaned, job.snapshot.chineseScript)
            job.localText = local
            lastTranscription = local

            #if os(iOS)
            if let candidateTask,
               let apple = await awaitCandidateResult(from: candidateTask),
               let generatedDraft = VoiceCandidateBuilder.makeDraft(
                    source: local,
                    hypotheses: apple.hypotheses.map {
                        AppleSpeechHypothesis(
                            text: applyScript(
                                LocalTextProcessor.process($0.text, vocabulary: job.snapshot.vocabulary),
                                job.snapshot.chineseScript
                            ),
                            confidence: $0.confidence,
                            rank: $0.rank
                        )
                    }
               ) {
                let draft = VoiceDraft(
                    id: job.id,
                    text: generatedDraft.text,
                    candidateGroups: generatedDraft.candidateGroups
                )
                job.draft = draft
                job.phase = .awaitingReview
                refreshProcessingStatus()
                return
            }
            #endif

            let shouldPolish = job.snapshot.polishEnabled && !job.snapshot.apiKey.isEmpty
            if shouldPolish {
                job.phase = .queuedPolish
                polishQueue.append(jobID)
                refreshProcessingStatus()
                pumpPolishQueue()
            } else {
                completeJob(job, finalText: local, polished: nil, polishFailed: false)
            }
        } catch {
            if Task.isCancelled || job.generation != pipelineGeneration {
                return
            }
            // ASR failure skips this segment without blocking later delivery.
            failJob(job, message: error.localizedDescription)
        }
    }

    #if os(iOS)
    private func makeCandidateTask(for job: VoiceJob) -> Task<AppleSpeechCandidates?, Never>? {
        guard job.snapshot.voiceCandidateReviewEnabled else { return nil }
        let apple = appleTranscriber ?? AppleOnDeviceTranscriber()
        if appleTranscriber == nil { appleTranscriber = apple }
        let data = job.pcmData
        return Task {
            do {
                return try await apple.transcribeCandidates(data, vocabulary: "")
            } catch {
                return nil
            }
        }
    }

    private func awaitCandidateResult(
        from task: Task<AppleSpeechCandidates?, Never>
    ) async -> AppleSpeechCandidates? {
        await withTaskGroup(of: AppleSpeechCandidates?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(
                    nanoseconds: UInt64(AppConstants.candidateRecognitionGracePeriod * 1_000_000_000)
                )
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }
    #endif

    private func maybeLaunchCompare(for job: VoiceJob) {
#if os(iOS)
        guard job.snapshot.compareWithSystemDictation else { return }
        let apple = appleTranscriber ?? AppleOnDeviceTranscriber()
        if appleTranscriber == nil { appleTranscriber = apple }
        let data = job.pcmData
        comparePipelineTask?.cancel()
        comparePipelineTask = Task { [weak self] in
            guard let self else { return }
            let started = ContinuousClock.now
            do {
                let text = try await apple.transcribe(data, vocabulary: "")
                let ms = await MainActor.run { self.elapsedMilliseconds(since: started) }
                let locale = await apple.resolvedLocaleIdentifier
                let name = await apple.compareEngineDisplayName
                await MainActor.run {
                    self.lastCompareText = text
                    self.lastCompareError = nil
                    self.lastCompareLatencyMs = ms
                    self.compareLocaleIdentifier = locale
                    self.compareEngineDisplayName = name
                }
            } catch {
                if Task.isCancelled { return }
                let locale = await apple.resolvedLocaleIdentifier
                let name = await apple.compareEngineDisplayName
                await MainActor.run {
                    self.lastCompareText = nil
                    self.lastCompareError = error.localizedDescription
                    self.lastCompareLatencyMs = self.elapsedMilliseconds(since: started)
                    self.compareLocaleIdentifier = locale
                    self.compareEngineDisplayName = name
                }
            }
        }
#endif
    }

    // MARK: - Cloud polish (max concurrency 2)

    private func pumpPolishQueue() {
        let limit = AppConstants.cloudPolishConcurrency
        while polishInFlight < limit, !polishQueue.isEmpty {
            let jobID = polishQueue.removeFirst()
            guard let job = jobs[jobID], !job.delivered else { continue }
            guard job.generation == pipelineGeneration else { continue }
            polishInFlight += 1
            job.phase = .polishing
            refreshProcessingStatus()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.processPolish(jobID: jobID)
                self.polishInFlight = max(0, self.polishInFlight - 1)
                self.pumpPolishQueue()
            }
        }
    }

    private func processPolish(jobID: UUID) async {
        guard let job = jobs[jobID], !job.delivered else { return }
        guard job.generation == pipelineGeneration else { return }
        let local = job.localText ?? ""
        let polishing = PolishingSettings(
            baseURL: job.snapshot.baseURL,
            modelName: job.snapshot.modelName,
            apiKey: job.snapshot.apiKey,
            mode: job.snapshot.polishMode,
            chineseScript: job.snapshot.chineseScript,
            askHistory: job.snapshot.askHistory
        )
        do {
            let polished = try await polishWithTimeout(local, settings: polishing)
            guard job.generation == pipelineGeneration, jobs[jobID] != nil else { return }
            // LLM success (纠错/代码/润色/问答): keep model text. Do not re-run
            // LocalTextProcessor.joinTranscriptSegments or force local `。` here.
            let finalText = applyScript(polished, job.snapshot.chineseScript)
            if job.snapshot.polishMode == .askLLM {
                appendAskTurn(user: local, assistant: finalText)
            }
            completeJob(job, finalText: finalText, polished: finalText, polishFailed: false)
        } catch {
            guard job.generation == pipelineGeneration, jobs[jobID] != nil else { return }
            let errorDetail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if job.snapshot.polishMode == .askLLM {
                // Never insert the raw question as if it were the answer.
                failJob(job, message: "回答生成失败: \(errorDetail)")
                return
            }
            job.errorMessage = "润色失败: \(errorDetail)"
            // Fallback uses local ASR text (already smart-joined at transcribe time).
            completeJob(job, finalText: local, polished: nil, polishFailed: true)
        }
    }

    private func appendAskTurn(user: String, assistant: String) {
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssistant = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty, !trimmedAssistant.isEmpty else { return }
        askConversation.append(AskConversationTurn(user: trimmedUser, assistant: trimmedAssistant))
        if askConversation.count > askHistoryLimit {
            askConversation.removeFirst(askConversation.count - askHistoryLimit)
        }
        // Require an explicit 追问 tap for the next serial turn.
        askFollowUpArmed = false
    }

    private func completeJob(
        _ job: VoiceJob,
        finalText: String,
        polished: String?,
        polishFailed: Bool
    ) {
        job.polishedText = polished
        job.polishFailed = polishFailed
        job.finalText = finalText
        job.phase = .ready
        job.errorMessage = nil

        // Latest UI fields publish when the job reaches the delivery cursor (on consume or when head).
        if deliveryCursor.canDeliver(sequence: job.sequence) {
            publishLatest(from: job)
        }
        refreshProcessingStatus()
    }

    private func failJob(_ job: VoiceJob, message: String) {
        job.phase = .failed
        job.errorMessage = message
        job.finalText = nil
        lastErrorCode = .unknown
        if state != .recording {
            statusMessage = "\(message) · 已跳过该段"
        }
        // Auto-skip when this failed job reaches the delivery cursor.
        skipFailedAtCursor()
        refreshProcessingStatus()
    }

    private func publishLatest(from job: VoiceJob) {
        lastTranscription = job.localText
        lastPolished = job.polishedText
        lastPolishFailed = job.polishFailed
        lastResult = job.finalText
        if let ms = job.primaryLatencyMs {
            lastPrimaryLatencyMs = ms
        }
    }

    private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: ContinuousClock.now)
        let ms = Double(duration.components.seconds) * 1000.0
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
        return max(Int(ms.rounded()), 0)
    }

    private func applyScript(_ text: String, _ pref: ChineseScriptPreference) -> String {
        ChineseScriptConverter.convert(text, direction: pref.conversionDirection)
    }

    private func polishWithTimeout(_ text: String, settings: PolishingSettings) async throws -> String {
        let timeoutSec = settings.timeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.polisher.polish(text, settings: settings) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                throw PolishingError.timeout
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

}
