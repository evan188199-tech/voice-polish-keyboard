import AVFoundation

/// iOS audio capture built on AVAudioSession and AVAudioEngine.
/// PCM is discarded unless the coordinator calls `beginRecording()`.
///
/// Follows the system default input (including AirPods HFP). On route/device
/// changes the engine is rebuilt after a short settle delay so capture can recover.
@MainActor
final class AudioRecorder {
    private var engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat?
    private let sink = AudioCaptureSink()
    private var sessionActive = false
    private var isRecovering = false
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    // Headset/HFP hardware comes online asynchronously.  A single short wait
    // is not enough on real devices (and commonly results in AVFAudio -10868).
    private let maxRecoveryAttempts = 8
    private let settleNanoseconds: UInt64 = 250_000_000
    /// Device-removal notifications arrive before the replacement input is
    /// fully usable; give the built-in microphone a longer initial grace time.
    private let routeChangeSettleNanoseconds: UInt64 = 1_000_000_000
    /// After deactivating the session, Core Audio still needs a beat before the
    /// next `setActive(true)` can bind a fresh input unit.
    private let postDeactivateSettleNanoseconds: UInt64 = 200_000_000
    /// `setActive(true)` may return before a just-connected/disconnected HFP
    /// route has a usable input format. Starting the input AU in that window
    /// commonly yields AVFAudio -10868 (`kAudioUnitErr_FormatNotSupported`).
    private let activationSettleNanoseconds: UInt64 = 200_000_000
    /// Poll window while waiting for `currentRoute.inputs` after activation.
    private let routeUsablePollNanoseconds: UInt64 = 100_000_000
    private let routeUsableMaxWaitNanoseconds: UInt64 = 2_000_000_000
    private var observers: [NSObjectProtocol] = []
#if os(iOS)
    /// Some media apps do not emit a silence-secondary-audio notification when
    /// our mixed recording session is already active. Poll the corresponding
    /// session property as a fallback so playback still releases the mic.
    private var systemAudioMonitorTask: Task<Void, Never>?
    private var wasOtherPrimaryAudioPlaying = false
#endif
    /// Suppresses observer-driven rebuilds while we are already rebuilding.
    private var isApplyingRebuild = false
    /// Rebuild operations emit their own configuration notifications after the
    /// synchronous guard has cleared. Suppress that echo to avoid a loop.
    private var suppressEngineConfigUntil = Date.distantPast

    private(set) var currentInputName: String = "麦克风"
    private(set) var isInputReady = false

    /// Fired on MainActor when the active capture must be discarded (route rebuild).
    var onCaptureInterruptedByRouteChange: (() -> Void)?
    /// Fired when the human-readable input name changes.
    var onInputNameChange: ((String) -> Void)?
    /// Fired when a route rebuild begins (input temporarily unusable).
    var onInputRecoveryStarted: (() -> Void)?
    /// Fired after a successful rebuild with the new input name.
    var onInputRecoverySucceeded: ((String) -> Void)?
    /// Fired after retries are exhausted for the current disruption.
    var onInputRecoveryFailed: ((Error) -> Void)?
#if os(iOS)
    /// Fired when another app starts primary audio playback. The coordinator
    /// uses this to release the microphone instead of keeping a mixed voice
    /// session alive underneath the system audio.
    var onSystemAudioPlaybackStarted: (() -> Void)?
#endif

