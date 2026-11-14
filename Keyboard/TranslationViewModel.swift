import Foundation
import Combine

/// Independent flow module. Integration must supply ASR text in speaking order and
/// an insertion callback for the current host appearance. No host context is read here.
@MainActor final class TranslationViewModel: ObservableObject {
    @Published private(set) var draft = TranslationDraft()
    @Published private(set) var capability = TranslationCapability.unavailable
    @Published private(set) var lastEvent: TranslationEvent?
    @Published private(set) var pendingCount = 0
    @Published var showPreview = false
    @Published var isEditingSource = false
    @Published var previewBeforeInsert = false {
        didSet {
            if previewBeforeInsert != oldValue, let id = draft.requestID, draft.isBusy { cancel(id) }
        }
    }
    @Published private(set) var message = "翻译尚未连接"
    var onInsert: ((String) -> Void)?
    private let service: any TextTranslating
    private let defaults: UserDefaults
    private let timeoutNanoseconds: UInt64
    private var isVisible = false
    private var hostSessionID: UUID?
    private var generation: UInt64 = 0
    private var queue: [TranslationRequest] = []
    private var worker: Task<Void, Never>?
    private var current: Task<TranslationEvent, Error>?
    private var currentRequest: TranslationRequest?
    private var originalInserted = false
    private var currentID: UUID?
    private var cancelled = Set<UUID>()
    private var delivered = Set<UUID>()
    private var voiceContexts: [UUID: TranslationContext] = [:]
    init(service: any TextTranslating = DisabledTranslationService(), defaults: UserDefaults = .standard,
         timeoutNanoseconds: UInt64 = 15_000_000_000) {
        self.service = service; self.defaults = defaults; self.timeoutNanoseconds = timeoutNanoseconds
        draft.editSource(defaults.string(forKey: "translation_source_v1") ?? "")
        if let data = defaults.data(forKey: "translation_target_v1"), let target = try? JSONDecoder().decode(TranslationTarget.self, from: data), target.isValid {
            draft.changeTarget(target)
        }
        if let data = defaults.data(forKey: "translation_recovery_v1") { lastEvent = try? JSONDecoder().decode(TranslationEvent.self, from: data) }
    }
    func appear(hasFullAccess: Bool, hostSessionID: UUID? = nil) async {
        if let hostSessionID, hostSessionID != self.hostSessionID {
            if isVisible { cancelAll() }
            self.hostSessionID = hostSessionID
        }
        if !isVisible { generation &+= 1; isVisible = true }
        let epoch = generation
        guard hasFullAccess else {
            capability = TranslationCapability(serviceID: "", serviceLabel: "需要完全访问", isAvailable: false,
                supportedTargets: [], orderedTargets: TranslationTarget.choices, failure: .noFullAccess)
            message = TranslationFailure.noFullAccess.message
            return
        }
        let result = await service.capability
        guard isVisible, epoch == generation else { return }
        if capability.serviceID != result.serviceID, !capability.serviceID.isEmpty { cancelAll() }
        capability = result
        message = result.isAvailable ? "翻译服务：\(result.serviceLabel) · 只发送本次原文" : (result.failure ?? .unavailable).message
    }
    func disappear() {
        isVisible = false; generation &+= 1
        cancelAll(); onInsert = nil; isEditingSource = false
    }
    func editSource(_ text: String) {
        if let id = draft.requestID { cancel(id) }
        draft.editSource(text); originalInserted = false; persistDraft()
    }
    func appendSource(_ text: String) { editSource(draft.source + text) }
    func deleteSourceBackward() { guard !draft.source.isEmpty else { return }; editSource(String(draft.source.dropLast())) }
    func chooseTarget(_ target: TranslationTarget) {
        guard target.isValid else { return }
        if let id = draft.requestID { cancel(id) }
        draft.changeTarget(target); persistDraft()
    }
    func restoreSource() {
        if let id = draft.requestID { cancel(id) }
        draft.restoreSource(); persistDraft()
    }
    func restoreLastOriginal() { if let lastEvent { editSource(lastEvent.source); showPreview = true } }
    @discardableResult func submitTyped() -> UUID? {
        guard isVisible, !draft.isBusy else { return nil }
        if let failure = availabilityFailure(for: draft.target) {
            draft.fail(failure, id: draft.requestID); message = failure.message; return nil
        }
        let context = TranslationContext(target: draft.target, sourceKind: .typed,
            deliveryMode: previewBeforeInsert ? .preview : .automatic, consentServiceID: capability.serviceID)
        guard let request = draft.begin(context) else { message = draft.failure?.message ?? "请检查原文"; return nil }
        enqueue(request)
        return context.id
    }
    /// Call only after a language is deliberately selected, never on press-down alone.
    func prepareVoice(target: TranslationTarget) -> TranslationContext? {
        guard isVisible else { return nil }
        if let failure = availabilityFailure(for: target) { message = failure.message; return nil }
        let context = TranslationContext(target: target, sourceKind: .voice, consentServiceID: capability.serviceID)
        voiceContexts[context.id] = context
        return context
    }
    /// The ASR owner supplies final original text in its existing FIFO order.
    func receiveVoiceSource(_ source: String, contextID: UUID) {
        guard isVisible, let context = voiceContexts.removeValue(forKey: contextID), !cancelled.contains(contextID) else { return }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            retain(TranslationEvent(context: context, source: source, translation: nil, failure: .emptySource)); return
        }
        guard source.utf8.count <= TranslationRequest.maxSourceUTF8Bytes else {
            retain(TranslationEvent(context: context, source: source, translation: nil, failure: .inputTooLong)); return
        }
        enqueue(TranslationRequest(context: context, source: source))
    }
    func cancel(_ id: UUID) {
        if let request = currentRequest?.context.id == id ? currentRequest : queue.first(where: { $0.context.id == id }) {
            retain(TranslationEvent(context: request.context, source: request.source, translation: nil, failure: .cancelled))
        }
        cancelled.insert(id); voiceContexts[id] = nil
        queue.removeAll { $0.context.id == id }
        if currentID == id { current?.cancel() }
        if draft.requestID == id { draft.cancel() }
        pendingCount = queue.count + (currentID == nil ? 0 : 1)
        Task { await service.cancel(id) }
        message = TranslationFailure.cancelled.message
    }
    func cancelDraft() { if let id = draft.requestID { cancel(id) } else { draft.cancel() }; persistDraft() }
    func insertPreview() {
        guard isVisible, let text = draft.consumePreview() else { return }
        onInsert?(text); message = "已尝试插入草稿，不会自动发送"
    }
    func insertOriginal() {
        guard isVisible, !draft.source.isEmpty, !originalInserted else { return }
        cancelDraft(); originalInserted = true
        onInsert?(draft.source); message = "已明确选择插入原文，不是译文"
    }
    private func availabilityFailure(for target: TranslationTarget) -> TranslationFailure? {
        guard capability.isAvailable else { return capability.failure ?? .unavailable }
        guard !capability.serviceID.isEmpty else { return .missingConfiguration }
        guard capability.supportedTargets.contains(target) else { return .unsupportedTarget }
        return nil
    }
    private func enqueue(_ request: TranslationRequest) {
        queue.append(request); pendingCount = queue.count + (currentID == nil ? 0 : 1)
        message = "翻译中 → \(request.context.target.displayName)"
        startWorker()
    }
    private func startWorker() {
        guard worker == nil else { return }
        let epoch = generation
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == epoch { self.worker = nil; self.current = nil; self.currentID = nil; self.currentRequest = nil; self.pendingCount = self.queue.count } }
            while !Task.isCancelled, self.isVisible, self.generation == epoch, !self.queue.isEmpty {
                let request = self.queue.removeFirst(), id = request.context.id
                guard !self.cancelled.contains(id) else { continue }
                self.currentID = id; self.currentRequest = request
                let work = Task { try await TranslationRequestExecutor.run(request, service: self.service, timeoutNanoseconds: self.timeoutNanoseconds) }
                self.current = work
                let event: TranslationEvent
                do {
                    let result = try await work.value
                    guard result.context == request.context, result.source == request.source else { throw TranslationFailure.invalidResult }
                    guard result.isSuccess else { throw result.failure ?? .emptyResult }
                    guard TranslationContentGuard.validate(source: request.source, translation: result.translation ?? "") else { throw TranslationFailure.unsafeResult }
                    event = result
                } catch {
                    event = TranslationEvent(context: request.context, source: request.source, translation: nil,
                        failure: (error as? TranslationFailure) ?? (error is CancellationError ? .cancelled : .invalidResult))
                }
                guard self.isVisible, self.generation == epoch else { return }
                self.current = nil; self.currentID = nil; self.currentRequest = nil
                self.pendingCount = self.queue.count
                guard !self.cancelled.contains(id), !self.delivered.contains(id) else { continue }
                if request.context.sourceKind == .typed {
                    guard self.draft.receive(event) else { continue }
                }
                self.delivered.insert(id)
                self.retain(event)
                if event.isSuccess, request.context.deliveryMode == .automatic, let text = event.translation {
                    self.onInsert?(text)
                    self.message = "已尝试插入译文草稿，不会自动发送"
                }
            }
        }
    }
    private func retain(_ event: TranslationEvent) {
        lastEvent = event
        message = event.failure?.message ?? "译文可恢复，请核对姓名、地名、否定与语气"
        if let data = try? JSONEncoder().encode(event) { defaults.set(data, forKey: "translation_recovery_v1") }
        persistDraft()
    }
    private func cancelAll() {
        generation &+= 1
        if let request = currentRequest ?? queue.last {
            retain(TranslationEvent(context: request.context, source: request.source, translation: nil, failure: .cancelled))
        }
        for request in queue { cancelled.insert(request.context.id) }
        if let id = currentID { cancelled.insert(id); Task { await service.cancel(id) } }
        queue.removeAll(); voiceContexts.removeAll()
        current?.cancel(); worker?.cancel(); current = nil; worker = nil; currentID = nil; currentRequest = nil
        draft.cancel(); pendingCount = 0
    }
    private func persistDraft() {
        defaults.set(draft.source, forKey: "translation_source_v1")
        if let data = try? JSONEncoder().encode(draft.target) { defaults.set(data, forKey: "translation_target_v1") }
    }
}
