import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor FictionalNotionTransport: NotionQueryTransport {
    private var responses: [NotionQueryResponse]
    private(set) var requests: [NotionQueryRequest] = []
    init(_ responses: [NotionQueryResponse]) { self.responses = responses }
    func query(_ request: NotionQueryRequest) async throws -> NotionQueryResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw NotionPreviewError.unavailable }
        return responses.removeFirst()
    }
    func seen() -> [NotionQueryRequest] { requests }
}
actor PendingNotionTransport: NotionQueryTransport {
    private var pending: CheckedContinuation<NotionQueryResponse, Error>?
    func query(_ request: NotionQueryRequest) async throws -> NotionQueryResponse {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func isPending() -> Bool { pending != nil }
    func resolve(_ response: NotionQueryResponse) { pending?.resume(returning: response); pending = nil }
}
actor FictionalDelay {
    var delays: [TimeInterval] = []
    func record(_ value: TimeInterval) { delays.append(value) }
    func seen() -> [TimeInterval] { delays }
}
@MainActor enum NotionPreviewChecks {
    static func page(_ name: String, more: Bool, cursor: String?) -> Data {
        let root: [String: Any] = ["results": [["object": "page", "properties": [
            "Chosen": ["id": "fixture-prop", "type": "title", "title": [["plain_text": name]]],
            "PrivateIgnored": ["id": "private-fixture", "type": "rich_text", "rich_text": [["plain_text": "不应导入"]]]
        ]]], "has_more": more, "next_cursor": cursor as Any? ?? NSNull()]
        return try! JSONSerialization.data(withJSONObject: root)
    }
    static func run() async {
        let check = KeyboardChecks.check
        let source = UUID()
        let field = NotionPreviewField(propertyID: "fixture-prop", responseName: "Chosen", kind: .privateRoute)
        let first = NotionQueryResponse(status: 200, retryAfter: nil, body: page("虚构路线甲", more: true, cursor: "fiction-cursor"))
        let second = NotionQueryResponse(status: 200, retryAfter: nil, body: page("虚构路线乙", more: false, cursor: nil))
        let transport = FictionalNotionTransport([first, second])
        let reader = NotionPrivatePreviewReader(transport: transport)
        let preview = try! await reader.preview(sourceID: source, fields: [field])
        let seen = await transport.seen()
        check(preview.candidates.map(\.term) == ["虚构路线甲", "虚构路线乙"], "Notion mock paginates only allowlisted terms into preview")
        check(seen.count == 2 && seen[0].cursor == nil && seen[1].cursor == "fiction-cursor" && seen.allSatisfy { $0.propertyIDs == ["fixture-prop"] },
              "Notion mock requests selected properties and next cursor")
        check(!preview.candidates.contains { $0.term == "不应导入" }, "unselected private source field is ignored")
        let throttle = NotionQueryResponse(status: 429, retryAfter: 1, body: Data())
        let delay = FictionalDelay()
        let retryTransport = FictionalNotionTransport([throttle, second])
        let retryReader = NotionPrivatePreviewReader(transport: retryTransport, sleep: { seconds in await delay.record(seconds) })
        _ = try! await retryReader.preview(sourceID: source, fields: [field])
        let delays = await delay.seen()
        check(delays == [1], "rate limit respects retry-after through injected clock")
        let transient = FictionalNotionTransport([NotionQueryResponse(status: 503, retryAfter: nil, body: Data()), second])
        let transientDelay = FictionalDelay()
        _ = try! await NotionPrivatePreviewReader(transport: transient, sleep: { await transientDelay.record($0) }).preview(sourceID: source, fields: [field])
        let transientDelays = await transientDelay.seen()
        check(transientDelays == [0.5], "transient server error retries with bounded backoff")
        let importSession = PrivateMaterialSession()
        await importSession.useDemo("notion-fixture-A")
        let selectedPreview = try! await importSession.previewNotion(sourceID: source, fields: [field],
            reader: NotionPrivatePreviewReader(transport: FictionalNotionTransport([second])))
        check(importSession.privateTerms.isEmpty, "Notion preview never imports without explicit review")
        try! importSession.confirmImport(selectedPreview, selected: [selectedPreview.candidates[0].id],
                                         expectedAccount: "notion-fixture-A", reviewed: true)
        check(importSession.privateTerms.count == 1, "explicitly reviewed mock Notion term enters local session")
        let pendingTransport = PendingNotionTransport()
        let pendingPreview = Task { try await importSession.previewNotion(sourceID: source, fields: [field],
            reader: NotionPrivatePreviewReader(transport: pendingTransport)) }
        while !(await pendingTransport.isPending()) { await Task.yield() }
        await importSession.useDemo("notion-fixture-B")
        await pendingTransport.resolve(second)
        do { _ = try await pendingPreview.value; check(false, "stale account preview must fail") }
        catch { check(importSession.privateTerms.isEmpty, "late Notion preview cannot cross an account switch") }
        let denied = FictionalNotionTransport([first, NotionQueryResponse(status: 403, retryAfter: nil, body: Data())])
        do { _ = try await NotionPrivatePreviewReader(transport: denied).preview(sourceID: source, fields: [field]); check(false, "revoked source must fail") }
        catch { check((error as? NotionPreviewError) == .permission, "permission loss fails entire preview rather than importing partial data") }
        let revokedSession = PrivateMaterialSession()
        await revokedSession.useDemo("revoked-fixture")
        let revokedResponse = FictionalNotionTransport([NotionQueryResponse(status: 403, retryAfter: nil, body: Data())])
        do { _ = try await revokedSession.previewNotion(sourceID: source, fields: [field], reader: NotionPrivatePreviewReader(transport: revokedResponse)); check(false, "denied source must fail") }
        catch { check(revokedSession.account == nil && revokedSession.privateTerms.isEmpty,
                      "unavailable source closes its in-memory account session") }
        let malformed = FictionalNotionTransport([NotionQueryResponse(status: 200, retryAfter: nil, body: page("虚构路线", more: true, cursor: nil))])
        do { _ = try await NotionPrivatePreviewReader(transport: malformed).preview(sourceID: source, fields: [field]); check(false, "missing cursor must fail") }
        catch { check((error as? NotionPreviewError) == .incomplete, "missing continuation never silently truncates") }
        let repeated = FictionalNotionTransport([first, first])
        do { _ = try await NotionPrivatePreviewReader(transport: repeated).preview(sourceID: source, fields: [field]); check(false, "repeated cursor must fail") }
        catch { check((error as? NotionPreviewError) == .incomplete, "repeated cursor fails instead of looping") }
        let tooManyPieces: [String: Any] = ["results": [["object": "page", "properties": [
            "Chosen": ["id": "fixture-prop", "type": "title", "title": Array(repeating: ["plain_text": "虚构"], count: 25)]
        ]]], "has_more": false, "next_cursor": NSNull()]
        let fragmented = FictionalNotionTransport([NotionQueryResponse(status: 200, retryAfter: nil,
            body: try! JSONSerialization.data(withJSONObject: tooManyPieces))])
        do { _ = try await NotionPrivatePreviewReader(transport: fragmented).preview(sourceID: source, fields: [field]); check(false, "possibly truncated property must fail") }
        catch { check((error as? NotionPreviewError) == .incomplete, "possibly paginated property cannot silently truncate") }
        let badRate = FictionalNotionTransport([NotionQueryResponse(status: 429, retryAfter: nil, body: Data())])
        do { _ = try await NotionPrivatePreviewReader(transport: badRate).preview(sourceID: source, fields: [field]); check(false, "missing retry-after must fail") }
        catch { check((error as? NotionPreviewError) == .rateLimited, "rate limiting without safe retry time stops") }
        var bounded = BoundedNotionBody()
        try! bounded.append(Data(repeating: 1, count: BoundedNotionBody.limit - 1))
        try! bounded.append(Data([2]))
        check(bounded.data.count == BoundedNotionBody.limit, "stream accepts exactly the cumulative byte limit")
        do { try bounded.append(Data([3])); check(false, "oversized next chunk must fail") }
        catch { check(bounded.data.count == BoundedNotionBody.limit, "stream rejects oversize before appending") }
        var oversized = BoundedNotionBody()
        do { try oversized.append(Data(repeating: 7, count: BoundedNotionBody.limit + 1)); check(false, "oversized first chunk must fail") }
        catch { check(oversized.data.isEmpty, "oversize first chunk leaves bounded buffer empty") }
        let request = NotionQueryRequest(sourceID: source, propertyIDs: ["fixture-prop"], cursor: "fiction-cursor", pageSize: 100)
        let prepared = try! NotionHTTPTransport.request(request, credential: "fictional-token")
        let components = URLComponents(url: prepared.url!, resolvingAgainstBaseURL: false)!
        check(components.scheme == "https" && components.host == "api.notion.com" && prepared.httpMethod == "POST",
              "Notion request is confined to official HTTPS query endpoint")
        check(components.queryItems?.first?.name == "filter_properties" && prepared.value(forHTTPHeaderField: "Notion-Version") == "2026-03-11",
              "Notion request pins API version and field filter")
        do { _ = try NotionHTTPTransport.request(request, credential: "bad\nfixture"); check(false, "invalid token must fail") }
        catch { check(true, "credential header injection is rejected") }
        let disabled = NotionPrivatePreviewReader()
        do { _ = try await disabled.preview(sourceID: source, fields: [field]); check(false, "unconfigured transport must fail") }
        catch { check((error as? NotionPreviewError) == .unavailable, "real Notion transport is not configured by default") }
    }
}
