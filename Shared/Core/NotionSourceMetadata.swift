import Foundation

struct NotionSourceField: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let type: String
}
protocol NotionMetadataTransport: Sendable {
    func metadata(sourceID: UUID) async throws -> NotionQueryResponse
}
struct DisabledNotionMetadataTransport: NotionMetadataTransport {
    func metadata(sourceID: UUID) async throws -> NotionQueryResponse { throw NotionPreviewError.unavailable }
}
struct NotionSourceMetadataReader: Sendable {
    let transport: any NotionMetadataTransport
    init(transport: any NotionMetadataTransport = DisabledNotionMetadataTransport()) { self.transport = transport }
    func fields(sourceID: UUID) async throws -> [NotionSourceField] {
        let response = try await transport.metadata(sourceID: sourceID)
        if [401, 403, 404].contains(response.status) { throw NotionPreviewError.permission }
        if response.status == 429 { throw NotionPreviewError.rateLimited }
        guard response.status == 200, response.body.count <= 1_048_576,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              json["object"] as? String == "data_source", let rawID = json["id"] as? String,
              UUID(uuidString: rawID) == sourceID,
              json["has_more"] == nil, json["next_cursor"] == nil,
              let properties = json["properties"] as? [String: Any], properties.count <= 1000 else { throw NotionPreviewError.invalidResponse }
        var result: [NotionSourceField] = []; var ids = Set<String>()
        for (name, raw) in properties {
            guard let property = raw as? [String: Any], let id = property["id"] as? String,
                  let type = property["type"] as? String, !id.isEmpty, id.utf8.count <= 128,
                  !name.isEmpty, name.utf8.count <= 128,
                  id.rangeOfCharacter(from: .controlCharacters) == nil,
                  name.rangeOfCharacter(from: .controlCharacters) == nil,
                  ids.insert(id).inserted else { throw NotionPreviewError.invalidResponse }
            if type == "title" || type == "rich_text" { result.append(NotionSourceField(id: id, name: name, type: type)) }
        }
        return result.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}