    var elapsed: TimeInterval { sink.elapsed }
    var recordedData: Data { sink.snapshot() }
    var latestLevel: Float { sink.latestLevel }
    var isRecoveringInput: Bool { isRecovering }
    var isCapturing: Bool { sink.isActivelyRecording }

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )
    }

    func startSession() async throws {
        guard !sessionActive else { return }
        guard let targetFormat else {
            throw RecorderError.invalidTargetFormat
        }

        sink.configure(targetFormat: targetFormat)
        // Install once for the whole start attempt. sessionActive stays false until
        // attach succeeds, so engine-config callbacks cannot rebuild mid-start.
        installObservers()

        var lastError: Error?
        for attempt in 1...maxRecoveryAttempts {
            do {
#if os(iOS)
                // Re-assert category on every attempt so a mid-start route change
                // (wired headset / AirPods HFP) can settle into the session.
                try configureAudioSession()
                // First attempt can be light; later attempts full-recycle the session.
                try await waitForInputRouteToSettle(fullRecycle: attempt > 1)
#endif
                teardownEngine()
                try attachEngine()
                sessionActive = true
                isInputReady = true
                recoveryAttempts = 0
                publishInputName(resolveInputName())
#if os(iOS)
                startSystemAudioMonitor()
#endif
                return
            } catch {
                lastError = error
                // An input AudioUnit which failed to start is not reliably
                // reusable after an HFP route transition. Reset it and release
                // the session before trying again.
                teardownEngine()
#if os(iOS)
                deactivateAudioSessionForRetry()
#endif
                if attempt < maxRecoveryAttempts {
                    try? await Task.sleep(nanoseconds: recoveryDelay(for: attempt))
                }
            }
        }

        removeObservers()
        isInputReady = false
        recoveryAttempts = 0
        throw lastError ?? RecorderError.noInput
    }

    func stopSession() {
        recoveryTask?.cancel()
        recoveryTask = nil
        removeObservers()
        teardownEngine()
        sessionActive = false
        isRecovering = false
        isInputReady = false
        recoveryAttempts = 0
        sink.cancelRecording()
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
#endif
    }

    func beginRecording() {
        sink.beginRecording()
    }

    /// Reconcile stale recovery flags when the user actually requests capture.
    /// Never force a synchronous rebuild: route transitions need an async settle
    /// window, and a rushed `engine.start()` is a common source of -10868.
    func ensureInputReadyForRecording() -> Bool {
        guard sessionActive else { return false }
        if isRecovering {
            return false
        }

        if hasUsableRunningEngine() {
            recoveryTask?.cancel()
            recoveryTask = nil
            recoveryAttempts = 0
            isRecovering = false
            isInputReady = true
            return true
        }

        scheduleRebuild(reason: "recording-demand")
        return false
    }

    func finishRecording() -> Data {
        sink.finishRecording()
    }

    func cancelRecording() {
        sink.cancelRecording()
    }

    // MARK: - Engine lifecycle

#if os(iOS)
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Explicit HFP so AirPods / BT headsets can provide microphone input.
        // Do not force a preferred sample rate — convert from the live route format.
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers]
        )
        try session.setActive(true, options: [])
        guard session.isInputAvailable else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw RecorderError.noInput
        }
    }

    /// Release a partially activated route between failed start attempts.
    /// In particular, this lets iOS finish promoting a Bluetooth device from
    /// its playback profile to HFP before AVAudioEngine opens the input unit.
    private func deactivateAudioSessionForRetry() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [])
    }

    /// Bluetooth connect/disconnect promotion is asynchronous. Wait until the
    /// session reports an available input route before opening the input unit.
    private func waitForInputRouteToSettle(fullRecycle: Bool = false) async throws {
        if fullRecycle {
            // Drop the previous HFP/built-in binding entirely, then reactivate.
            deactivateAudioSessionForRetry()
            try await Task.sleep(nanoseconds: postDeactivateSettleNanoseconds)
            try configureAudioSession()
        }
        try await Task.sleep(nanoseconds: activationSettleNanoseconds)
        try await waitUntilRouteLooksUsable()
    }

    /// Poll until iOS surfaces at least one input port after activation.
    private func waitUntilRouteLooksUsable() async throws {
        let session = AVAudioSession.sharedInstance()
        let maxAttempts = Int(routeUsableMaxWaitNanoseconds / max(routeUsablePollNanoseconds, 1))
        for attempt in 0..<max(maxAttempts, 1) {
            if Task.isCancelled { throw CancellationError() }
            if session.isInputAvailable, !session.currentRoute.inputs.isEmpty {
                return
            }
            if attempt + 1 < maxAttempts {
                try await Task.sleep(nanoseconds: routeUsablePollNanoseconds)
            }
        }
        guard session.isInputAvailable else {
            throw RecorderError.noInput
        }
        // Input available but route ports still empty — let attachEngine probe formats.
    }

    private func shouldFullRecycleSession(for reason: String) -> Bool {
        if reason.hasPrefix("retry-") {
            // Escalating retries: full recycle from the 2nd retry onward.
            return recoveryAttempts >= 2
        }
        if reason.hasPrefix("route-") || reason == "media-reset" || reason == "recording-demand" {
            return true
        }
        if reason.hasPrefix("interruption-") {
            return true
        }
        return false
    }
