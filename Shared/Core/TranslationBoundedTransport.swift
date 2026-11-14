import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One isolated session per request. This bounds the application's accumulated
/// response bytes, not transient URLSession/kernel buffers or remote retention.
final class URLSessionTranslationTransport: TranslationHTTPTransport, @unchecked Sendable {
    private let deadlineNanoseconds: UInt64
#if TRANSLATION_TRANSPORT_TESTING
    private let testProtocolClasses: [AnyClass]?
    init(testProtocolClasses: [AnyClass], deadlineNanoseconds: UInt64) {
        self.testProtocolClasses = testProtocolClasses; self.deadlineNanoseconds = deadlineNanoseconds
    }
#endif
    init() {
#if TRANSLATION_TRANSPORT_TESTING
        self.testProtocolClasses = nil
#endif
        self.deadlineNanoseconds = 30_000_000_000
    }
    func send(_ request: URLRequest) async throws -> TranslationHTTPReply {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
#if TRANSLATION_TRANSPORT_TESTING
        if let testProtocolClasses { configuration.protocolClasses = testProtocolClasses }
#endif
        return try await TranslationBoundedRequest(deadlineNanoseconds: deadlineNanoseconds).run(request, configuration: configuration)
    }
}

/// Internal delegate is exposed for a local no-network redirect contract test.
final class TranslationBoundedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let limit = 1_048_576
    private let lock = NSLock()
    private let deadlineNanoseconds: UInt64
    private var continuation: CheckedContinuation<TranslationHTTPReply, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timer: Task<Void, Never>?
    private var finished = false
    private var response: HTTPURLResponse?
    private var body = Data()
    private var expectedURL: URL?
    init(deadlineNanoseconds: UInt64) { self.deadlineNanoseconds = deadlineNanoseconds }

    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> TranslationHTTPReply {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                let installed = lock.withLock { () -> Bool in
                    guard !finished else { return false }
                    self.continuation = continuation; self.session = session; self.task = task; self.expectedURL = request.url
                    return true
                }
                guard installed else { session.invalidateAndCancel(); continuation.resume(throwing: CancellationError()); return }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: self?.deadlineNanoseconds ?? 0) } catch { return }
                    self?.finish(.failure(PolishingError.timeout), cancel: true)
                }
                let alreadyFinished = lock.withLock { () -> Bool in
                    guard !finished else { return true }
                    self.timer = timer; return false
                }
                if alreadyFinished { timer.cancel() } else { task.resume() }
            }
        } onCancel: { self.finish(.failure(CancellationError()), cancel: true) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let expected = lock.withLock { expectedURL }
        guard let http = response as? HTTPURLResponse, response.url == expected,
              response.expectedContentLength < 0 || response.expectedContentLength <= Int64(Self.limit) else {
            finish(.failure(PolishingError.invalidResponse), cancel: true); completionHandler(.cancel); return
        }
        // Some Foundation implementations report an unknown expected length even
        // when a Content-Length header exists (including local URLProtocol tests).
        if let header = http.value(forHTTPHeaderField: "Content-Length") {
            guard let declared = Int64(header.trimmingCharacters(in: .whitespacesAndNewlines)),
                  declared >= 0, declared <= Int64(Self.limit) else {
                finish(.failure(PolishingError.invalidResponse), cancel: true); completionHandler(.cancel); return
            }
        }
        let valid = lock.withLock { () -> Bool in
            guard !finished else { return false }; self.response = http; return true
        }
        completionHandler(valid ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let valid = lock.withLock { () -> Bool in
            guard !finished, data.count <= Self.limit - body.count else { return false }
            body.append(data); return true
        }
        if !valid { finish(.failure(PolishingError.invalidResponse), cancel: true) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<TranslationHTTPReply, Error> = lock.withLock {
            if let error { return .failure(error) }
            guard let response else { return .failure(PolishingError.noResponse) }
            return .success(TranslationHTTPReply(status: response.statusCode, body: body))
        }
        finish(result, cancel: false)
    }
    private func finish(_ result: Result<TranslationHTTPReply, Error>, cancel: Bool) {
        let captured: (CheckedContinuation<TranslationHTTPReply, Error>?, URLSession?, URLSessionDataTask?, Task<Void, Never>?)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let value = (continuation, session, task, timer)
            continuation = nil; session = nil; task = nil; timer = nil
            body.removeAll(keepingCapacity: false)
            return value
        }
        guard let captured else { return }
        captured.3?.cancel()
        if cancel { captured.2?.cancel(); captured.1?.invalidateAndCancel() }
        else { captured.1?.finishTasksAndInvalidate() }
        captured.0?.resume(with: result)
    }
}
