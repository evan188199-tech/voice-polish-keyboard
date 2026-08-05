import AVFoundation
#if os(macOS)
import CoreAudio
import AudioToolbox
#endif

/// Platform audio capture. iOS configures AVAudioSession; macOS uses AVAudioEngine only.
/// PCM is discarded unless the coordinator calls `beginRecording()`.
///
/// Follows the system default input (including AirPods HFP). On route/device
/// changes the engine is rebuilt after a short settle delay so capture can recover.
@MainActor
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat?
    private let sink = AudioCaptureSink()
    private var sessionActive = false
    private var isRecovering = false
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    private let maxRecoveryAttempts = 3
    private let settleNanoseconds: UInt64 = 250_000_000
    private var observers: [NSObjectProtocol] = []
    /// Suppresses observer-driven rebuilds while we are already rebuilding.
    private var isApplyingRebuild = false
    /// Rebuild operations emit their own configuration notifications after the
    /// synchronous guard has cleared. Suppress that echo to avoid a loop.
    private var suppressEngineConfigUntil = Date.distantPast
#if os(macOS)
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
#endif

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

    func startSession() throws {
        guard !sessionActive else { return }
        guard let targetFormat else {
            throw RecorderError.invalidTargetFormat
        }
#if os(iOS)
        try configureAudioSession()
#endif
        sink.configure(targetFormat: targetFormat)
        try attachEngine()
        installObservers()
        sessionActive = true
        isInputReady = true
        recoveryAttempts = 0
        publishInputName(resolveInputName())
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
    func ensureInputReadyForRecording() -> Bool {
        guard sessionActive else { return false }

        let format = engine.inputNode.inputFormat(forBus: 0)
        let formatIsUsable = format.sampleRate.isFinite
            && format.sampleRate > 0
            && format.channelCount > 0
        if engine.isRunning, formatIsUsable {
            recoveryTask?.cancel()
            recoveryTask = nil
            recoveryAttempts = 0
            isRecovering = false
            isInputReady = true
            return true
        }

        recoveryTask?.cancel()
        recoveryTask = nil
        rebuildEngine(reason: "recording-demand")
        return engine.isRunning && isInputReady && !isRecovering
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
            mode: .measurement,
            options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers]
        )
        try session.setActive(true, options: [])
        guard session.isInputAvailable else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw RecorderError.noInput
        }
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
        sink.prepareForEngineAttach()
    }

    private func rebuildEngine(reason: String) {
        guard sessionActive else { return }
        guard !isApplyingRebuild else { return }

        let wasCapturing = sink.isActivelyRecording
        if wasCapturing {
            // Never splice audio from two devices into one segment.
            onCaptureInterruptedByRouteChange?()
            sink.cancelRecording()
        }

        if !isRecovering {
            isRecovering = true
            isInputReady = false
            onInputRecoveryStarted?()
        }

        isApplyingRebuild = true
        defer { isApplyingRebuild = false }

        do {
#if os(iOS)
            // Re-assert category so a newly connected HFP device can join.
            try configureAudioSession()
#endif
            teardownEngine()
            // Give Core Audio a beat to settle after stop before reinstalling the tap.
            try attachEngine()
            suppressEngineConfigUntil = Date().addingTimeInterval(1)
            recoveryAttempts = 0
            isRecovering = false
            isInputReady = true
            let name = resolveInputName()
            publishInputName(name)
            onInputRecoverySucceeded?(name)
        } catch {
            recoveryAttempts += 1
            if recoveryAttempts < maxRecoveryAttempts {
                scheduleRebuild(reason: "retry-\(reason)-\(recoveryAttempts)")
            } else {
                isRecovering = false
                isInputReady = false
                onInputRecoveryFailed?(error)
                // Keep sessionActive so a later route event can still recover.
            }
        }
    }

    private func scheduleRebuild(reason: String) {
        guard sessionActive else { return }
        // A brand-new device event gets a fresh retry budget; internal retries keep theirs.
        if !reason.hasPrefix("retry-") {
            recoveryAttempts = 0
        }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.settleNanoseconds)
            guard !Task.isCancelled, self.sessionActive else { return }
            self.rebuildEngine(reason: reason)
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
            object: engine,
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

#if os(macOS)
        installDefaultInputListener()
#endif
    }

    private func removeObservers() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
#if os(macOS)
        removeDefaultInputListener()
#endif
    }

#if os(iOS)
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
            if sink.isActivelyRecording {
                onCaptureInterruptedByRouteChange?()
                sink.cancelRecording()
            }
            isInputReady = false
            isRecovering = true
            onInputRecoveryStarted?()
            if engine.isRunning {
                engine.pause()
            }
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
#endif

#if os(macOS)
    private func installDefaultInputListener() {
        removeDefaultInputListener()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.scheduleRebuild(reason: "default-input")
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            defaultInputListenerBlock = block
        }
    }

    private func removeDefaultInputListener() {
        guard let block = defaultInputListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultInputListenerBlock = nil
    }
#endif

    // MARK: - Input naming

    private func publishInputName(_ name: String) {
        guard name != currentInputName else { return }
        currentInputName = name
        onInputNameChange?(name)
    }

    private func resolveInputName() -> String {
#if os(iOS)
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        if let port = inputs.first {
            return friendlyInputName(portPortName: port.portName, portType: port.portType)
        }
        return "麦克风"
#elseif os(macOS)
        return macDefaultInputName() ?? "麦克风"
#else
        return "麦克风"
#endif
    }

#if os(iOS)
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
#endif

#if os(macOS)
    private func macDefaultInputName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var name: CFString?
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, pointer)
        }
        guard nameStatus == noErr, let name else { return nil }
        let raw = name as String
        if raw.isEmpty { return nil }
        if raw.localizedCaseInsensitiveContains("麦克风") || raw.localizedCaseInsensitiveContains("Microphone") {
            return raw
        }
        // Built-in Mac mics often read "MacBook Pro Microphone" already.
        return raw
    }
#endif
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
            return "麦克风切换后恢复失败"
        }
    }
}


enum MicrophonePermission {
    static func request() async -> Bool {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #elseif os(macOS)
        return await AVCaptureDevice.requestAccess(for: .audio)
        #else
        return false
        #endif
    }
}