#endif

    private func attachEngine() throws {
        guard targetFormat != nil else {
            throw RecorderError.invalidTargetFormat
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        let usableFormat: AVAudioFormat
        if inputFormat.sampleRate.isFinite,
           inputFormat.sampleRate > 0,
           inputFormat.channelCount > 0 {
            usableFormat = inputFormat
        } else {
            let outputFormat = input.outputFormat(forBus: 0)
            guard outputFormat.sampleRate.isFinite,
                  outputFormat.sampleRate > 0,
                  outputFormat.channelCount > 0 else {
#if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
#endif
                throw RecorderError.noInput
            }
            usableFormat = outputFormat
        }
        _ = usableFormat

        // Do not pass the hardware format to installTap. On newer iPhones the
        // route can still be settling immediately after setActive(), and a
        // stale/mismatched format makes AVAudioEngine terminate the process
        // instead of returning a Swift error. nil asks the engine to use the
        // current input format; the sink creates its converter from the first
        // buffer's actual format.
        sink.prepareForEngineAttach()
        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0,
            bufferSize: 2048,
            format: nil,
            block: makeAudioTapBlock(for: sink)
        )

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func teardownEngine() {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        // `stop()` alone can retain the previous route's input AudioUnit and format state.
        // Recreating AVAudioEngine is required to release stale hardware AU context
        // and attach to newly activated route format, preventing AVFAudio error -10868.
        engine.reset()
        engine = AVAudioEngine()
        sink.prepareForEngineAttach()
    }

    private func recoveryDelay(for attempt: Int) -> UInt64 {
        AudioRouteRecoveryPolicy.retryDelayNanoseconds(
            attempt: attempt,
            baseDelayNanoseconds: settleNanoseconds
        )
    }

    private func hasUsableRunningEngine() -> Bool {
        guard engine.isRunning else { return false }
        let format = engine.inputNode.inputFormat(forBus: 0)
        return format.sampleRate.isFinite
            && format.sampleRate > 0
            && format.channelCount > 0
    }

    /// Immediately mark input unusable and drop any live capture so a later
    /// async rebuild cannot splice two devices into one segment.
    private func beginRecoveryIfNeeded(cancelCapture: Bool) {
        if cancelCapture, sink.isActivelyRecording {
            onCaptureInterruptedByRouteChange?()
            sink.cancelRecording()
        }
        if !isRecovering {
            isRecovering = true
            isInputReady = false
            onInputRecoveryStarted?()
        } else {
            isInputReady = false
        }
    }

    /// Release the previous input AudioUnit before the settle delay so the next
    /// attach binds to the post-transition route instead of a stale HFP unit.
    private func releaseEngineForRouteTransition() {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
        engine = AVAudioEngine()
        sink.prepareForEngineAttach()
    }

    private func rebuildEngine(reason: String) async {
        guard sessionActive else { return }
        guard !isApplyingRebuild else { return }

        beginRecoveryIfNeeded(cancelCapture: true)

        isApplyingRebuild = true
        defer { isApplyingRebuild = false }

        do {
#if os(iOS)
            let fullRecycle = shouldFullRecycleSession(for: reason)
            if fullRecycle {
                try await waitForInputRouteToSettle(fullRecycle: true)
            } else {
                try configureAudioSession()
                try await waitForInputRouteToSettle(fullRecycle: false)
            }
#endif
            teardownEngine()
            try attachEngine()
            guard hasUsableRunningEngine() else {
                throw RecorderError.routeRecoveryFailed
            }
            suppressEngineConfigUntil = Date().addingTimeInterval(1.5)
            recoveryAttempts = 0
            isRecovering = false
            isInputReady = true
            let name = resolveInputName()
            publishInputName(name)
            onInputRecoverySucceeded?(name)
        } catch is CancellationError {
            return
        } catch {
            recoveryAttempts += 1
#if os(iOS)
            deactivateAudioSessionForRetry()
#endif
            releaseEngineForRouteTransition()
            if recoveryAttempts < maxRecoveryAttempts {
                scheduleRebuild(reason: "retry-\(reason)-\(recoveryAttempts)")
            } else {
                isRecovering = false
                isInputReady = false
                onInputRecoveryFailed?(error)
                // Keep sessionActive so a later route event or user retry can recover.
            }
        }
    }

    private func scheduleRebuild(reason: String) {
        guard sessionActive else { return }
        // A brand-new device event gets a fresh retry budget; internal retries keep theirs.
        if !reason.hasPrefix("retry-") {
            recoveryAttempts = 0
        }

        // Fail closed immediately: do not keep a dead engine "ready" during settle.
        beginRecoveryIfNeeded(cancelCapture: true)
        if !reason.hasPrefix("retry-") {
            releaseEngineForRouteTransition()
        }

        recoveryTask?.cancel()
        let delay: UInt64
        if reason.hasPrefix("retry-") {
            delay = recoveryDelay(for: recoveryAttempts)
        } else if reason.hasPrefix("route-") || reason == "media-reset" {
            delay = routeChangeSettleNanoseconds
        } else if reason == "recording-demand" {
            // User is actively trying to talk; still wait briefly for Core Audio.
            delay = settleNanoseconds
        } else {
            delay = settleNanoseconds
        }
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, self.sessionActive else { return }
            await self.rebuildEngine(reason: reason)
        }
    }

    // MARK: - Observers

    private func installObservers() {
        removeObservers()

#if os(iOS)
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            // Extract Sendable payload before hopping to MainActor (Swift 6).
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                self?.handleRouteChange(reasonRawValue: reasonRaw)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                self?.handleInterruption(typeRawValue: typeRaw, optionsRawValue: optionsRaw)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let hintRaw = notification.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
            Task { @MainActor in
                self?.handleSilenceSecondaryAudioHint(hintRawValue: hintRaw)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRebuild(reason: "media-reset")
            }
        })
