import Foundation

/// IDs of failures skipped by the processing cursor but not yet reported.
struct OrderedFailureIDs {
    private(set) var ids: [UUID] = []
    var first: UUID? { ids.first }
    func allows(_ id: UUID) -> Bool { first == nil || first == id }
    mutating func append(_ id: UUID) { if !ids.contains(id) { ids.append(id) } }
    mutating func remove(_ id: UUID) { ids.removeAll { $0 == id } }
    mutating func removeAll() { ids.removeAll() }
}

/// Tracks the next sequence number that may be delivered to clients.
/// Cloud jobs may finish out of order; insertion stays strictly sequential
/// within a single pipeline generation.
struct OrderedDeliveryCursor: Equatable, Sendable {
    private(set) var nextSequence: UInt64 = 1

    mutating func reset(to sequence: UInt64 = 1) {
        nextSequence = max(sequence, 1)
    }

    func canDeliver(sequence: UInt64) -> Bool {
        sequence == nextSequence
    }

    @discardableResult
    mutating func advance() -> UInt64 {
        let current = nextSequence
        nextSequence &+= 1
        return current
    }
}

/// Pure helpers for multi-job status copy.
enum VoiceJobStatusText {
    static func processingMessage(
        phase: VoiceJobPhase,
        polishMode: PolishMode,
        pendingCount: Int
    ) -> String {
        let base: String
        switch phase {
        case .queuedASR, .transcribing:
            base = "识别中…"
        case .queuedPolish, .polishing:
            base = polishMode.processingStatusMessage
        case .ready:
            base = "就绪"
        case .discarded:
            base = "已丢弃"
        case .failed:
            base = "处理失败"
        }
        if pendingCount > 1 {
            return "\(base) · 待处理 \(pendingCount) 段"
        }
        return base
    }
}

enum VoiceJobPhase: String, Equatable, Sendable {
    case queuedASR
    case transcribing
    case queuedPolish
    case polishing
    case ready
    case discarded
    case failed
}
