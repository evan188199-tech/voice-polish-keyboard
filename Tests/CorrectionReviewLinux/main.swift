import Foundation

@main enum CorrectionReviewChecks {
    static func main() {
        var failures = 0
        func check(_ ok: @autoclosure () -> Bool, _ label: String) { if ok() { print("PASS: \(label)") } else { failures += 1; print("FAIL: \(label)") } }
        let source = "明天联系小明，把小明改成晓明。"
        let proposal = CorrectionReviewProposal.make(original: source)
        check(proposal.original == source && proposal.draft == "明天联系小明。" && proposal.candidates == ["小明", "晓明"], "raw, clean draft and sourced candidates stay distinct")
        var state = CorrectionReviewState()
        let token = state.begin(original: source)
        check(state.finalText == nil && !state.confirm(candidate: "晓明"), "no delivery before review")
        let forged = CorrectionReviewProposal(original: source, draft: "明天联系小明。", target: "小明", candidates: ["黄晓明"], hint: "x")
        check(!state.acceptProposal(forged, token: token), "unsourced or altered asynchronous proposal is rejected")
        check(state.acceptProposal(proposal, token: token), "matching proposal is accepted")
        check(!state.confirm(candidate: "黄晓明"), "unsupported name cannot become a candidate")
        check(state.confirm(candidate: "晓明") && state.finalText == "明天联系晓明。", "explicit choice forms final text")
        check(!state.confirm(candidate: "晓明") && state.restoreOriginal() == source, "duplicate confirm rejected and raw text retained")
        check(state.undo() && state.finalText == nil && state.phase == .reviewing, "undo clears uncommitted result")
        check(state.confirm(candidate: "小明") && state.finalText == "明天联系小明。", "original target is also an explicit choice")
        check(state.undo() && state.keepOriginal() && state.finalText == source, "keep original requires an explicit choice")
        state.cancel()
        check(state.finalText == nil && state.restoreOriginal() == source && !state.undo(), "cancel does not deliver and keeps recovery source")
        let spelling = CorrectionReviewProposal.make(original: "明天联系小明，小明是黄晓明的晓明。")
        check(spelling.draft == "明天联系小明。" && spelling.candidates == ["小明", "晓明"], "spelling example offers only recognized names for explicit review")
        let noTargetSpelling = CorrectionReviewProposal.make(original: "小明是黄晓明的晓明。")
        check(noTargetSpelling.draft == nil, "standalone spelling without target does not invent a draft")
        let same = CorrectionReviewProposal.make(original: "明天联系小明，把小明改成小明。")
        check(same.candidates == ["小明"], "same candidate does not invent a homophone")
        let cantonese = CorrectionReviewProposal.make(original: "後日去桂林，將桂林改為陽朔。")
        check(cantonese.draft == "後日去桂林。" && cantonese.candidates == ["桂林", "陽朔"], "traditional candidate uses only spoken transcript")
        for text in ["把小明改成晓明。", "联系小明和小明，把小明改成晓明。", "联系aaa，把aa改成bb。", "他引用‘联系小明，把小明改成晓明。’", "联系小明，把小明改成晓明，把晓明改成张明。"] {
            let p = CorrectionReviewProposal.make(original: text)
            check(p.draft == nil && p.candidates.isEmpty, "missing or ambiguous target never gets a guessed draft")
        }
        var pending = CorrectionReviewState()
        let first = pending.begin(original: source)
        let secondSource = "联系阿文，把阿文改成阿明。"
        let second = pending.begin(original: secondSource)
        check(!pending.acceptProposal(proposal, token: first) && pending.phase == .loading, "old response cannot revive a new session")
        let secondProposal = CorrectionReviewProposal.make(original: secondSource)
        check(pending.acceptProposal(secondProposal, token: second), "current response accepted")
        check(!pending.confirmManual("  ") && pending.confirmManual("联系阿明。") && pending.finalText == "联系阿明。", "manual edit needs nonempty explicit text")
        check(pending.consumeConfirmed() == "联系阿明。" && pending.consumeConfirmed() == nil && !pending.undo(),
              "confirmed result is handed off at most once")
        let cancelledToken = pending.begin(original: source); pending.cancel()
        check(!pending.acceptProposal(proposal, token: cancelledToken), "late response after cancellation rejected")
        if failures > 0 { print("FAILED: \(failures)"); exit(1) }
        print("Correction review checks passed")
    }
}