#endif

        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.sessionActive,
                      !self.isApplyingRebuild,
                      Date() >= self.suppressEngineConfigUntil else { return }
                self.scheduleRebuild(reason: "engine-config")
            }
        })

    }

    private func removeObservers() {
#if os(iOS)
        systemAudioMonitorTask?.cancel()
        systemAudioMonitorTask = nil
        wasOtherPrimaryAudioPlaying = false
#endif
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
    }

#if os(iOS)
    private func startSystemAudioMonitor() {
        systemAudioMonitorTask?.cancel()
        wasOtherPrimaryAudioPlaying = false
        systemAudioMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.sessionActive {
                let otherAudioPlaying = AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint
                if otherAudioPlaying, !self.wasOtherPrimaryAudioPlaying {
                    self.onSystemAudioPlaybackStarted?()
                    return
                }
                self.wasOtherPrimaryAudioPlaying = otherAudioPlaying
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func handleRouteChange(reasonRawValue: UInt?) {
        guard sessionActive, !isApplyingRebuild else { return }
        let reason = reasonRawValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))

        switch reason {
        case .some(.newDeviceAvailable),
             .some(.oldDeviceUnavailable),
             .some(.override),
             .some(.routeConfigurationChange):
            scheduleRebuild(reason: "route-\(reason?.rawValue ?? 0)")
        case .some(.categoryChange):
            guard Date() >= suppressEngineConfigUntil else { return }
            scheduleRebuild(reason: "route-\(reason?.rawValue ?? 0)")
        case .some(.unknown), .none:
            // Still refresh the displayed name; rebuild if formats look dead.
            let name = resolveInputName()
            if name != currentInputName {
                publishInputName(name)
            }
            let format = engine.inputNode.inputFormat(forBus: 0)
            if !(format.sampleRate.isFinite && format.sampleRate > 0 && format.channelCount > 0) {
                scheduleRebuild(reason: "route-invalid-format")
            }
        default:
            let name = resolveInputName()
            if name != currentInputName {
                publishInputName(name)
            }
        }
    }

    private func handleInterruption(typeRawValue: UInt?, optionsRawValue: UInt?) {
        guard sessionActive else { return }
        guard let typeRawValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeRawValue) else {
            return
        }
        switch type {
        case .began:
            // Calls, Siri and media playback can all begin as an interruption.
            // The product contract is to release the microphone immediately;
            // do not leave a paused voice session waiting to resume underneath.
            onSystemAudioPlaybackStarted?()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRawValue ?? 0)
            if options.contains(.shouldResume) {
                scheduleRebuild(reason: "interruption-ended")
            } else {
                // Still attempt recovery; user may want to record after the call.
                scheduleRebuild(reason: "interruption-ended-no-flag")
            }
        @unknown default:
            scheduleRebuild(reason: "interruption-unknown")
        }
    }

    private func handleSilenceSecondaryAudioHint(hintRawValue: UInt?) {
        guard sessionActive,
              let hintRawValue,
              AVAudioSession.SilenceSecondaryAudioHintType(rawValue: hintRawValue) == .begin
        else { return }
        onSystemAudioPlaybackStarted?()
    }
