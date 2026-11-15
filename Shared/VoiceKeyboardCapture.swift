import Foundation

/// UI transitions are synchronous; only an acknowledged host snapshot may show recording.
/// Submitted jobs deliberately do not belong to this state machine.
struct VoiceKeyboardCapture: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle, starting, recording, finishing, cancelling
    }

    private(set) var phase: Phase = .idle
    var isRecording: Bool { phase == .recording }
    var isTransitioning: Bool { phase != .idle && phase != .recording }
    var canSwitchPage: Bool { phase == .idle }

    mutating func beginStart() -> Bool {
        guard phase == .idle else { return false }
        phase = .starting
        return true
    }

    mutating func beginFinish() -> Bool {
        guard phase == .recording else { return false }
        phase = .finishing
        return true
    }

    mutating func beginCancel() -> Bool {
        guard phase == .recording || phase == .starting else { return false }
        phase = .cancelling
        return true
    }

    mutating func settle(recording: Bool) {
        phase = recording ? .recording : .idle
    }

    /// A poll sent before a start/finish must not undo that newer local transition.
    mutating func observe(recording: Bool) {
        guard !isTransitioning else { return }
        settle(recording: recording)
    }
}

enum VoiceKeyboardSwipe {
    /// This project's initial threshold, pending device usability testing.
    static func shouldSwitch(horizontal: Double, vertical: Double, capture: VoiceKeyboardCapture) -> Bool {
        capture.canSwitchPage && abs(horizontal) >= 60 && abs(horizontal) > abs(vertical) * 1.5
    }
}
