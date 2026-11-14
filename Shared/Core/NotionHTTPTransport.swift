import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The app must supply a supported, explicitly authorized credential provider.
/// No implementation or real credential is configured here.
protocol NotionCredentialProvider: Sendable {
    func credential(for sourceID: UUID) async throws -> String?
}
/// Enforces a cumulative cap before appending each received chunk.
struct BoundedNotionBody {
    static let limit = 1_048_576
    private(set) var data = Data()
    mutating func append(_ chunk: Data) throws {
        guard chunk.count <= Self.limit - data.count else { throw NotionPreviewError.invalidResponse }
        data.append(chunk)
    }
}

private final class NotionBoundedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NotionQueryResponse, Error>?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var body = BoundedNotionBody()
    private var response: HTTPURLResponse?
    func run(_ request: URLRequest) async throws -> NotionQueryResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil; configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 20
                configuration.timeoutIntervalForResource = 30
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                let start = lock.withLock {
                    if cancelled { return false }
                    self.continuation = continuation; self.task = task; return true
                }
                if start { task.resume() }
                else { session.invalidateAndCancel(); continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              response.expectedContentLength < 0 || response.expectedContentLength <= Int64(BoundedNotionBody.limit) else {
            completionHandler(.cancel); finish(session, result: .failure(NotionPreviewError.invalidResponse)); return
        }
        lock.withLock { self.response = http }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let ok = lock.withLock { () -> Bool in
            do { try body.append(data); return true } catch { return false }
        }
        if !ok { dataTask.cancel(); finish(session, result: .failure(NotionPreviewError.invalidResponse)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<NotionQueryResponse, Error> = lock.withLock {
            if cancelled { return .failure(CancellationError()) }
            guard error == nil, let response else { return .failure(NotionPreviewError.unavailable) }
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .success(NotionQueryResponse(status: response.statusCode, retryAfter: retry, body: body.data))
        }
        finish(session, result: result)
    }
    private func finish(_ session: URLSession, result: Result<NotionQueryResponse, Error>) {
        let (continuation, finalResult): (CheckedContinuation<NotionQueryResponse, Error>?, Result<NotionQueryResponse, Error>) = lock.withLock {
            let c = self.continuation; self.continuation = nil; self.task = nil
            return (c, cancelled ? .failure(CancellationError()) : result)
        }
        continuation?.resume(with: finalResult)
        session.finishTasksAndInvalidate()
    }
}

/// Opt-in transport. No real credential or live session is configured by the app.
struct NotionHTTPTransport: NotionQueryTransport {
    private let credentialProvider: any NotionCredentialProvider
    init(credentialProvider: any NotionCredentialProvider) { self.credentialProvider = credentialProvider }
    func query(_ query: NotionQueryRequest) async throws -> NotionQueryResponse {
        guard let credential = try await credentialProvider.credential(for: query.sourceID),
              !credential.isEmpty, credential.utf8.count <= 4096,
              credential.rangeOfCharacter(from: .controlCharacters) == nil else { throw NotionPreviewError.permission }
        let request = try Self.request(query, credential: credential)
        try Task.checkCancellation()
        do { return try await NotionBoundedRequest().run(request) }
        catch is CancellationError { throw CancellationError() }
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