#endif

    // MARK: - Input naming

    private func publishInputName(_ name: String) {
        guard name != currentInputName else { return }
        currentInputName = name
        onInputNameChange?(name)
    }

    private func resolveInputName() -> String {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        if let port = inputs.first {
            return friendlyInputName(portPortName: port.portName, portType: port.portType)
        }
        return "麦克风"
    }

    private func friendlyInputName(portPortName: String, portType: AVAudioSession.Port) -> String {
        switch portType {
        case .builtInMic:
            return "iPhone 麦克风"
        case .headsetMic:
            return portPortName.isEmpty ? "有线耳机麦克风" : "\(portPortName) 麦克风"
        case .bluetoothHFP:
            // AirPods typically surface as "AirPods" / "某某的 AirPods".
            if portPortName.isEmpty { return "蓝牙耳机麦克风" }
            if portPortName.localizedCaseInsensitiveContains("麦克风") {
                return portPortName
            }
            return "\(portPortName) 麦克风"
        case .bluetoothLE:
            return portPortName.isEmpty ? "蓝牙麦克风" : "\(portPortName) 麦克风"
        case .usbAudio:
            return portPortName.isEmpty ? "USB 麦克风" : portPortName
        default:
            return portPortName.isEmpty ? "麦克风" : portPortName
        }
    }
}

/// Build the callback outside the @MainActor-isolated AudioRecorder type.
/// AVAudioEngine executes this closure on its realtime dispatch queue.
private func makeAudioTapBlock(for sink: AudioCaptureSink) -> AVAudioNodeTapBlock {
    { buffer, _ in
        sink.ingest(buffer)
    }
}

