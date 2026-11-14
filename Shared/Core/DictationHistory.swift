import Foundation
import Combine

struct DictationHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let transcript: String
    let result: String?
    let mode: PolishMode
    let transcriptionLatencyMs: Int?
    let polishingLatencyMs: Int?
    let errorMessage: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        transcript: String,
        result: String?,
        mode: PolishMode,
        transcriptionLatencyMs: Int? = nil,
        polishingLatencyMs: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.transcript = transcript
        self.result = result
        self.mode = mode
        self.transcriptionLatencyMs = transcriptionLatencyMs
        self.polishingLatencyMs = polishingLatencyMs
        self.errorMessage = errorMessage
    }
}

@MainActor
final class DictationHistoryStore: ObservableObject {
    static let shared = DictationHistoryStore()
    private let key = "dictation_history_v1"
    private let schemaKey = "dictation_history_schema_version"
    private let limit = 100
    @Published private(set) var entries: [DictationHistoryEntry] = []

    struct Statistics: Equatable {
        let totalCount: Int
        let medianTranscriptionLatencyMs: Int?
        let medianPolishingLatencyMs: Int?
        let failureRate: Double
    }

    var statistics: Statistics {
        let asr = entries.compactMap(\.transcriptionLatencyMs).sorted()
        let polish = entries.compactMap(\.polishingLatencyMs).sorted()
        let failures = entries.filter { $0.errorMessage != nil }.count
        return Statistics(
            totalCount: entries.count,
            medianTranscriptionLatencyMs: median(asr),
            medianPolishingLatencyMs: median(polish),
            failureRate: entries.isEmpty ? 0 : Double(failures) / Double(entries.count)
        )
    }

    init(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([DictationHistoryEntry].self, from: data) {
            entries = decoded
        }
        defaults.set(1, forKey: schemaKey)
    }

    func append(_ entry: DictationHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        persist()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }
}
