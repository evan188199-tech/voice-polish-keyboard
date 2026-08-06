import Foundation
import SherpaOnnx

protocol SpeechTranscribing: Sendable {
    var isReady: Bool { get async }
    var hasModelFiles: Bool { get async }
    var modelDisplayName: String { get }
    var downloadProgress: Double? { get async }
    var preparePhase: String? { get async }
    func prepareModel() async throws
    /// Transcribe raw 16 kHz mono Int16 PCM. Long audio is VAD-chunked automatically.
    func transcribe(_ pcmData: Data, vocabulary: String) async throws -> String
}

// MARK: - sherpa-onnx SenseVoiceSmall INT8

actor SenseVoiceTranscriber: SpeechTranscribing {
    private var recognizer: SherpaOnnxOfflineRecognizer?
    /// Keep model path strings alive while the C API holds pointers during setup.
    private var retainedPaths: [String] = []
    private let modelDir: URL

    let modelDisplayName = AppConstants.senseVoiceModelDisplayName
    var isReady: Bool { recognizer != nil }
    var hasModelFiles: Bool {
        FileManager.default.fileExists(atPath: modelPath.path)
            && FileManager.default.fileExists(atPath: tokensPath.path)
    }
    private(set) var downloadProgress: Double?
    private(set) var preparePhase: String?

    init(modelDir: URL? = nil) {
        self.modelDir = modelDir ?? Self.defaultModelDirectory()
    }

    static func defaultModelDirectory() -> URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoicePolishKeyboard", isDirectory: true)
            .appendingPathComponent("SenseVoiceModels", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SenseVoiceModels", isDirectory: true)
        #endif
        return base.appendingPathComponent(AppConstants.senseVoiceModelName, isDirectory: true)
    }

    private var modelPath: URL { modelDir.appendingPathComponent("model.int8.onnx") }
    private var tokensPath: URL { modelDir.appendingPathComponent("tokens.txt") }

    func prepareModel() async throws {
        preparePhase = hasModelFiles ? "loading" : "downloading"
        if !hasModelFiles {
            try await downloadModel()
        } else {
            // Files already present (e.g. Mac-side seed). Still show indeterminate load.
            downloadProgress = nil
        }
        preparePhase = "loading"
        try loadRecognizer()
        preparePhase = nil
        downloadProgress = nil
    }

    func transcribe(_ pcmData: Data, vocabulary: String) async throws -> String {
        guard let recognizer else { throw TranscriberError.notReady }

        let samples = pcmToFloats(pcmData)
        guard !samples.isEmpty else { throw TranscriberError.noText }

        let duration = TimeInterval(samples.count) / 16_000.0
        let pieces: [[Float]]
        if duration > AppConstants.vadChunkThreshold {
            pieces = vadSplit(samples, sampleRate: 16_000)
        } else {
            pieces = [samples]
        }

        var texts: [String] = []
        for chunk in pieces where !chunk.isEmpty {
            // Respond to session teardown between VAD chunks. New recordings do not cancel older jobs.
            try Task.checkCancellation()
            // Optional vocabulary is applied after recognition via LocalTextProcessor.
            let result = recognizer.decode(samples: chunk, sampleRate: 16_000)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                texts.append(text)
            }
        }

        // Process each VAD chunk independently so spoken-letter collapsing
        // respects pause boundaries, then smart-join the cleaned segments.
        // Cloud polish later keeps LLM output as-is; this only shapes local ASR text.
        let joined = LocalTextProcessor.processSegments(texts, vocabulary: vocabulary)
        guard !joined.isEmpty else { throw TranscriberError.noText }
        return joined
    }

    // MARK: - Private

    private func loadRecognizer() throws {
        let modelFile = modelPath.path
        let tokensFile = tokensPath.path
        guard FileManager.default.fileExists(atPath: modelFile) else {
            throw TranscriberError.modelNotFound(modelFile)
        }
        guard FileManager.default.fileExists(atPath: tokensFile) else {
            throw TranscriberError.modelNotFound(tokensFile)
        }

        retainedPaths = [modelFile, tokensFile]

        // Empty language => auto detect among zh / en / ja / yue / ko.
        let senseVoice = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: modelFile,
            language: "",
            useInverseTextNormalization: true
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokensFile,
            numThreads: 2,
            provider: "cpu",
            debug: 0,
            senseVoice: senseVoice
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            decodingMethod: "greedy_search"
        )
        recognizer = SherpaOnnxOfflineRecognizer(config: &config)
    }

    private func downloadModel() async throws {
        preparePhase = "downloading"
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        // tokens first (tiny), then the large INT8 model (~230MB).
        let files: [(name: String, weight: Double)] = [
            ("tokens.txt", 0.02),
            ("model.int8.onnx", 0.98)
        ]
        var completedWeight = 0.0
        for (name, weight) in files {
            guard let url = URL(string: "\(AppConstants.senseVoiceHFBase)/\(name)") else {
                throw TranscriberError.downloadFailed(name)
            }
            let dest = modelDir.appendingPathComponent(name)
            downloadProgress = completedWeight

            let delegate = ProgressDownloadDelegate { [completedWeight, weight] fraction in
                Task { await self.setProgress(completedWeight + fraction * weight) }
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            do {
                let tempURL: URL = try await withCheckedThrowingContinuation { cont in
                    delegate.completion = cont
                    session.downloadTask(with: url).resume()
                }
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tempURL, to: dest)
                session.finishTasksAndInvalidate()
                completedWeight += weight
                downloadProgress = completedWeight
            } catch {
                session.invalidateAndCancel()
                throw TranscriberError.downloadFailed("\(name): \(error.localizedDescription)")
            }
        }
        downloadProgress = nil
    }

    private func setProgress(_ value: Double) {
        downloadProgress = min(max(value, 0), 1)
    }

    private func pcmToFloats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> [Float] in
            let count = ptr.count / MemoryLayout<Int16>.stride
            guard count > 0, let base = ptr.bindMemory(to: Int16.self).baseAddress else { return [] }
            var out = [Float](repeating: 0, count: count)
            for i in 0..<count {
                out[i] = Float(base[i]) / 32768.0
            }
            return out
        }
    }

    /// Simple energy-based VAD: split at silence gaps.
    private func vadSplit(_ samples: [Float], sampleRate: Int) -> [[Float]] {
        let silenceSamples = Int(AppConstants.vadSilenceThreshold * Double(sampleRate))
        let energyFloor = AppConstants.vadEnergyFloor
        var chunks: [[Float]] = []
        var current: [Float] = []
        var silentCount = 0

        for sample in samples {
            if abs(sample) > energyFloor {
                if silentCount >= silenceSamples && !current.isEmpty {
                    chunks.append(current)
                    current = []
                }
                silentCount = 0
                current.append(sample)
            } else {
                silentCount += 1
                if silentCount < silenceSamples {
                    current.append(sample)
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [samples] : chunks
    }
}

enum TranscriberError: LocalizedError {
    case modelNotFound(String)
    case notReady
    case noText
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path): return "模型未找到: \(path)"
        case .notReady: return "语音识别模型尚未就绪"
        case .noText: return "未识别到语音内容"
        case .downloadFailed(let detail): return "模型文件下载失败: \(detail)"
        }
    }
}


// MARK: - Streaming download with progress

private final class ProgressDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var completion: CheckedContinuation<URL, Error>?
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("download")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            completion?.resume(returning: dest)
        } catch {
            completion?.resume(throwing: error)
        }
        completion = nil
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completion?.resume(throwing: error)
            completion = nil
        }
    }
}
