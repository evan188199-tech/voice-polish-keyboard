import XCTest

final class PolishModeTests: XCTestCase {
    func testDefaultAndLabels() {
        XCTAssertEqual(PolishMode.default, .rewrite)
        XCTAssertEqual(PolishMode.correctOnly.displayName, "只纠错")
        XCTAssertEqual(PolishMode.coding.displayName, "Coding")
        XCTAssertEqual(PolishMode.rewrite.displayName, "润色词句")
        XCTAssertEqual(PolishMode.askLLM.displayName, "问 LLM")
        XCTAssertEqual(PolishMode.correctOnly.shortLabel, "纠错")
        XCTAssertEqual(PolishMode.coding.shortLabel, "代码")
        XCTAssertEqual(PolishMode.rewrite.shortLabel, "润色")
        XCTAssertEqual(PolishMode.askLLM.shortLabel, "问答")
    }

    func testCycleOrder() {
        XCTAssertEqual(PolishMode.cycleOrder, [.correctOnly, .coding, .rewrite, .askLLM])
    }

    func testWireCodec() {
        XCTAssertEqual(PolishMode.fromWire("askLLM"), .askLLM)
        XCTAssertEqual(PolishMode.fromWire("coding"), .coding)
        XCTAssertNil(PolishMode.fromWire(nil))
        XCTAssertNil(PolishMode.fromWire(""))
        XCTAssertNil(PolishMode.fromWire("nope"))
    }

    func testPromptsAndTemperature() {
        XCTAssertNotEqual(PolishMode.correctOnly.systemPrompt, PolishMode.askLLM.systemPrompt)
        XCTAssertTrue(PolishMode.correctOnly.systemPrompt.contains("纠错") || PolishMode.correctOnly.systemPrompt.contains("识别错误"))
        XCTAssertTrue(PolishMode.coding.systemPrompt.contains("编程") || PolishMode.coding.systemPrompt.contains("标识符"))
        XCTAssertTrue(PolishMode.rewrite.systemPrompt.contains("不要回答问题"))
        XCTAssertTrue(PolishMode.askLLM.systemPrompt.contains("最终结果") || PolishMode.askLLM.systemPrompt.contains("指令"))
        XCTAssertEqual(PolishMode.correctOnly.temperature, 0.2, accuracy: 0.0001)
        XCTAssertEqual(PolishMode.coding.temperature, 0.2, accuracy: 0.0001)
        XCTAssertEqual(PolishMode.rewrite.temperature, 0.2, accuracy: 0.0001)
        XCTAssertEqual(PolishMode.askLLM.temperature, 0.5, accuracy: 0.0001)
        XCTAssertEqual(PolishMode.askLLM.processingStatusMessage, "生成中…")
        XCTAssertEqual(PolishMode.rewrite.processingStatusMessage, "润色中…")
    }
}
