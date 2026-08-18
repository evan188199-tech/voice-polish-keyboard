import Foundation

/// Shift key states for the QWERTY keyboard page.
///
/// - `off`: letters are lowercase.
/// - `oneShot`: the next letter is uppercase, then the state returns to `off`.
/// - `locked`: every letter is uppercase until the user toggles back to `off`.
enum ShiftState: Equatable, Sendable {
    case off
    case oneShot
    case locked
}

/// Stateless transitions for the Shift key. All logic is pure so it can be
/// unit-tested without a view; the owning view tracks `lastTapAt` separately.
struct ShiftStateController: Sendable {
    /// Maximum interval between two consecutive Shift taps to count as a
    /// double-tap lock gesture, in seconds.
    var doubleTapInterval: TimeInterval = 0.4

    /// Returns the new Shift state after a Shift key tap.
    ///
    /// Transition table:
    /// - `off -> oneShot`
    /// - `oneShot -> locked` when the previous tap was within `doubleTapInterval`
    /// - `oneShot -> oneShot` otherwise (re-arm another single capitalize)
    /// - `locked -> off`
    func shiftTapped(from current: ShiftState, lastTapAt: Date?, now: Date) -> ShiftState {
        switch current {
        case .off:
            return .oneShot
        case .oneShot:
            if let lastTapAt, now.timeIntervalSince(lastTapAt) <= doubleTapInterval {
                return .locked
            }
            return .oneShot
        case .locked:
            return .off
        }
    }

    /// Returns the letter to insert for the given Shift state and the state to
    /// transition to after insertion. `oneShot` consumes itself and returns to
    /// `off`; `locked` is preserved.
    func inserting(character: Character, into state: ShiftState) -> (output: Character, nextState: ShiftState) {
        switch state {
        case .off:
            return (character.lowercased().first ?? character, .off)
        case .oneShot:
            return (character.uppercased().first ?? character, .off)
        case .locked:
            return (character.uppercased().first ?? character, .locked)
        }
    }
}
