import Foundation

// Calls shipping value types, not a replacement delivery implementation.
@main struct DeliveryAcceptance {
    static func main() {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1; print("PASS \(name)") }
            else { failed += 1; print("FAIL \(name)") }
        }
        func context() -> TranslationContext {
            TranslationContext(target: .english, sourceKind: .typed,
                deliveryMode: .preview, consentServiceID: "fixture-no-network")
        }
        func draft(_ c: TranslationContext) -> TranslationDraft {
            var d = TranslationDraft(); d.editSource("请明天来"); _ = d.begin(c); return d
        }
        func event(_ c: TranslationContext, failure: TranslationFailure? = nil) -> TranslationEvent {
            TranslationEvent(context: c, source: "请明天来", translation: "Come tomorrow.", failure: failure)
        }
        do {
            let c = context(); var d = draft(c)
            d.cancel()
            check("取消后拒绝迟到成功", !d.receive(event(c)))
            check("取消后禁止消费译文且保留原文", d.consumePreview() == nil && d.source == "请明天来")
        }
        do {
            let old = context(); var d = draft(old); d.cancel()
            let next = context(); _ = d.begin(next)
            check("新请求拒绝旧会话结果", !d.receive(event(old)) && d.requestID == next.id && d.isBusy)
            check("新请求可完成一次", d.receive(event(next)) && d.consumePreview() == "Come tomorrow." && d.consumePreview() == nil)
        }
        do {
            let c = context(); var d = draft(c); _ = d.receive(event(c)); _ = d.consumePreview()
            _ = d.receive(event(c))
            check("重复完成事件不得重新开放已消费输出", d.consumePreview() == nil)
        }
        do {
            let c = context(); var d = draft(c); _ = d.receive(event(c))
            d.fail(.timeout, id: c.id)
            check("成功后迟到失败不得覆盖成功终态", d.translation == "Come tomorrow." && d.failure == nil)
        }
        do {
            let c = context(); var d = draft(c); d.fail(.timeout, id: c.id)
            _ = d.receive(event(c))
            check("失败后迟到成功不得重新开放交付", d.consumePreview() == nil && d.failure == .timeout)
        }
        do {
            let old = context(); var d = draft(old)
            _ = d.receive(event(old, failure: .truncated))
            check("部分输出不得交付且原文可恢复", d.consumePreview() == nil && d.savedSource == "请明天来" && d.source == "请明天来")
            let retry = context(); _ = d.begin(retry)
            check("重试拒绝前次部分请求的迟到结果", !d.receive(event(old)))
            _ = d.receive(event(retry))
            check("部分失败后的重试仅消费一次", d.consumePreview() == "Come tomorrow." && d.consumePreview() == nil)
            d.restoreSource()
            check("恢复原文后禁止再消费旧输出", d.source == "请明天来" && d.consumePreview() == nil && !d.receive(event(retry)))
        }
        do {
            var g = TranslationDeliveryGuard(); let id = UUID(); let doc = UUID()
            g.capture(id, document: doc, visible: true, connected: true, continuityVerified: true)
            g.abandon(id)
            check("取消绑定后禁止插入许可", !g.consume(id, document: doc, visible: true, connected: true))
            g.capture(id, document: doc, visible: true, connected: true, continuityVerified: true)
            g.invalidate()
            check("切换会话后禁止旧绑定插入", !g.consume(id, document: doc, visible: true, connected: true))
            g.capture(id, document: doc, visible: true, connected: true, continuityVerified: true)
            check("同一绑定最多一次插入许可", g.consume(id, document: doc, visible: true, connected: true) && !g.consume(id, document: doc, visible: true, connected: true))
            g.capture(id, document: doc, visible: true, connected: true, continuityVerified: true)
            check("错误宿主文档禁止交付且消费许可", !g.consume(id, document: UUID(), visible: true, connected: true) && !g.consume(id, document: doc, visible: true, connected: true))
        }
        do {
            var review = CorrectionReviewState(); let original = "请明天来"
            let token = review.begin(original: original); review.cancel()
            check("纠错取消后拒绝迟到建议", !review.acceptProposal(.make(original: original), token: token) && review.consumeConfirmed() == nil)
            let next = review.begin(original: original)
            _ = review.acceptProposal(.make(original: original), token: next)
            _ = review.keepOriginal()
            check("确认原文最多消费一次", review.consumeConfirmed() == original && review.consumeConfirmed() == nil)
        }
        print("DeliveryAcceptance: \(passed) passed, \(failed) failed; production value types only; no device/host insertion verified")
        if failed > 0 { exit(1) }
    }
}
