import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Production credentials and approvals are provided by the main app. This
/// type reads no credentials itself and stores no configuration on disk.
struct TranslationServiceApproval: Equatable, Sendable {
    let serviceID: String
    let endpoint: String
    let model: String
    let targets: [TranslationTarget]
}
struct TranslationFactoryConfiguration: Sendable {
    let settings: PolishingSettings
    let serviceID: String
    let serviceLabel: String
    let verifiedTargets: [TranslationTarget]
    let approval: TranslationServiceApproval?
    let userEnabled: Bool
    let networkAuthorized: Bool
}
struct TranslationHTTPReply: Sendable {
    let status: Int
    let body: Data
}
protocol TranslationHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> TranslationHTTPReply
}
private final class TranslationRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
/// An ephemeral HTTP transport, constructed only when the caller opts in.
/// Response-size checks occur after URLSession receives bytes, not a streaming cap.
final class URLSessionTranslationTransport: TranslationHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: TranslationRedirectBlocker(), delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> TranslationHTTPReply {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, response.url == request.url else { throw PolishingError.noResponse }
        guard data.count <= 1_048_576 else { throw PolishingError.invalidResponse }
        return TranslationHTTPReply(status: http.statusCode, body: data)
    }
}
/// Translation-only implementation of the project's existing TextPolishing
/// interface. No compatibility retries that collapse system and user roles.
struct StrictTranslationPolisher: TextPolishing {
    let transport: any TranslationHTTPTransport
    func polish(_ raw: String, settings: PolishingSettings) async throws -> String {
        guard raw.utf8.count <= 12_000, let prompt = settings.styleSystemPrompt, !prompt.isEmpty,
              settings.chineseScript == nil, settings.askHistory.isEmpty else { throw PolishingError.invalidResponse }
        guard !settings.apiKey.isEmpty, settings.apiKey.rangeOfCharacter(from: .controlCharacters) == nil else { throw PolishingError.missingAPIKey }
        guard let url = settings.chatCompletionsURL, TranslationServiceFactory.isSafeEndpoint(settings.baseURL) else { throw PolishingError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(settings.timeout, 30))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["model": settings.modelName,
            "messages": [["role": "system", "content": prompt], ["role": "user", "content": raw]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        try Task.checkCancellation()
        let reply = try await transport.send(request)
        try Task.checkCancellation()
        guard reply.status == 200 else { throw PolishingError.httpError(reply.status, "") }
        guard reply.body.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]], choices.count == 1,
              choices[0]["finish_reason"] as? String == "stop" else { throw PolishingError.truncatedResponse }
        guard let text = APITextPolisher.extractAssistantText(from: reply.body), !text.isEmpty else { throw PolishingError.invalidResponse }
        return text
    }
}
private struct UnavailableConfiguredTranslation: TextTranslating {
    let reason: TranslationFailure
    var capability: TranslationCapability { get async {
        TranslationCapability(serviceID: "", serviceLabel: "翻译未启用", isAvailable: false,
                              supportedTargets: [], orderedTargets: TranslationTarget.choices, failure: reason)
    } }
    func translate(_ request: TranslationRequest) async throws -> TranslationEvent { throw reason }
}
/// Actor prevents a duplicate ID from starting multiple network requests and
/// gives the bridge a real cancellation hook. Executor suppresses late replies.
actor ManagedTranslationService: TextTranslating {
    private let service: any TextTranslating
    private let timeoutNanoseconds: UInt64
    private var tasks: [UUID: (UUID, Task<TranslationEvent, Error>)] = [:]
    private var used = Set<UUID>()
    private var revoked = false
    init(service: any TextTranslating, timeoutNanoseconds: UInt64) { self.service = service; self.timeoutNanoseconds = timeoutNanoseconds }
    var capability: TranslationCapability { get async {
        if revoked { return await UnavailableConfiguredTranslation(reason: .notEnabled).capability }
        let value = await service.capability
        return revoked ? await UnavailableConfiguredTranslation(reason: .notEnabled).capability : value
    } }
    func translate(_ request: TranslationRequest) async throws -> TranslationEvent {
        guard !revoked else { throw TranslationFailure.notEnabled }
        let id = request.context.id
        guard !used.contains(id) else { throw TranslationFailure.invalidResult }
        guard used.count < 2_048 else { throw TranslationFailure.unavailable }
        used.insert(id)
        let generation = UUID()
        let operation = Task { try await TranslationRequestExecutor.run(request, service: service, timeoutNanoseconds: timeoutNanoseconds) }
        tasks[id] = (generation, operation)
        defer { if tasks[id]?.0 == generation { tasks[id] = nil } }
        return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }
    func cancel(_ requestID: UUID) async { tasks[requestID]?.1.cancel() }
    /// Cancels pending work locally; requests already received remotely cannot
    /// be recalled. A newly authorized config needs a fresh instance.
    func revoke() { revoked = true; for (_, task) in tasks.values { task.cancel() } }
}
enum TranslationServiceFactory {
    static func isSafeEndpoint(_ base: String) -> Bool {
        guard let parts = URLComponents(string: base), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return false }
        return true
    }
    static func make(configuration: TranslationFactoryConfiguration,
                     transport: (any TranslationHTTPTransport)? = nil) -> any TextTranslating {
        guard configuration.userEnabled else { return UnavailableConfiguredTranslation(reason: .notEnabled) }
        guard configuration.networkAuthorized else { return UnavailableConfiguredTranslation(reason: .unavailable) }
        let settings = configuration.settings
        let expected = TranslationServiceApproval(serviceID: configuration.serviceID, endpoint: settings.baseURL, model: settings.modelName, targets: configuration.verifiedTargets)
        guard configuration.approval == expected,
              configuration.serviceID.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil,
              isSafeEndpoint(settings.baseURL), settings.chatCompletionsURL != nil,
              !settings.modelName.isEmpty, settings.modelName.utf8.count <= 256,
              settings.modelName.rangeOfCharacter(from: .controlCharacters) == nil,
              !settings.apiKey.isEmpty, settings.apiKey.rangeOfCharacter(from: .controlCharacters) == nil,
              !configuration.verifiedTargets.isEmpty, configuration.verifiedTargets.allSatisfy(\.isValid) else {
            return UnavailableConfiguredTranslation(reason: .missingConfiguration)
        }
        let base = ConfiguredTranslationService(provider: StrictTranslationPolisher(transport: transport ?? URLSessionTranslationTransport()), settings: settings,
            serviceID: configuration.serviceID, serviceLabel: configuration.serviceLabel, verifiedTargets: configuration.verifiedTargets,
            userEnabled: true, allowRequests: true)
        return ManagedTranslationService(service: base, timeoutNanoseconds: 30_000_000_000)
    }
}
