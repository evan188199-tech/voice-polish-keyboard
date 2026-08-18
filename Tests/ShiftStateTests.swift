import XCTest
@testable import VoicePolishApp

final class ShiftStateTests: XCTestCase {
    private let controller = ShiftStateController()

    // MARK: - shiftTapped

    func testOffSingleTapEntersOneShot() {
        let next = controller.shiftTapped(from: .off, lastTapAt: nil, now: Date())
        XCTAssertEqual(next, .oneShot)
    }

    func testOneShotDoubleTapWithinIntervalLocks() {
        let first = Date()
        let next = controller.shiftTapped(from: .oneShot, lastTapAt: first, now: first.addingTimeInterval(0.3))
        XCTAssertEqual(next, .locked)
    }

    func testOneShotSecondTapAfterIntervalReArmsOneShot() {
        let first = Date()
        let next = controller.shiftTapped(from: .oneShot, lastTapAt: first, now: first.addingTimeInterval(0.5))
        XCTAssertEqual(next, .oneShot)
    }

    func testOneShotWithoutPreviousTapStaysOneShot() {
        let next = controller.shiftTapped(from: .oneShot, lastTapAt: nil, now: Date())
        XCTAssertEqual(next, .oneShot)
    }

    func testLockedTapReturnsToOff() {
        let now = Date()
        let next = controller.shiftTapped(from: .locked, lastTapAt: now, now: now)
        XCTAssertEqual(next, .off)
    }

    func testBoundaryIntervalExactlyAtThresholdLocks() {
        let first = Date()
        let next = controller.shiftTapped(from: .oneShot, lastTapAt: first, now: first.addingTimeInterval(0.4))
        XCTAssertEqual(next, .locked)
    }

    // MARK: - inserting

    func testOffLetterIsLowercase() {
        let result = controller.inserting(character: "A", into: .off)
        XCTAssertEqual(result.output, "a")
        XCTAssertEqual(result.nextState, .off)
    }

    func testOneShotLetterIsUppercaseAndResets() {
        let result = controller.inserting(character: "a", into: .oneShot)
        XCTAssertEqual(result.output, "A")
        XCTAssertEqual(result.nextState, .off)
    }

    func testLockedLetterIsUppercaseAndStaysLocked() {
        let result = controller.inserting(character: "a", into: .locked)
        XCTAssertEqual(result.output, "A")
        XCTAssertEqual(result.nextState, .locked)
    }

    func testInsertingNonLetterPassesThrough() {
        let result = controller.inserting(character: "5", into: .oneShot)
        XCTAssertEqual(result.output, "5")
        XCTAssertEqual(result.nextState, .off)
    }
}
