import Foundation

@main enum SpokenCorrectionChecks {
    static func main() {
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            if condition() { print("PASS: \(label)") } else { failures += 1; print("FAIL: \(label)") }
        }
        let fixtures: [(String, String)] = [
            ("明天联系小明，小明是黄晓明的晓明。", "明天联系晓明。"),
            ("聽日搵小明，小明係黃曉明嘅曉明。", "聽日搵曉明。")
        ]
        for (source, expected) in fixtures {
            let result = DictationTextPreparation(source, mode: .rewrite)
            check(result.body == expected && result.original == source, "correct only explicit target: \(source)")
            check(!result.accept("分析：" + expected), "provider analysis prefix rejected")
        }
        for text in ["小明是黄晓明的晓明", "他说小明是黄晓明的晓明", "小明和小明，把小明改成晓明。", "通知阿明，不要把阿明改成阿文。", "把小明改成晓明。", "他写下：把小明改成晓明。", "保留20份，不要删除3份。", "路线经过桂林和阳朔。", "明天联系小明，把小明改成晓明，把小王改成张明。", "明天联系小明，把小明改成晓明，把晓明改成张明，把张明改成王明。"] {
            check(SpokenCorrection.process(text, mode: .rewrite).body == text, "ambiguous or ordinary text preserved: \(text)")
        }
        // Synthetic ASR hypotheses for the same spoken correction. Text alone
        // does not identify the user's intended characters or validate audio.
        for hypothesis in ["明天联系小明，把小明改成晓明。", "明天联系小明，把小明改成小明。", "明天联系晓明，把晓明改成小明。", "通知阿明交3份，把阿明改成阿文。", "後日去桂林，將桂林改為陽朔。", "明天联系小明，把小明改成晓明，把晓明改成张明。"] {
            let correction = SpokenCorrection.process(hypothesis, mode: .rewrite)
            check(correction.body == hypothesis && correction.needsConfirmation,
                  "unverified ASR edit is retained for review: \(hypothesis)")
        }
        // A repeated spelling may be an ASR homophone collapse. Do not remove
        // the explanation or report a successful correction from this alone.
        let collapsed = "明天联系小明，小明是黄小明的小明。"
        let collapsedResult = SpokenCorrection.process(collapsed, mode: .rewrite)
        check(collapsedResult.body == collapsed && collapsedResult.needsConfirmation,
              "homophone collapse in the spelling explanation stays reviewable")
        let unpunctuated = "明天联系小明把小明改成小明"
        let unpunctuatedResult = SpokenCorrection.process(unpunctuated, mode: .rewrite)
        check(unpunctuatedResult.body == unpunctuated,
              "unpunctuated homophone hypothesis is not silently rewritten")
        let plain = DictationTextPreparation("明天出发。", mode: .rewrite)
        check(!plain.accept("分析：明天出发。"), "short input rejects analysis prefix")
        check(!plain.accept("以下是整理后的文本：明天出发。"), "short input rejects delivery preface")
        check(plain.accept("明天出发。"), "normal result accepted")
        let dictatedPrefix = DictationTextPreparation("分析：明天出发。", mode: .rewrite)
        check(dictatedPrefix.accept("分析：明天出发。"), "user dictated analysis text remains valid")
        check(DictationTextPreparation("为什么？", mode: .askLLM).accept("分析：这是答案。"), "explicit question mode can return an analysis")
        if failures > 0 { print("FAILED: \(failures)"); exit(1) }
        print("Spoken correction checks passed")
    }
}
