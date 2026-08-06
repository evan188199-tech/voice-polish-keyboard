import XCTest

final class RightOptionStateMachineTests: XCTestCase {
    func testPressAndReleaseStartsAndFinishes() {
        var m = RightOptionStateMachine()
        XCTAssertEqual(m.handle(.optionFlags(rightDown: true, leftDown: false)), .start)
        XCTAssertEqual(m.phase, .recording)
        XCTAssertEqual(m.handle(.optionFlags(rightDown: false, leftDown: false)), .finish)
        XCTAssertEqual(m.phase, .idle)
    }

    func testKeyRepeatDoesNotDoubleStart() {
        var m = RightOptionStateMachine()
        XCTAssertEqual(m.handle(.keyDown(keyCode: MacKeyCode.rightOption, isRepeat: false)), .start)
        XCTAssertEqual(m.handle(.keyDown(keyCode: MacKeyCode.rightOption, isRepeat: true)), .none)
        XCTAssertEqual(m.phase, .recording)
        XCTAssertEqual(m.handle(.keyUp(keyCode: MacKeyCode.rightOption)), .finish)
    }

    func testEscapeCancels() {
        var m = RightOptionStateMachine()
        _ = m.handle(.optionFlags(rightDown: true, leftDown: false))
        XCTAssertEqual(m.handle(.keyDown(keyCode: MacKeyCode.escape, isRepeat: false)), .cancel)
        XCTAssertEqual(m.phase, .idle)
    }

    func testLeftOptionDoesNotStart() {
        var m = RightOptionStateMachine()
        XCTAssertEqual(m.handle(.optionFlags(rightDown: false, leftDown: true)), .none)
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.handle(.keyDown(keyCode: MacKeyCode.leftOption, isRepeat: false)), .none)
        XCTAssertEqual(m.handle(.keyUp(keyCode: MacKeyCode.leftOption)), .none)
    }

    func testMixedOptionStillAllowsRightPTT() {
        var m = RightOptionStateMachine()
        _ = m.handle(.optionFlags(rightDown: false, leftDown: true))
        XCTAssertEqual(m.handle(.optionFlags(rightDown: true, leftDown: true)), .start)
        XCTAssertEqual(m.handle(.optionFlags(rightDown: false, leftDown: true)), .finish)
    }

    func testConnectionLostCancelsRecording() {
        var m = RightOptionStateMachine()
        _ = m.handle(.optionFlags(rightDown: true, leftDown: false))
        XCTAssertEqual(m.handle(.connectionLost), .cancel)
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.handle(.connectionLost), .none)
    }

    func testDoubleStartIgnoredWhileRecording() {
        var m = RightOptionStateMachine()
        XCTAssertEqual(m.handle(.optionFlags(rightDown: true, leftDown: false)), .start)
        // Spurious re-assert of right down
        XCTAssertEqual(m.handle(.optionFlags(rightDown: true, leftDown: false)), .none)
        XCTAssertEqual(m.phase, .recording)
    }
}

final class SharedProtocolMacTests: XCTestCase {
    func testBuildToken() {
        let a = BuildToken.generate()
        XCTAssertTrue(BuildToken.validate(a))
        XCTAssertFalse(BuildToken.validate("nope"))
    }

    func testBridgeErrorCodeRoundtrip() throws {
        let response = BridgeResponse.error("mic", code: .micDenied)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(BridgeResponse.self, from: data)
        XCTAssertEqual(decoded.errorCode, .micDenied)
        XCTAssertEqual(decoded.outcome, .error)
    }

    func testLocalTextProcessor() {
        let cleaned = LocalTextProcessor.process("嗯 你好", vocabulary: "")
        XCTAssertFalse(cleaned.contains("嗯"))
        XCTAssertTrue(cleaned.contains("你好"))
    }

    func testJoinTranscriptSegmentsChineseBareGetsPeriod() {
        let joined = LocalTextProcessor.joinTranscriptSegments([
            "今天天气很好",
            "明天去公司"
        ])
        XCTAssertEqual(joined, "今天天气很好。明天去公司")
    }

    func testJoinTranscriptSegmentsEnglishUsesSpace() {
        XCTAssertEqual(
            LocalTextProcessor.joinTranscriptSegments(["hello world", "open the app"]),
            "hello world open the app"
        )
    }

    func testLocalTextProcessorConvertsChineseNumbers() {
        XCTAssertEqual(LocalTextProcessor.process("一二三四", vocabulary: ""), "1234")
        XCTAssertEqual(LocalTextProcessor.process("八零八零", vocabulary: ""), "8080")
        XCTAssertEqual(LocalTextProcessor.process("一百二十三", vocabulary: ""), "123")
        XCTAssertEqual(LocalTextProcessor.process("一万零三", vocabulary: ""), "10003")
        XCTAssertEqual(LocalTextProcessor.process("一心一意", vocabulary: ""), "一心一意")
    }

    func testLocalTextProcessorProcessSegmentsRespectsLetterPauses() {
        XCTAssertEqual(
            LocalTextProcessor.processSegments(["C O D E X"], vocabulary: ""),
            "CODEX"
        )
        XCTAssertEqual(
            LocalTextProcessor.processSegments(["A B", "C D"], vocabulary: ""),
            "AB CD"
        )
        XCTAssertEqual(
            LocalTextProcessor.processSegments(["hello world"], vocabulary: ""),
            "Hello world"
        )
    }
}
