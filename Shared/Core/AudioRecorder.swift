import AVFoundation

/// Platform audio capture. iOS configures AVAudioSession; macOS uses AVAudioEngine only.
/// PCM is discarded unless the coordinator calls `beginRecording()`.
@MainActor
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat?
    private let sink = AudioCaptureSink()
    private var sessionActive = false

    var elapsed: TimeInterval { sink.elapsed }
    var recordedData: Data { sink.snapshot() }
    var latestLevel: Float { sink.latestLevel }

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
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers]
        )
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true, options: [])
        guard session.isInputAvailable else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw RecorderError.noInput
        }
#endif

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate.isFinite,
              inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0 else {
#if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
#endif
            throw RecorderError.noInput
        }

        // Do not pass the hardware format to installTap. On newer iPhones the
        // route can still be settling immediately after setActive(), and a
        // stale/mismatched format makes AVAudioEngine terminate the process
        // instead of returning a Swift error. nil asks the engine to use the
        // current input format; the sink creates its converter from the first
        // buffer's actual format.
        sink.configure(targetFormat: targetFormat)
        input.removeTap(onBus: 0)
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            sink.ingest(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
#if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
#endif
            throw error
        }
        sessionActive = true
    }

    func stopSession() {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        sessionActive = false
        sink.cancelRecording()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    func beginRecording() {
        sink.beginRecording()
    }

    func finishRecording() -> Data {
        sink.finishRecording()
    }

    func cancelRecording() {
        sink.cancelRecording()
    }
}

/// Thread-safe capture sink used from the AVAudioEngine realtime callback.
final class AudioCaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var audioBuffer = Data()
    private var isRecording = false
    private var startDate: Date?
    private(set) var latestLevel: Float = 0

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

        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
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

            var peak: Int16 = 0
            for i in 0..<frameCount {
                let v = abs(ptr[i])
                if v > peak { peak = v }
            }
            latestLevel = Float(peak) / Float(Int16.max)
        }
    }
}

enum RecorderError: LocalizedError {
    case noInput
    case invalidTargetFormat

    var errorDescription: String? {
        switch self {
        case .noInput:
            return "无法获取麦克风输入"
        case .invalidTargetFormat:
            return "无法创建录音格式"
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
