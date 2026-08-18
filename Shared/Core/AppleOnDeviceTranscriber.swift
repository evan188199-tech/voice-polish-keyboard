#if os(iOS)
import Foundation
@preconcurrency import Speech

/// One system recognition hypothesis.  The recognizer ranks hypotheses in
/// descending likelihood; confidence is the mean available segment score.
struct AppleSpeechHypothesis: Sendable, Equatable {
    let text: String
    let confidence: Float
    let rank: Int
}

struct AppleSpeechCandidates: Sendable, Equatable {
    let hypotheses: [AppleSpeechHypothesis]
    let localeIdentifier: String?
}

/// Apple on-device `SFSpeechRecognizer` baseline for main-app A/B comparison.
/// Not used by keyboard/IME insert paths.
actor AppleOnDeviceTranscriber: SpeechTranscribing {
    private var recognizer: SFSpeechRecognizer?
    private(set) var resolvedLocaleIdentifier: String?
    private var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    let modelDisplayName = "系统听写 (on-device)"
    private(set) var downloadProgress: Double?
    private(set) var preparePhase: String?

    var isReady: Bool {
        recognizer != nil && authorizationStatus == .authorized
    }

    var hasModelFiles: Bool {
        // No bundle model; "present" means Speech framework can build a recognizer for a preferred locale.
        Self.pickLocale() != nil
    }

    var compareEngineDisplayName: String {
        AppleSpeechLocaleSelector.displayName(for: resolvedLocaleIdentifier)
    }

    func prepareModel() async throws {
        preparePhase = "loading"
        defer {
            preparePhase = nil
            downloadProgress = nil
        }

        let status = await Self.requestAuthorization()
        authorizationStatus = status
        switch status {
        case .authorized:
            break
        case .denied:
            throw AppleSpeechError.permissionDenied
        case .restricted:
            throw AppleSpeechError.permissionRestricted
        case .notDetermined:
            throw AppleSpeechError.permissionNotDetermined
        @unknown default:
            throw AppleSpeechError.permissionNotDetermined
        }

        guard let locale = Self.pickLocale() else {
            throw AppleSpeechError.noSupportedLocale
        }
        resolvedLocaleIdentifier = locale.identifier

        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw AppleSpeechError.recognizerUnavailable(locale.identifier)
        }
        guard recognizer.isAvailable else {
            throw AppleSpeechError.recognizerUnavailable(locale.identifier)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw AppleSpeechError.onDeviceUnavailable(locale.identifier)
        }

        self.recognizer = recognizer
    }

    func removeModelFiles() async throws {
        // System dictation owns its language pack; only release this comparison instance.
        recognizer = nil
        resolvedLocaleIdentifier = nil
    }

    func transcribe(_ pcmData: Data, vocabulary: String) async throws -> String {
        let candidates = try await transcribeCandidates(pcmData, vocabulary: vocabulary)
        guard let text = candidates.hypotheses.first?.text, !text.isEmpty else {
            throw TranscriberError.noText
        }
        return text
    }

    /// Return Apple Speech's ranked alternatives for A/B compare.
    func transcribeCandidates(_ pcmData: Data, vocabulary: String) async throws -> AppleSpeechCandidates {
        _ = vocabulary
        if recognizer == nil || authorizationStatus != .authorized {
            try await prepareModel()
        }
        guard let recognizer else { throw TranscriberError.notReady }
        guard !pcmData.isEmpty else { throw TranscriberError.noText }

        // Re-check on-device support at request time (language pack may change).
        guard recognizer.supportsOnDeviceRecognition else {
            throw AppleSpeechError.onDeviceUnavailable(resolvedLocaleIdentifier ?? "unknown")
        }

        let wavURL = try Self.writeTempWav(pcmInt16Mono: pcmData, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let request = SFSpeechURLRecognitionRequest(url: wavURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }

        let localeIdentifier = resolvedLocaleIdentifier
        return try await Self.recognizeCandidates(
            recognizer: recognizer,
            request: request,
            localeIdentifier: localeIdentifier
        )
    }

    /// Speech invokes its Objective-C result handler outside this actor's
    /// executor. Keep the callback in a nonisolated helper so Swift 6 does not
    /// inherit actor isolation and abort at callback entry.
    nonisolated private static func recognizeCandidates(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest,
        localeIdentifier: String?
    ) async throws -> AppleSpeechCandidates {
        try await withCheckedThrowingContinuation { continuation in
            var settled = false
            recognizer.recognitionTask(with: request) { result, error in
                if settled { return }
                if let error {
                    settled = true
                    continuation.resume(throwing: AppleSpeechError.recognitionFailed(error.localizedDescription))
                    return
                }
                guard let result else { return }
                if result.isFinal {
                    settled = true
                    let hypotheses = result.transcriptions.enumerated().compactMap { index, transcription -> AppleSpeechHypothesis? in
                        let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return nil }
                        let scores = transcription.segments.map(\.confidence).filter { $0.isFinite }
                        let confidence = scores.isEmpty ? 0 : scores.reduce(0, +) / Float(scores.count)
                        return AppleSpeechHypothesis(text: text, confidence: confidence, rank: index)
                    }
                    if hypotheses.isEmpty {
                        continuation.resume(throwing: TranscriberError.noText)
                    } else {
                        continuation.resume(returning: AppleSpeechCandidates(
                            hypotheses: hypotheses,
                            localeIdentifier: localeIdentifier
                        ))
                    }
                }
            }
        }
    }

    // MARK: - Locale / auth helpers

    nonisolated static func pickLocale(
        available: Set<Locale> = SFSpeechRecognizer.supportedLocales()
    ) -> Locale? {
        let ids = available.map(\.identifier)
        guard let preferred = AppleSpeechLocaleSelector.preferredLocaleIdentifier(from: ids) else {
            return nil
        }
        return available.first(where: { $0.identifier == preferred })
            ?? Locale(identifier: preferred)
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Wrap raw 16 kHz mono Int16 PCM in a minimal WAV container for URL recognition.
    nonisolated static func writeTempWav(pcmInt16Mono: Data, sampleRate: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpk-apple-asr-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmInt16Mono.count)
        let riffSize = UInt32(36) + dataSize

        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(contentsOf: withUnsafeBytes(of: riffSize.littleEndian, Array.init))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian, Array.init)) // PCM chunk size
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init)) // audio format PCM
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))
        header.append(contentsOf: Array("data".utf8))
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian, Array.init))

        try (header + pcmInt16Mono).write(to: url, options: .atomic)
        return url
    }
}


enum AppleSpeechError: LocalizedError {
    case permissionDenied
    case permissionRestricted
    case permissionNotDetermined
    case noSupportedLocale
    case recognizerUnavailable(String)
    case onDeviceUnavailable(String)
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "系统语音识别权限被拒绝"
        case .permissionRestricted:
            return "系统语音识别权限受限"
        case .permissionNotDetermined:
            return "系统语音识别权限未确定"
        case .noSupportedLocale:
            return "设备没有可用的系统听写语言包"
        case .recognizerUnavailable(let locale):
            return "系统听写在 locale \(locale) 上不可用"
        case .onDeviceUnavailable(let locale):
            return "系统听写端侧识别不可用（locale \(locale)）。请在「设置 > 通用 > 键盘 > 听写」下载语言包并开启离线听写。"
        case .recognitionFailed(let detail):
            return "系统听写失败: \(detail)"
        }
    }
}
#endif