/// Thread-safe capture sink used from the AVAudioEngine realtime callback.
final class AudioCaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var lastInputFormatKey: String?
    private var audioBuffer = Data()
    private var isRecording = false
    private var startDate: Date?
    private(set) var latestLevel: Float = 0

    /// True while `beginRecording()` has opened a capture window.
    var isActivelyRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRecording
    }

    var elapsed: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        if let startDate { return Date().timeIntervalSince(startDate) }
        return TimeInterval(audioBuffer.count) / 32_000.0
    }

    func configure(targetFormat: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        self.targetFormat = targetFormat
        // The input format is route-dependent and may change while the audio
        // session is activating. It is intentionally created lazily from the
        // first buffer received by the tap.
        self.converter = nil
        self.lastInputFormatKey = nil
    }

    /// Drop the converter so the next buffer rebuilds against a new route format.
    func prepareForEngineAttach() {
        lock.lock()
        defer { lock.unlock() }
        converter = nil
        lastInputFormatKey = nil
    }

    func beginRecording() {
        lock.lock()
        defer { lock.unlock() }
        audioBuffer.removeAll(keepingCapacity: true)
        isRecording = true
        startDate = Date()
        latestLevel = 0
    }

    func finishRecording() -> Data {
        lock.lock()
        defer { lock.unlock() }
        isRecording = false
        startDate = nil
        let data = audioBuffer
        audioBuffer = Data()
        latestLevel = 0
        return data
    }

    func cancelRecording() {
        lock.lock()
        defer { lock.unlock() }
        isRecording = false
        startDate = nil
        audioBuffer.removeAll(keepingCapacity: true)
        latestLevel = 0
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return audioBuffer
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording, let targetFormat else { return }

        let formatKey = Self.formatKey(for: buffer.format)
        if converter == nil || lastInputFormatKey != formatKey {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            lastInputFormatKey = formatKey
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, converted.frameLength > 0 else { return }

        let frameCount = Int(converted.frameLength)
        if let channel = converted.int16ChannelData {
            let ptr = channel[0]
            audioBuffer.append(UnsafeBufferPointer(start: ptr, count: frameCount))
            latestLevel = AudioPeakMeter.normalizedPeak(samples: ptr, count: frameCount)
        }
    }

    private static func formatKey(for format: AVAudioFormat) -> String {
        "\(format.commonFormat.rawValue)|\(format.sampleRate)|\(format.channelCount)|\(format.isInterleaved)"
    }
}

/// Peak meter helpers shared with unit tests (Int16.min-safe).
enum AudioPeakMeter {
    static func normalizedPeak(samples: UnsafePointer<Int16>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var peak: Int32 = 0
        for i in 0..<count {
            let magnitude = abs(Int32(samples[i]))
            if magnitude > peak { peak = magnitude }
        }
        // Int16.min has magnitude 32768, one above Int16.max — clamp to 1.
        return min(Float(peak) / Float(Int16.max), 1.0)
    }

    static func normalizedPeak(samples: [Int16]) -> Float {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return normalizedPeak(samples: base, count: buffer.count)
        }
    }
}

/// Pure policy helpers for route-change behavior (unit-tested).
enum AudioRouteRecoveryPolicy {
    /// Mid-capture route changes discard the current segment; never splice devices.
    static func shouldCancelActiveCapture(isRecording: Bool) -> Bool {
        isRecording
    }

    /// While recovering, refuse a new hold-to-talk start.
    static func shouldRejectStart(isRecovering: Bool, isInputReady: Bool) -> Bool {
        isRecovering || !isInputReady
    }

    static func canRetry(attempt: Int, maxAttempts: Int) -> Bool {
        attempt < maxAttempts
    }

    /// Capped exponential backoff gives iOS time to finish a headset/HFP route
    /// promotion instead of repeatedly reopening the same unavailable unit.
    static func retryDelayNanoseconds(attempt: Int, baseDelayNanoseconds: UInt64) -> UInt64 {
        // attempt 1 → 1x, 2 → 2x, 3 → 4x, 4+ → 8x (capped) of base settle.
        let exponent = min(max(attempt - 1, 0), 3)
        return baseDelayNanoseconds * UInt64(1 << exponent)
    }
}

enum RecorderError: LocalizedError {
    case noInput
    case invalidTargetFormat
    case routeRecoveryFailed

    var errorDescription: String? {
        switch self {
        case .noInput:
            return "无法获取麦克风输入"
        case .invalidTargetFormat:
            return "无法创建录音格式"
        case .routeRecoveryFailed:
            return "麦克风切换后暂不可用，请稍后再试"
        }
    }
}


enum MicrophonePermission {
    static func request() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
