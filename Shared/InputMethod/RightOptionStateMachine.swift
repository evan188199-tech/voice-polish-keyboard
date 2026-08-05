import Foundation

/// Hardware key codes (Carbon / macOS).
enum MacKeyCode {
    static let escape: UInt16 = 53
    static let leftOption: UInt16 = 58
    static let rightOption: UInt16 = 61
}

/// Pure state machine for right-Option push-to-talk.
/// Ignores key repeats, left Option as a trigger, and mixed Option noise.
struct RightOptionStateMachine: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case idle
        case recording
    }

    enum Event: Equatable, Sendable {
        /// Option flag transitions from flagsChanged (preferred for Option keys).
        case optionFlags(rightDown: Bool, leftDown: Bool)
        case keyDown(keyCode: UInt16, isRepeat: Bool)
        case keyUp(keyCode: UInt16)
        case connectionLost
        case reset
    }

    enum Action: Equatable, Sendable {
        case none
        case start
        case finish
        case cancel
    }

    private(set) var phase: Phase = .idle
    private(set) var rightOptionDown = false
    private(set) var leftOptionDown = false

    mutating func handle(_ event: Event) -> Action {
        switch event {
        case .reset:
            phase = .idle
            rightOptionDown = false
            leftOptionDown = false
            return .none

        case .connectionLost:
            let wasRecording = phase == .recording
            phase = .idle
            rightOptionDown = false
            // Keep left flag as-is is meaningless after disconnect; clear both.
            leftOptionDown = false
            return wasRecording ? .cancel : .none

        case let .optionFlags(rightDown, leftDown):
            return handleOptionFlags(rightDown: rightDown, leftDown: leftDown)

        case let .keyDown(keyCode, isRepeat):
            if keyCode == MacKeyCode.escape {
                guard phase == .recording else { return .none }
                phase = .idle
                rightOptionDown = false
                return .cancel
            }
            // Right Option may also arrive as keyDown on some systems; ignore repeats.
            if keyCode == MacKeyCode.rightOption {
                if isRepeat { return .none }
                return handleOptionFlags(rightDown: true, leftDown: leftOptionDown)
            }
            if keyCode == MacKeyCode.leftOption {
                leftOptionDown = true
                return .none
            }
            return .none

        case let .keyUp(keyCode):
            if keyCode == MacKeyCode.rightOption {
                return handleOptionFlags(rightDown: false, leftDown: leftOptionDown)
            }
            if keyCode == MacKeyCode.leftOption {
                leftOptionDown = false
                return .none
            }
            return .none
        }
    }

    private mutating func handleOptionFlags(rightDown: Bool, leftDown: Bool) -> Action {
        leftOptionDown = leftDown
        let wasRight = rightOptionDown
        rightOptionDown = rightDown

        // Rising edge on right Option → start (only from idle).
        if rightDown && !wasRight {
            // Left Option alone never starts. Mixed: still allow right Option PTT.
            guard phase == .idle else { return .none }
            phase = .recording
            return .start
        }

        // Falling edge on right Option → finish when recording.
        if !rightDown && wasRight {
            guard phase == .recording else { return .none }
            phase = .idle
            return .finish
        }

        return .none
    }
}
