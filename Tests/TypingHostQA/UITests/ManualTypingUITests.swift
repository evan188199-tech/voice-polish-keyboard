import XCTest

@MainActor
final class ManualTypingUITests: XCTestCase {
    private func openKeyboard() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        app.buttons["host.select"].tap()
        let abc = app.buttons["切换到英文键盘"].firstMatch
        if !abc.waitForExistence(timeout: 2) {
            let globe = app.buttons.matching(NSPredicate(format: "identifier == 'Next keyboard' OR label IN %@",
                                                          ["Next keyboard", "下一个键盘", "下一個鍵盤"])).firstMatch
            XCTAssertTrue(globe.waitForExistence(timeout: 3), app.debugDescription)
            globe.press(forDuration: 1)
            let keyboard = app.cells.matching(NSPredicate(format: "label CONTAINS '言出文随'")).firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
            keyboard.tap()
        }
        XCTAssertTrue(abc.waitForExistence(timeout: 3), app.debugDescription)
        return app
    }

    func testFullAndSogouPinyinToEnglish() throws {
        let app = try openKeyboard()
        app.buttons["切换到拼音键盘"].firstMatch.tap()
        let scheme = app.buttons["pinyin.scheme"].firstMatch
        scheme.tap()
        app.buttons["全拼"].firstMatch.tap()
        let field = app.textFields["host.field"]
        for key in "nihao" { app.buttons[String(key)].firstMatch.tap() }
        app.buttons["pinyin.choice.你好"].firstMatch.tap()
        XCTAssertEqual(field.value as? String, "Alpha 你好 Omega")
        scheme.tap()
        app.buttons["搜狗双拼"].firstMatch.tap()
        for key in ["x","分号，韵母 ing","q","分号，韵母 ing"] { app.buttons[key].firstMatch.tap() }
        let choice = app.buttons["pinyin.choice.性情"].firstMatch
        for _ in 0..<8 where !choice.exists { app.buttons["下一页候选"].firstMatch.tap() }
        XCTAssertTrue(choice.exists, app.debugDescription)
        choice.tap()
        XCTAssertEqual(field.value as? String, "Alpha 你好性情 Omega")
        app.buttons["切换到英文键盘"].firstMatch.tap()
        for key in ["a","b","c"] { app.buttons[key].firstMatch.tap() }
        XCTAssertEqual(field.value as? String, "Alpha 你好性情abc Omega")
        app.buttons["回到语音键盘"].firstMatch.tap()
        XCTAssertTrue(app.buttons["切换到拼音键盘"].firstMatch.exists)
        XCTAssertEqual(field.value as? String, "Alpha 你好性情abc Omega")
        app.buttons["发送"].firstMatch.tap()
        XCTAssertEqual(app.staticTexts["host.localSend"].label, "Alpha 你好性情abc Omega")
    }

    func testInitialsPreserveUnselectedSuffix() throws {
        let app = try openKeyboard()
        app.buttons["切换到拼音键盘"].firstMatch.tap()
        app.buttons["pinyin.scheme"].firstMatch.tap()
        app.buttons["全拼"].firstMatch.tap()
        let field = app.textFields["host.field"]
        for key in "dzjwqm" { app.buttons[String(key)].firstMatch.tap() }
        let candidate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pinyin.choice.'")).firstMatch
        XCTAssertTrue(candidate.exists)
        let chosen = candidate.label
        candidate.tap()
        XCTAssertEqual(field.value as? String, "Alpha " + chosen + " Omega")
        XCTAssertFalse(app.staticTexts["pinyin.code"].firstMatch.label.isEmpty)
        app.buttons["清除拼音编码"].firstMatch.tap()
        for key in "mwt" { app.buttons[String(key)].firstMatch.tap() }
        app.buttons["pinyin.choice.没问题"].firstMatch.tap()
        XCTAssertEqual(field.value as? String, "Alpha " + chosen + "没问题 Omega")
    }

    func testMixedMeetingDraftWithCaseNumbersAndNewline() throws {
        let app = try openKeyboard()
        app.buttons["host.resumeProse"].tap()
        func tap(_ key: String) { app.buttons[key].firstMatch.tap() }
        tap("切换到英文键盘")
        for key in ["Shift", "T", "e", "a", "m", "空格", "Shift", "S", "y", "n", "c", "空格", "a", "t", "空格",
                    "切换到数字键盘", "3", "空格", "切换到英文键盘"] { tap(key) }
        app.buttons["Shift"].firstMatch.doubleTap()
        tap("P")
        tap("M")
        tap("切换到数字键盘")
        tap("小数点")
        let prose = app.textViews["host.prose"]
        let draft = "周五见 Team Sync at 3 PM."
        XCTAssertEqual(prose.value as? String, draft)
        tap("换行")
        XCTAssertEqual(prose.value as? String, draft + "\n")
        app.buttons["delete.backward"].firstMatch.tap()
        tap("回到语音键盘")
        XCTAssertEqual(prose.value as? String, draft)
        XCTAssertTrue(app.buttons["切换到英文键盘"].firstMatch.exists)
    }

    func testDisableSuggestionsAndKeepIdentifiersAcrossFields() throws {
        let app = try openKeyboard()
        func tap(_ key: String) { app.buttons[key].firstMatch.tap() }
        tap("切换到英文键盘")
        for key in ["t", "e", "h"] { tap(key) }
        let suggestion = app.buttons["typing.choice.the"].firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 3))
        tap("英文输入设置")
        tap("关闭英文建议")
        XCTAssertFalse(suggestion.exists)
        defer {
            if app.buttons["英文输入设置"].firstMatch.exists {
                tap("英文输入设置")
                if app.buttons["开启英文建议"].firstMatch.exists { tap("开启英文建议") }
            }
        }
        app.buttons["host.resumeProse"].tap()
        if app.buttons["切换到英文键盘"].firstMatch.exists { tap("切换到英文键盘") }
        XCTAssertFalse(suggestion.exists)
        for key in ["Shift", "A", "l", "Shift", "B", "切换到数字键盘", "at 符号", "切换到英文键盘",
                    "a", "切换到数字键盘", "小数点", "切换到英文键盘", "c", "o", "空格",
                    "x", "切换到数字键盘", "小数点", "切换到英文键盘", "c", "o", "切换到数字键盘",
                    "斜杠", "切换到英文键盘", "Shift", "Q"] { tap(key) }
        XCTAssertEqual(app.textViews["host.prose"].value as? String, "周五见 AlB@a.co x.co/Q")
        XCTAssertEqual(app.textFields["host.field"].value as? String, "Alpha teh Omega")
        XCTAssertFalse(suggestion.exists)
    }

    func testExplicitNextWordUndoAndHostText() throws {
        let app = try openKeyboard()
        let field = app.textFields["host.field"]
        let abc = app.buttons["切换到英文键盘"].firstMatch
        abc.tap()
        for letter in ["g", "o", "o", "d"] { app.buttons[letter].firstMatch.tap() }
        app.buttons["空格"].firstMatch.tap()
        XCTAssertEqual(field.value as? String, "Alpha good  Omega")
        let choice = app.buttons["typing.choice.evening"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 3), app.debugDescription)
        choice.tap()
        XCTAssertEqual(field.value as? String, "Alpha good evening Omega")
        let undo = app.buttons["typing.undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 3), app.debugDescription)
        undo.tap()
        XCTAssertEqual(field.value as? String, "Alpha good  Omega")

        app.buttons["host.select"].tap()
        for letter in ["t", "e", "h"] { app.buttons[letter].firstMatch.tap() }
        XCTAssertEqual(field.value as? String, "Alpha teh Omega")
        let spelling = app.buttons["typing.choice.the"].firstMatch
        XCTAssertTrue(spelling.waitForExistence(timeout: 3), app.debugDescription)
        spelling.tap()
        XCTAssertEqual(field.value as? String, "Alpha the Omega")
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.tap()
        XCTAssertEqual(field.value as? String, "Alpha teh Omega")
    }
}
