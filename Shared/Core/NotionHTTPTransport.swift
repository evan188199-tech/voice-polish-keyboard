import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The app must supply a supported, explicitly authorized credential provider.
/// No implementation or real credential is configured here.
protocol NotionCredentialProvider: Sendable {
    func credential(for sourceID: UUID) async throws -> String?
}
private final class NotionRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Configurable REST transport, deliberately not instantiated by app UI.
/// Redirects, cookies and caches are disabled; errors never include source IDs or credentials.
struct NotionHTTPTransport: NotionQueryTransport {
    private let credentialProvider: any NotionCredentialProvider
    private let session: URLSession
    init(credentialProvider: any NotionCredentialProvider) {
        self.credentialProvider = credentialProvider
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config, delegate: NotionRedirectBlocker(), delegateQueue: nil)
    }
    func query(_ query: NotionQueryRequest) async throws -> NotionQueryResponse {
        guard let credential = try await credentialProvider.credential(for: query.sourceID),
              !credential.isEmpty, credential.utf8.count <= 4096,
              credential.rangeOfCharacter(from: .controlCharacters) == nil else { throw NotionPreviewError.permission }
        let request = try Self.request(query, credential: credential)
        do {
            let (body, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, body.count <= 1_048_576 else { throw NotionPreviewError.invalidResponse }
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return NotionQueryResponse(status: response.statusCode, retryAfter: retry, body: body)
        } catch is CancellationError { throw CancellationError() }
        catch let error as NotionPreviewError { throw error }
        catch { throw NotionPreviewError.unavailable }
    }
    static func request(_ query: NotionQueryRequest, credential: String) throws -> URLRequest {
        guard !credential.isEmpty, credential.utf8.count <= 4096, credential.rangeOfCharacter(from: .controlCharacters) == nil,
              query.propertyIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && $0.rangeOfCharacter(from: .controlCharacters) == nil }),
              query.pageSize > 0, query.pageSize <= 100, !query.propertyIDs.isEmpty,
              query.propertyIDs.count <= 3 else { throw NotionPreviewError.invalidResponse }
        var components = URLComponents()
        components.scheme = "https"; components.host = "api.notion.com"
        components.path = "/v1/data_sources/\(query.sourceID.uuidString.lowercased())/query"
        components.queryItems = query.propertyIDs.map { URLQueryItem(name: "filter_properties", value: $0) }
        guard let url = components.url else { throw NotionPreviewError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue(query.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["page_size": query.pageSize]
        if let cursor = query.cursor { body["start_cursor"] = cursor }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}
