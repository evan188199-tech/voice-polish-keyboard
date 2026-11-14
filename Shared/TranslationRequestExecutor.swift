import Foundation

/// An unstructured provider may ignore cancellation. Resolve the caller promptly,
/// discard late completions, and never let a stale request block a later draft.
/// This cannot retract a request already accepted by a remote service.
enum TranslationRequestExecutor {
    static func run(_ request: TranslationRequest, service: any TextTranslating,
                    timeoutNanoseconds: UInt64) async throws -> TranslationEvent {
        let completion = TranslationCompletion()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let operation = Task {
                    guard completion.isPending else { return }
                    do {
                        try Task.checkCancellation()
                        let result = try await service.translate(request)
                        completion.resolve(.success(result))
                    } catch { completion.resolve(.failure(error)) }
                }
                let timeout = Task {
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    completion.resolve(.failure(TranslationFailure.timeout))
                }
                completion.attach(operation: operation, timeout: timeout)
            }
        } onCancel: {
            completion.resolve(.failure(TranslationFailure.cancelled))
        }
    }
}
private final class TranslationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<TranslationEvent, Error>?
    private var continuation: CheckedContinuation<TranslationEvent, Error>?
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    var isPending: Bool { lock.withLock { result == nil } }
    func install(_ continuation: CheckedContinuation<TranslationEvent, Error>) {
        let existing = lock.withLock { () -> Result<TranslationEvent, Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let existing { continuation.resume(with: existing) }
    }
    func attach(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        let resolved = lock.withLock {
            if result != nil { return true }
            self.operation = operation; self.timeout = timeout
            return false
        }
        if resolved { operation.cancel(); timeout.cancel() }
    }
    func resolve(_ result: Result<TranslationEvent, Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<TranslationEvent, Error>?, Task<Void, Never>?, Task<Void, Never>?)? in
            guard self.result == nil else { return nil }
            self.result = result
            let pending = (continuation, operation, timeout)
            continuation = nil; operation = nil; timeout = nil
            return pending
        }
        guard let pending else { return }
        pending.1?.cancel(); pending.2?.cancel()
        pending.0?.resume(with: result)
    }
}
