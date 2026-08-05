import Foundation

enum AppConstants {
    static let protocolVersion: UInt16 = 2
    static let bridgePorts: [UInt16] = [52741, 52742, 52743]
    static let polishingTimeout: TimeInterval = 8
    /// Short timeout used by settings "test model" probe.
    static let polishingProbeTimeout: TimeInterval = 5
    static let buildTokenSalt: String = "vpk.loopback.2026"

    /// Local SenseVoice jobs run strictly FIFO.
    static let localASRConcurrency = 1
    /// Cloud polish jobs may run in parallel up to this limit.
    static let cloudPolishConcurrency = 2
    /// Candidate recognition may lag the primary local ASR, but must never make
    /// an ordinary dictation wait indefinitely.
    static let candidateRecognitionGracePeriod: TimeInterval = 1.5

    /// Default maximum recording duration (seconds).
    static let defaultMaxRecordingDuration: TimeInterval = 60
    /// Hard cap: user may configure up to this value.
    static let absoluteMaxRecordingDuration: TimeInterval = 90

    /// Recordings longer than this use VAD chunking.
    static let vadChunkThreshold: TimeInterval = 25
    /// Silence duration (seconds) that marks a chunk boundary.
    static let vadSilenceThreshold: TimeInterval = 0.5
    /// RMS energy floor for speech (normalized float 0-1).
    static let vadEnergyFloor: Float = 0.01

    static let senseVoiceModelName: String = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"
    static let senseVoiceModelDisplayName: String = "SenseVoiceSmall INT8 (zh/en/ja/ko/yue, ~230 MB)"
    static let senseVoiceHFBase: String =
        "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/resolve/main"
}
