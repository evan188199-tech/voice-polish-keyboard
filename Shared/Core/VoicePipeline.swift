import Foundation

/// Stable lifecycle exposed by the iOS pipeline and bridge diagnostics.
enum VoicePipelinePhase: String, Codable, Sendable, CaseIterable {
    case queued
    case recording
    case transcribing
    case polishing
    case delivering
    case completed
    case failed
    case cancelled
}

/// A privacy-safe public view of a voice task. Audio and recognised text never
/// live in this value, so it is safe to log and pass over the local bridge.
struct VoicePipelineJob: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let sequence: UInt64
    var phase: VoicePipelinePhase
    let createdAt: Date
    var recordingDurationMs: Int?
    var transcriptionLatencyMs: Int?
    var polishingLatencyMs: Int?
    var errorCode: BridgeErrorCode?
}

enum PipelineDiagnostics {
    private static let key = "pipeline_diagnostics_v1"
    private static let limit = 100

    struct Event: Codable, Identifiable, Sendable {
        let id: UUID
        let timestamp: Date
        let jobID: UUID?
        let phase: VoicePipelinePhase
        let elapsedMs: Int?
        let errorCode: BridgeErrorCode?
    }

    static func record(
        jobID: UUID?,
        phase: VoicePipelinePhase,
        elapsedMs: Int? = nil,
        errorCode: BridgeErrorCode? = nil,
        defaults: UserDefaults = .standard
    ) {
        var events = load(defaults: defaults)
        events.insert(
            Event(id: UUID(), timestamp: Date(), jobID: jobID, phase: phase, elapsedMs: elapsedMs, errorCode: errorCode),
            at: 0
        )
        if events.count > limit { events.removeLast(events.count - limit) }
        if let data = try? JSONEncoder().encode(events) { defaults.set(data, forKey: key) }
    }

    static func load(defaults: UserDefaults = .standard) -> [Event] {
        guard let data = defaults.data(forKey: key),
              let events = try? JSONDecoder().decode([Event].self, from: data) else { return [] }
        return events
    }
}

/// Fixed, content-free breadcrumbs for diagnosing the local voice path.
enum VoiceDiagnosticStage: String, CaseIterable {
    case micRequested, micGranted, micDenied
    case modelMissing, modelLoading, modelReady, modelFailed
    case audioStarting, audioReady, audioFailed
    case bridgeStartRequested, bridgeStartReceived
    case captureStarted, captureEmpty, captureNonempty
    case inferenceStarted, inferenceSucceeded, inferenceFailed
}

enum VoiceStageDiagnostics {
    private static let key = "voice_stage_diagnostics_v1"
    private static let limit = 40

    static func record(_ stage: VoiceDiagnosticStage, defaults: UserDefaults = .standard) {
        var stages = defaults.stringArray(forKey: key) ?? []
        stages.append(stage.rawValue)
        defaults.set(Array(stages.suffix(limit)), forKey: key)
    }

    static func load(defaults: UserDefaults = .standard) -> [VoiceDiagnosticStage] {
        (defaults.stringArray(forKey: key) ?? []).compactMap(VoiceDiagnosticStage.init(rawValue:))
    }
}
