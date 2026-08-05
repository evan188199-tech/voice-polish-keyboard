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

    func transcribe(_ pcmData: Data, vocabulary: String) async throws -> String {
        let candidates = try await transcribeCandidates(pcmData, vocabulary: vocabulary)
        guard let text = candidates.hypotheses.first?.text, !text.isEmpty else {
            throw TranscriberError.noText
        }
        return text
    }

    /// Return Apple Speech's ranked alternatives for candidate review.
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

/// Builds small, non-overlapping replacement groups from whole-utterance
/// hypotheses.  It is deliberately conservative: punctuation-only edits and
/// insertions/deletions are not surfaced as uncertain words.
enum VoiceCandidateBuilder {
    static func makeDraft(source: String, hypotheses: [AppleSpeechHypothesis]) -> VoiceDraft? {
        let sourceUnits = Array(source.utf16)
        guard !sourceUnits.isEmpty else { return nil }

        var alternativesByRange: [UTF16TextRange: [(text: String, score: Float)]] = [:]
        for hypothesis in hypotheses.prefix(5) {
            let units = Array(hypothesis.text.utf16)
            for edit in edits(from: sourceUnits, to: units) {
                guard edit.sourceRange.length > 0, !edit.replacement.isEmpty else { continue }
                let original = substring(source, range: edit.sourceRange) ?? ""
                guard isMeaningful(original), isMeaningful(edit.replacement), original != edit.replacement else { continue }
                let score = Float(5 - hypothesis.rank) + hypothesis.confidence
                alternativesByRange[edit.sourceRange, default: []].append((edit.replacement, score))
            }
        }

        var groups: [CandidateGroup] = []
        for (range, candidates) in alternativesByRange {
            var scores: [String: Float] = [:]
            for candidate in candidates {
                scores[candidate.text] = max(scores[candidate.text] ?? -.infinity, candidate.score)
            }
            let ordered = scores.sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            let alternatives = ordered.prefix(4).map { $0.key }
            if !alternatives.isEmpty {
                groups.append(CandidateGroup(
                    range: range,
                    original: substring(source, range: range) ?? "",
                    alternatives: alternatives
                ))
            }
        }
        groups.sort { lhs, rhs in
            lhs.range.location == rhs.range.location
                ? lhs.range.length < rhs.range.length
                : lhs.range.location < rhs.range.location
        }

        var nonOverlapping: [CandidateGroup] = []
        for group in groups where nonOverlapping.count < 3 {
            let overlaps = nonOverlapping.contains { existing in
                let end = group.range.location + group.range.length
                let existingEnd = existing.range.location + existing.range.length
                return group.range.location < existingEnd && existing.range.location < end
            }
            if !overlaps { nonOverlapping.append(group) }
        }
        guard !nonOverlapping.isEmpty else { return nil }
        return VoiceDraft(id: UUID(), text: source, candidateGroups: nonOverlapping)
    }

    private struct Edit {
        let sourceRange: UTF16TextRange
        let replacement: String
    }

    /// LCS edit hunks. Dictation snippets are bounded by the recording limit;
    /// the cap prevents pathological work on a pasted or malformed result.
    private static func edits(from source: [UInt16], to target: [UInt16]) -> [Edit] {
        guard source.count <= 360, target.count <= 360 else { return [] }
        let rows = source.count + 1
        let cols = target.count + 1
        var table = Array(repeating: 0, count: rows * cols)
        for i in stride(from: source.count - 1, through: 0, by: -1) {
            for j in stride(from: target.count - 1, through: 0, by: -1) {
                table[i * cols + j] = source[i] == target[j]
                    ? table[(i + 1) * cols + j + 1] + 1
                    : max(table[(i + 1) * cols + j], table[i * cols + j + 1])
            }
        }

        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < source.count, j < target.count {
            if source[i] == target[j] {
                pairs.append((i, j)); i += 1; j += 1
            } else if table[(i + 1) * cols + j] >= table[i * cols + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        var edits: [Edit] = []
        var sourceStart = 0
        var targetStart = 0
        for pair in pairs + [(source.count, target.count)] {
            if pair.0 > sourceStart || pair.1 > targetStart {
                let replacement = String(decoding: target[targetStart..<pair.1], as: UTF16.self)
                edits.append(Edit(
                    sourceRange: UTF16TextRange(location: sourceStart, length: pair.0 - sourceStart),
                    replacement: replacement
                ))
            }
            sourceStart = pair.0 + 1
            targetStart = pair.1 + 1
        }
        return edits
    }

    private static func substring(_ text: String, range: UTF16TextRange) -> String? {
        let utf16Count = text.utf16.count
        guard range.location <= utf16Count,
              range.length <= utf16Count - range.location else { return nil }
        let start = String.Index(utf16Offset: range.location, in: text)
        let end = String.Index(utf16Offset: range.location + range.length, in: text)
        guard start <= end else { return nil }
        return String(text[start..<end])
    }

    private static func isMeaningful(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar) || (scalar.value >= 0x3400 && scalar.value <= 0x9FFF)
        }
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
