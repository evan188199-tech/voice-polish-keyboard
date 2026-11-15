import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Every URLSession request is intercepted in-process. No network or API key is used.
final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor enum ContentChecks {
    static func run() async {
        let check = KeyboardChecks.check
        let source = "明天有三件事第一联系供应商确认周五交货第二检查二十个样品第三把结果发给小明另外预算不要超过三千块"
        let local = LocalTextProcessor.process(source, vocabulary: "")
        let prepared = DictationTextPreparation(local, mode: .rewrite)
        check(prepared.body.contains("\n1. 联系供应商确认周五交货\n2. 检查20个样品\n3. 把结果发给小明\n\n另外预算不要超过3000块"), "explicit list preserves deadline, name, units and negative budget constraint")
        check(FaithfulTextFormatter.format(prepared.body, mode: .rewrite) == prepared.body, "formatting is idempotent")
        let narration = String(repeating: "今天先检查设备。因为下雨所以不要出发。明天再联系小明。", count: 8)
        let paragraphs = FaithfulTextFormatter.format(narration, mode: .rewrite)
        check(paragraphs.contains("\n\n") && paragraphs.replacingOccurrences(of: "\n", with: "") == narration, "long narration only gains paragraph boundaries")
        for text in ["", "Today do not send 20 samples; the budget is 3000.", "聽日唔好出發，先 check API。", "第一版不要改第二版", "第一名不是第二名", "他说：“第一联系小明第二发货。”"] {
            check(FaithfulTextFormatter.format(text, mode: .rewrite) == text, "conservative no-list fixture: \(text.prefix(12))")
        }
        let code = "第一步修改 /tmp/AH/foo_v2.1.swift，第二步运行 x = 20; 不要删除 API_KEY"
        check(FaithfulTextFormatter.format(code, mode: .coding) == code && LocalTextProcessor.process(code, vocabulary: "") == code, "coding paths, symbols, versions and tokens survive")
        check(LocalTextProcessor.process("Shah has a name", vocabulary: "").contains("Shah"), "filler removal never deletes syllables inside English names")
        let codePreparation = DictationTextPreparation(code, mode: .coding)
        check(!codePreparation.accept(code.replacingOccurrences(of: "x =", with: "x +=")), "code punctuation cannot be changed by cloud formatting")
        let huge = String(repeating: "不要遗漏20个样品，原因是质量要求。", count: 3000)
        let hugeBody = FaithfulTextFormatter.format(huge, mode: .rewrite)
        check(hugeBody.replacingOccurrences(of: "\n", with: "") == huge, "very long local text is never truncated")
        check(!prepared.accept("只需联系供应商。"), "summary/omitted constraints rejected for protected layout")
        check(!prepared.accept(prepared.body.replacingOccurrences(of: "小明", with: "黄晓明")), "provider cannot alter protected list name")
        check(!prepared.accept(prepared.body.replacingOccurrences(of: "不要", with: "要")), "provider cannot drop negation")
        for (raw, changed) in [("温度是-3.5度", "温度是3.5度"),
                               ("温度是-3.5度", "温度是-35度"),
                               ("费用是¥3000", "费用是3000"),
                               ("折扣是20%", "折扣是20"),
                               ("日期2026-11-14", "日期20261114"),
                               ("误差为.5", "误差为5"),
                               ("温度为- 3度", "温度为3度")] {
            let draft = DictationTextPreparation(raw, mode: .rewrite)
            check(draft.accept(raw) && !draft.accept(changed), "short dictation protects signed numbers, decimals, dates and currency")
        }
        let signed = DictationTextPreparation(String(repeating: "请保留以下记录。", count: 18) + "温度-3.5度", mode: .rewrite)
        check(!signed.accept(signed.body.replacingOccurrences(of: "-3.5", with: "3.5")), "long layout rejects lost numeric sign")
        let ask = DictationTextPreparation("3加5是多少", mode: .askLLM)
        check(ask.accept("8"), "answer mode may return a different number")
        for (raw, changed) in [("明天不要发给小明", "明天发给小明"),
                               ("明天发给小明", "明天不要发给小明"),
                               ("不要通知小明但要联系小红", "通知小明但不要联系小红"),
                               ("聽日唔好出發", "聽日出發"),
                               ("我冇收到", "我收到"),
                               ("Do not send it", "Send it"),
                               ("Never send it", "Send it")] {
            let draft = DictationTextPreparation(raw, mode: .rewrite)
            check(draft.accept(raw) && !draft.accept(changed), "short dictation keeps explicit negation and its scope")
        }
        check(DictationTextPreparation("不要超过三千", mode: .askLLM).accept("可以"), "answer mode is not a dictation-preservation mode")
        let hk = ChineseScriptConverter.convert(prepared.body, direction: .toTraditional)
        check(hk.contains("聯繫") && hk.contains("3000"), "Hong Kong script path preserves numeric content")

        let correctionFixtures: [(String, String)] = [
            ("明天联系小明，小明是黄晓明的晓明。", "明天联系晓明。"),
            ("发给张伟，伟是伟大的伟。", "发给张伟。"),
            ("聽日搵小明，小明係黃曉明嘅曉明。", "聽日搵曉明。"),
            ("明天联系李丽，李丽是王丽丽的丽丽。", "明天联系丽丽。"),
            ("不是明天，是后天交货。", "后天交货。")
        ]
        for (raw, expected) in correctionFixtures {
            let result = SpokenCorrection.process(raw, mode: .rewrite)
            check(result.body == expected && result.original == raw, "scoped spoken correction: \(raw.prefix(12))")
            check(SpokenCorrection.process(result.body, mode: .rewrite).body == result.body, "spoken correction is idempotent")
        }
        for text in ["小明是黄晓明的晓明", "他解释说，小明是黄晓明的晓明", "明天联系小明和小明，小明是黄晓明的晓明", "他说‘小明是黄晓明的晓明’", "明天联系小明，小明不是黄晓明的晓明", "明天联系小明，小明是黄晓明的明", "不是所有任务都取消", "send /tmp/x to 小明，小明是黄晓明的晓明", "不要修改已插入的宿主"] {
            check(SpokenCorrection.process(text, mode: .rewrite).body == text, "ambiguous/quoted/negative/no-target correction is preserved")
        }
        let corrected = DictationTextPreparation("明天联系小明，小明是黄晓明的晓明。", mode: .rewrite)
        check(corrected.body == "明天联系晓明。" && !corrected.accept(corrected.original), "correction explanation cannot return through polishing")
        let standalone = DictationTextPreparation("小明是黄晓明的晓明", mode: .rewrite)
        check(standalone.correctionNeedsConfirmation && standalone.body == standalone.original, "standalone correction needs explicit target; no host access")
        let suggestion = SpokenCorrection.suggest(explanation: "小明是黄晓明的晓明", draft: "明天联系小明。")
        check(suggestion?.original == "明天联系小明。" && suggestion?.corrected == "明天联系晓明。", "standalone correction proposes one change in the selected draft")
        for draft in ["明天联系小明和小明。", "明天联系小红。", "他说：\"联系小明\"", "‘联系小明’", "路径 /tmp/小明"] {
            check(SpokenCorrection.suggest(explanation: "小明是黄晓明的晓明", draft: draft) == nil, "ambiguous, absent, quoted or protected draft gets no automatic candidate")
        }
        for explanation in ["他解释说，小明是黄晓明的晓明", "小明不是黄晓明的晓明", "小明是黄晓明的明", "小明是黄晓明的晓明。再发消息"] {
            check(SpokenCorrection.suggest(explanation: explanation, draft: "明天联系小明。") == nil, "ambiguous or instruction-like explanation cannot alter draft")
        }
        check(ChineseScriptConverter.convert(corrected.body, direction: .toTraditional) == "明天聯繫曉明。", "spoken correction supports traditional output")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = APITextPolisher(session: session)
        let settings = PolishingSettings(baseURL: "https://fixture.invalid", modelName: "mock", apiKey: "fixture-only", mode: .rewrite)
        FixtureURLProtocol.payload = try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": prepared.body]]]])
        let good = try! await provider.polish(prepared.body, settings: settings)
        check(prepared.accept(good), "mock provider layout response accepted")
        let numericDraft = DictationTextPreparation("温度是-3.5度", mode: .rewrite)
        FixtureURLProtocol.payload = try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": "温度是3.5度"]]]])
        let changedNumber = try! await provider.polish(numericDraft.body, settings: settings)
        let delivered = numericDraft.accept(changedNumber) ? changedNumber : numericDraft.body
        check(delivered == "温度是-3.5度", "mock provider lost sign falls back to complete local text")
        let negativeDraft = DictationTextPreparation("明天不要发给小明", mode: .rewrite)
        FixtureURLProtocol.payload = try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": "明天发给小明"]]]])
        let changedNegation = try! await provider.polish(negativeDraft.body, settings: settings)
        check(!negativeDraft.accept(changedNegation), "mock provider cannot omit a short dictation's negation")
        FixtureURLProtocol.payload = #"{"choices":[{"finish_reason":"length","message":{"content":"短了"}}]}"#.data(using: .utf8)!
        do { _ = try await provider.polish(prepared.body, settings: settings); check(false, "truncation must throw") }
        catch { check(error as? PolishingError != nil, "mock truncated response triggers local fallback error") }
        FixtureURLProtocol.statusCode = 429
        do { _ = try await provider.polish(prepared.body, settings: settings); check(false, "quota failure must throw") }
        catch { check(true, "mock quota failure keeps local preparation available") }
        FixtureURLProtocol.statusCode = 200
        let requestsBefore = FixtureURLProtocol.requests
        do { _ = try await provider.polish(huge, settings: settings); check(false, "huge input must throw before provider") }
        catch { check(FixtureURLProtocol.requests == requestsBefore, "oversize cloud input falls back without request or clipping") }
    }
}
