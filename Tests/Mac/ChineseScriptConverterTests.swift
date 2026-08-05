import XCTest

final class ChineseScriptConverterTests: XCTestCase {
    func testSimplifiedToTraditional() {
        let text = "软件工程师"
        let result = ChineseScriptConverter.convert(text, direction: .toTraditional)
        XCTAssertEqual(result, "軟件工程師")
    }

    func testTraditionalToSimplified() {
        let text = "軟件工程師"
        let result = ChineseScriptConverter.convert(text, direction: .toSimplified)
        XCTAssertEqual(result, "软件工程师")
    }

    func testMixedChineseEnglishPreservesEnglish() {
        let text = "iPhone 15 发布了"
        let result = ChineseScriptConverter.convert(text, direction: .toTraditional)
        XCTAssertTrue(result.contains("iPhone"))
        XCTAssertTrue(result.contains("15"))
        XCTAssertTrue(result.contains("發佈了"))
    }

    func testCodeIdentifiersUntouched() {
        let text = "let userName = getUser()"
        let result = ChineseScriptConverter.convert(text, direction: .toTraditional)
        XCTAssertEqual(result, "let userName = getUser()")
    }

    func testCantoneseCharsPreserved() {
        let text = "佢嘅嘢冇咗"
        let result = ChineseScriptConverter.convert(text, direction: .toSimplified)
        // Cantonese chars generally don't have simplified forms, so roundtrip should match original
        let roundTripped = ChineseScriptConverter.convert(result, direction: .toTraditional)
        XCTAssertEqual(roundTripped, text)
    }

    func testEmptyStringReturnsEmpty() {
        XCTAssertEqual(ChineseScriptConverter.convert("", direction: .toTraditional), "")
        XCTAssertEqual(ChineseScriptConverter.convert("", direction: .toSimplified), "")
    }

    func testNilDirectionReturnsOriginal() {
        let text = "测试测试"
        XCTAssertEqual(ChineseScriptConverter.convert(text, direction: nil), text)
    }

    func testIdempotentDoubleConversion() {
        let simplified = "简体中文测试"
        let traditional = ChineseScriptConverter.convert(simplified, direction: .toTraditional)
        let again = ChineseScriptConverter.convert(traditional, direction: .toTraditional)
        XCTAssertEqual(again, traditional)
    }

    func testAlreadyInDirection() {
        let simplified = "简体中文"
        let traditional = ChineseScriptConverter.convert(simplified, direction: .toTraditional)
        XCTAssertTrue(ChineseScriptConverter.alreadyInDirection(traditional, direction: .toTraditional))
        XCTAssertTrue(ChineseScriptConverter.alreadyInDirection(simplified, direction: .toSimplified))
    }

    func testNumbersAndPunctuationPreserved() {
        let text = "售价 ¥199.99，数量 42 件！"
        let result = ChineseScriptConverter.convert(text, direction: .toTraditional)
        XCTAssertTrue(result.contains("¥199.99"))
        XCTAssertTrue(result.contains("42"))
    }
}
