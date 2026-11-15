import Foundation

enum AppConstants {
    static let protocolVersion: UInt16 = 3
    static let bridgePorts: [UInt16] = [52741, 52742, 52743]
    static let polishingTimeout: TimeInterval = 8
    /// One short pause before the single automatic timeout retry.
    static let polishingRetryDelayNanoseconds: UInt64 = 300_000_000
    /// Short timeout used by settings "test model" probe.
    static let polishingProbeTimeout: TimeInterval = 5
    static let buildTokenSalt: String = "vpk.loopback.2026"

    /// Local SenseVoice jobs run strictly FIFO.
    static let localASRConcurrency = 1
    /// Cloud polish jobs may run in parallel up to this limit.
    static let cloudPolishConcurrency = 2
    /// Default maximum recording duration (seconds).
    static let defaultMaxRecordingDuration: TimeInterval = 60
    /// Hard cap: user may configure up to this value.
    static let absoluteMaxRecordingDuration: TimeInterval = 90

    /// iOS: auto-deactivate voice session after this much idle time (no hold-to-talk).
    static let defaultSessionIdleTimeoutSeconds: TimeInterval = 600
    /// Minimum / maximum configurable idle timeout.
    static let minimumSessionIdleTimeoutSeconds: TimeInterval = 60
    static let absoluteMaxSessionIdleTimeoutSeconds: TimeInterval = 1800

    /// Recordings longer than this use VAD chunking.
    static let vadChunkThreshold: TimeInterval = 25
    /// Silence duration (seconds) that marks a chunk boundary.
    static let vadSilenceThreshold: TimeInterval = 0.5
    /// RMS energy floor for speech (normalized float 0-1).
    static let vadEnergyFloor: Float = 0.01

    static let senseVoiceModelName: String = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"
    static let senseVoiceModelDisplayName: String = "SenseVoiceSmall INT8 (zh/en/ja/ko/yue, ~230 MB)"
    // Pinned to the upstream release commit; changing the model requires updating both digests.
    static let senseVoiceModelSHA256 = "12ca1a2ae7ecf3e0019ef2822307ee0b5cadc9196569e379b4c4026f8205276d"
    static let senseVoiceTokensSHA256 = "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"
    static let senseVoiceHFBase: String =
        "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/resolve/355f4d4884d8afd08aef04b9007a8556d7b463b2"
}
