import Foundation

/// Transport is deliberately injected; no production login, credential store,
/// session or network call is configured by this module.
struct NotionQueryRequest: Sendable, Equatable {
    let sourceID: UUID
    let propertyIDs: [String]
    let cursor: String?
    let pageSize: Int
    let apiVersion: String = "2026-03-11"
}
struct NotionQueryResponse: Sendable {
    let status: Int
    let retryAfter: TimeInterval?
    let body: Data
}
protocol NotionQueryTransport: Sendable {
    func query(_ request: NotionQueryRequest) async throws -> NotionQueryResponse
}
struct DisabledNotionQueryTransport: NotionQueryTransport {
    func query(_ request: NotionQueryRequest) async throws -> NotionQueryResponse { throw NotionPreviewError.unavailable }
}
enum NotionPreviewError: Error, Equatable { case unavailable, permission, rateLimited, invalidResponse, incomplete, limit }
struct NotionPreviewField: Sendable, Equatable {
    let propertyID: String
    let responseName: String
    let kind: PrivateTermCandidate.Kind
}

/// Retrieves selected properties only, returns a preview and never imports it.
/// See Notion data source query and pagination docs; credentials stay in a future transport.
struct NotionPrivatePreviewReader: Sendable {
    let transport: any NotionQueryTransport
    let sleep: @Sendable (TimeInterval) async throws -> Void
    init(transport: any NotionQueryTransport = DisabledNotionQueryTransport(),
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) { self.transport = transport; self.sleep = sleep }

    func preview(sourceID: UUID, fields: [NotionPreviewField]) async throws -> TermImportPreview {
        guard !fields.isEmpty, fields.count <= 3,
              fields.allSatisfy({ !$0.propertyID.isEmpty && $0.propertyID.utf8.count <= 128 && !$0.responseName.isEmpty && $0.responseName.utf8.count <= 128 }),
              Set(fields.map(\.propertyID)).count == fields.count else { throw NotionPreviewError.invalidResponse }
        var rows: [[String: String]] = []
        var cursor: String?
        var seenCursors = Set<String>()
        for _ in 0..<50 {
            try Task.checkCancellation()
            let request = NotionQueryRequest(sourceID: sourceID, propertyIDs: fields.map(\.propertyID), cursor: cursor, pageSize: 100)
            var attempts = 0
            var response = try await transport.query(request)
            while (response.status == 429 || [500, 502, 503, 504].contains(response.status)) && attempts < 2 {
                let delay: TimeInterval
                if response.status == 429 {
                    guard let value = response.retryAfter, value.isFinite, value >= 0, value <= 30 else { throw NotionPreviewError.rateLimited }
                    delay = value
                } else { delay = 0.5 * Double(attempts + 1) }
                attempts += 1; try await sleep(delay); try Task.checkCancellation()
                response = try await transport.query(request)
            }
            if [401, 403, 404].contains(response.status) { throw NotionPreviewError.permission }
            if response.status == 429 { throw NotionPreviewError.rateLimited }
            guard response.status == 200, response.body.count <= 1_048_576,
                  let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
                  let results = json["results"] as? [[String: Any]], results.count <= 100,
                  let hasMore = json["has_more"] as? Bool else {
                throw NotionPreviewError.invalidResponse
            }
            for page in results {
                guard page["object"] as? String == "page", let properties = page["properties"] as? [String: Any] else { throw NotionPreviewError.invalidResponse }
                for field in fields {
                    guard let property = properties[field.responseName] as? [String: Any],
                          property["id"] as? String == field.propertyID,
                          let type = property["type"] as? String, ["title", "rich_text"].contains(type),
                          let pieces = property[type] as? [[String: Any]], pieces.count < 25 else { throw NotionPreviewError.incomplete }
                    var text = ""
                    for piece in pieces {
                        guard let plain = piece["plain_text"] as? String else { throw NotionPreviewError.incomplete }
                        text += plain
                        guard text.utf8.count <= 2_000 else { throw NotionPreviewError.limit }
                    }
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        rows.append(["term": text, "kind": field.kind.rawValue])
                        guard rows.count <= 1_000 else { throw NotionPreviewError.limit }
                    }
                }
            }
            guard hasMore else {
                guard json["next_cursor"] == nil || json["next_cursor"] is NSNull else { throw NotionPreviewError.incomplete }
                let payload = try JSONSerialization.data(withJSONObject: ["terms": rows])
                return try TermImportPreview.parse(payload)
            }
            guard let next = json["next_cursor"] as? String, !next.isEmpty, next.utf8.count <= 1024,
                  seenCursors.insert(next).inserted else { throw NotionPreviewError.incomplete }
            cursor = next
        }
        throw NotionPreviewError.limit
    }
}
