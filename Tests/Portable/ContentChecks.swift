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
        let huge = String(repeating: "不要遗漏20个样品，原因是质量要求。", count: 3000)
        let hugeBody = FaithfulTextFormatter.format(huge, mode: .rewrite)
        check(hugeBody.replacingOccurrences(of: "\n", with: "") == huge, "very long local text is never truncated")
        check(!prepared.accept("只需联系供应商。"), "summary/omitted constraints rejected for protected layout")
        check(!prepared.accept(prepared.body.replacingOccurrences(of: "小明", with: "黄晓明")), "provider cannot alter protected list name")
        check(!prepared.accept(prepared.body.replacingOccurrences(of: "不要", with: "要")), "provider cannot drop negation")
        let hk = ChineseScriptConverter.convert(prepared.body, direction: .toTraditional)
        check(hk.contains("聯繫") && hk.contains("3000"), "Hong Kong script path preserves numeric content")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = APITextPolisher(session: session)
        let settings = PolishingSettings(baseURL: "https://fixture.invalid", modelName: "mock", apiKey: "fixture-only", mode: .rewrite)
        FixtureURLProtocol.payload = try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": prepared.body]]]])
        let good = try! await provider.polish(prepared.body, settings: settings)
        check(prepared.accept(good), "mock provider layout response accepted")
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
