import Foundation

/// Fixed-rate long-press delete timings used by the keyboard delete key.
struct DeleteRepeatTiming: Equatable, Sendable {
    var initialDelayNanoseconds: UInt64
    var repeatIntervalNanoseconds: UInt64

    /// Balanced mature-keyboard defaults: 400ms first delay, then 70ms repeats.
    static let standard = DeleteRepeatTiming(
        initialDelayNanoseconds: 400_000_000,
        repeatIntervalNanoseconds: 70_000_000
    )
}

/// Owns the press / delay / repeat / cancel lifecycle for continuous delete.
///
/// Behavior:
/// - `pressBegan()` deletes once immediately.
/// - After the initial delay, deletes again on a fixed interval.
/// - `pressEnded()` / `cancel()` stop immediately and stay cancelled for this press session.
/// - Duplicate `pressBegan()` while active is ignored so only one loop runs.
@MainActor
final class DeleteRepeatController {
    private let timing: DeleteRepeatTiming
    private let onDelete: () -> Void
    private var repeatTask: Task<Void, Never>?
    private(set) var isActive = false

    init(
        timing: DeleteRepeatTiming = .standard,
        onDelete: @escaping () -> Void
    ) {
        self.timing = timing
        self.onDelete = onDelete
    }

    deinit {
        repeatTask?.cancel()
    }

    /// Starts a press session: one immediate delete, then fixed-rate repeats.
    func pressBegan() {
        guard !isActive else { return }

        isActive = true
        onDelete()

        let initialDelay = timing.initialDelayNanoseconds
        let repeatInterval = timing.repeatIntervalNanoseconds

        repeatTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: initialDelay)
            } catch {
                return
            }

            while !Task.isCancelled {
                guard let self, self.isActive else { return }
                self.onDelete()

                do {
                    try await Task.sleep(nanoseconds: repeatInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// Ends a normal press (finger up inside or outside).
    func pressEnded() {
        cancel()
    }

    /// Cancels any pending delay / repeat work immediately.
    func cancel() {
        isActive = false
        repeatTask?.cancel()
        repeatTask = nil
    }
}
