import XCTest

/// Run only against a disposable, configured iPhone 16e simulator.
final class VoiceKeyboardUITests: XCTestCase {
    @MainActor private func openVoiceKeyboard() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        for attempt in 0..<2 {
            app.textFields["qa.input"].tap()
            if app.buttons["回到语音键盘"].exists { app.buttons["回到语音键盘"].tap() }
            if !app.buttons["下一个系统键盘"].waitForExistence(timeout: 5) {
                let next = app.buttons["Next keyboard"].firstMatch
                if next.waitForExistence(timeout: 10) {
                    next.press(forDuration: 1.5)
                    let voice = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "粤英语音键盘")).firstMatch
                    if voice.waitForExistence(timeout: 10) { voice.tap() }
                }
            }
            if app.buttons["voice.microphone"].firstMatch.waitForExistence(timeout: 10) { break }
            if attempt == 0 { app.terminate(); app.launch() }
        }
        return app
    }

    @MainActor func testVoiceLayoutAndTopRowTyping() {
        let app = openVoiceKeyboard()
        XCTAssertTrue(app.staticTexts["voice.captureHint"].waitForExistence(timeout: 20))
        let returnKey = app.buttons["回车，遵循当前应用行为"].firstMatch
        XCTAssertTrue(returnKey.isHittable)
        // This harness explicitly targets a portrait iPhone 16e simulator.
        XCTAssertLessThanOrEqual(returnKey.frame.maxY, 844)
        app.buttons["切换到英文键盘"].tap()
        let q = app.buttons["q"].firstMatch
        XCTAssertTrue(q.waitForExistence(timeout: 10))
        XCTAssertTrue(q.isHittable)
        XCTAssertGreaterThanOrEqual(q.frame.minY, 0)
        q.tap()
        XCTAssertEqual(app.textFields["qa.input"].value as? String, "q")
        app.buttons["删除"].firstMatch.tap()
        XCTAssertEqual(app.textFields["qa.input"].value as? String, "Test input")
    }

    @MainActor func testHeldResultIsInsertedOnce() {
        let app = openVoiceKeyboard()
        let held = app.buttons["voice.insertHeldResult"].firstMatch
        XCTAssertTrue(held.waitForExistence(timeout: 20), "Seed the disposable extension container as described in README.")
        held.tap()
        XCTAssertEqual(app.textFields["qa.input"].value as? String, "模拟保留结果")
        XCTAssertFalse(held.exists)
        app.terminate()
        app.launch()
        app.textFields["qa.input"].tap()
        XCTAssertTrue(app.staticTexts["voice.captureHint"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["voice.insertHeldResult"].exists)
        XCTAssertEqual(app.textFields["qa.input"].value as? String, "Test input")
    }
}
