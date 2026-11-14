import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One prior user/assistant exchange for ask-mode follow-up.
struct AskConversationTurn: Sendable, Equatable {
    let user: String
    let assistant: String
}

protocol TextPolishing: Sendable {
    func polish(_ raw: String, settings: PolishingSettings) async throws -> String
}

struct PolishingSettings: Sendable {
    let baseURL: String
    let modelName: String
    let apiKey: String
    let timeout: TimeInterval
    let mode: PolishMode
    /// Optional local style profile prompt for non-answer polishing modes.
    let styleSystemPrompt: String?

    let chineseScript: ChineseScriptPreference?
    /// Prior ask turns for serial follow-up; ignored by non-ask modes.
    let askHistory: [AskConversationTurn]

    init(
        baseURL: String,
        modelName: String,
        apiKey: String,
        timeout: TimeInterval = AppConstants.polishingTimeout,
        mode: PolishMode = .default,
        chineseScript: ChineseScriptPreference? = nil,
        askHistory: [AskConversationTurn] = [],
        styleSystemPrompt: String? = nil
    ) {
        self.baseURL = Self.normalizeBaseURL(baseURL)
        self.modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mode = mode
        let defaultTimeout = mode == .askLLM ? 15.0 : 10.0
        self.timeout = max(timeout, defaultTimeout)
        self.chineseScript = chineseScript
        self.askHistory = askHistory
        self.styleSystemPrompt = styleSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Accepts OpenAI-style roots (`https://api.openai.com`), roots already ending in `/v1`,
    /// or full chat-completions endpoints. Always produces a root without trailing `/v1`.
    static func normalizeBaseURL(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }

        let chatSuffix = "/chat/completions"
        if url.lowercased().hasSuffix(chatSuffix) {
            url = String(url.dropLast(chatSuffix.count))
            while url.hasSuffix("/") { url.removeLast() }
        }

        // Common provider paste: `.../v1` should not become `.../v1/v1/chat/completions`.
        if url.count >= 3 {
            let lower = url.lowercased()
            if lower.hasSuffix("/v1") {
                url = String(url.dropLast(3))
                while url.hasSuffix("/") { url.removeLast() }
            }
        }
        return url
    }

    /// Requires absolute http(s) base URL with a host.
    var chatCompletionsURL: URL? {
        guard !baseURL.isEmpty else { return nil }
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard url.host != nil else { return nil }
        return url
    }
}

enum PolishAvailabilityResult: Equatable, Sendable {
    case success(latencyMs: Int)
    case failure(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .success(let ms):
            return "模型可用（\(ms) ms）"
        case .failure(let reason):
            return reason
        }
    }
}

final class APITextPolisher: TextPolishing, @unchecked Sendable {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    private let probeSystemPrompt = "Reply with exactly: ok"

    func polish(_ raw: String, settings: PolishingSettings) async throws -> String {
        // Avoid exceeding the existing response budget. Preserve the entire local text;
        // never silently send a clipped prefix or treat a truncated response as success.
        guard raw.utf8.count <= 12_000 else { throw PolishingError.inputTooLong }
        let basePrompt = settings.styleSystemPrompt.flatMap { $0.isEmpty ? nil : $0 }
            ?? settings.mode.systemPrompt
        let prompt = settings.chineseScript.map { script in
            basePrompt + "\n" + (script == .traditionalHK ? "請用香港繁體中文輸出。（繁體字，非簡體。）" : "请用简体中文输出。")
        } ?? basePrompt
        if settings.mode != .askLLM {
            return try await chatCompletion(
                userText: raw,
                systemPrompt: prompt,
                settings: settings,
                maxTokens: 4096,
                temperature: settings.mode.temperature
            )
        }

        var lastError: Error?
        for attempt in 0..<2 {
            do {
                let content = try await chatCompletion(
                    userText: raw,
                    systemPrompt: prompt,
                    settings: settings,
                    maxTokens: 4096,
                    temperature: settings.mode.temperature,
                    askHistory: settings.askHistory
                )
                return try AskAnswerParser.parse(content, sourceText: raw)
            } catch {
                lastError = error
                if attempt == 0, AskAnswerParser.isRetryable(error) {
                    continue
                }
                throw error
            }
        }
        throw lastError ?? PolishingError.noResponse
    }

    /// Exposed for unit tests.
    static func systemPrompt(for mode: PolishMode) -> String {
        mode.systemPrompt
    }

    /// Lightweight connectivity / credential probe for the settings screen.
    func testAvailability(settings: PolishingSettings) async -> PolishAvailabilityResult {
        if settings.apiKey.isEmpty {
            return .failure("请先保存 API Key。")
        }
        if settings.chatCompletionsURL == nil {
            return .failure("API 地址无效，请检查设置。")
        }
        if settings.modelName.isEmpty {
            return .failure("模型名称不能为空。")
        }

        let probeSettings = PolishingSettings(
            baseURL: settings.baseURL,
            modelName: settings.modelName,
            apiKey: settings.apiKey,
            timeout: min(settings.timeout, AppConstants.polishingProbeTimeout)
        )
        let started = Date()
        do {
            // Reasoning models may spend small token budgets on thinking and return
            // empty `content`. Availability only needs a successful chat response.
            _ = try await chatCompletion(
                userText: "ping",
                systemPrompt: probeSystemPrompt,
                settings: probeSettings,
                maxTokens: 64,
                temperature: 0,
                allowEmptyContent: true
            )
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return .success(latencyMs: max(ms, 1))
        } catch let error as PolishingError {
            return .failure(error.errorDescription ?? "测试失败。")
        } catch let error as URLError where error.code == .timedOut {
            return .failure("连接超时（\(Int(probeSettings.timeout)) 秒）。")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private enum RequestShape {
        case classic
        case completionTokensNoTemperature
        case messagesOnly
        case userOnly
    }

    private func chatCompletion(
        userText: String,
        systemPrompt: String,
        settings: PolishingSettings,
        maxTokens: Int,
        temperature: Double,
        allowEmptyContent: Bool = false,
        askHistory: [AskConversationTurn] = []
    ) async throws -> String {
        guard settings.chatCompletionsURL != nil else { throw PolishingError.invalidURL }

        var lastError: Error?
        for shape in [RequestShape.classic, .completionTokensNoTemperature, .messagesOnly, .userOnly] {
            do {
                return try await performChatCompletion(
                    userText: userText,
                    systemPrompt: systemPrompt,
                    settings: settings,
                    maxTokens: maxTokens,
                    temperature: temperature,
                    shape: shape,
                    allowEmptyContent: allowEmptyContent,
                    askHistory: askHistory
                )
            } catch let error as PolishingError {
                lastError = error
                if case .httpError(let code, let body) = error, code == 400, shouldRetry(body: body, shape: shape) {
                    continue
                }
                throw error
            } catch {
                throw error
            }
        }
        throw lastError ?? PolishingError.noResponse
    }

    private func shouldRetry(body: String, shape: RequestShape) -> Bool {
        guard shape != .userOnly else { return false }
        let lower = body.lowercased()
        // Wrong model name is not fixed by reshaping the request body.
        if lower.contains("unsupported model") {
            return false
        }
        // Provider-specific parameter / request-shape complaints.
        return lower.contains("unsupported")
            || lower.contains("max_tokens")
            || lower.contains("temperature")
            || lower.contains("invalid_request")
            || lower.contains("unknown parameter")
            || lower.contains("not supported")
            || lower.contains("system")
            || lower.contains("role")
    }

    private func performChatCompletion(
        userText: String,
        systemPrompt: String,
        settings: PolishingSettings,
        maxTokens: Int,
        temperature: Double,
        shape: RequestShape,
        allowEmptyContent: Bool,
        askHistory: [AskConversationTurn] = []
    ) async throws -> String {
        guard let url = settings.chatCompletionsURL else { throw PolishingError.invalidURL }

        let messages = Self.buildMessages(
            userText: userText,
            systemPrompt: systemPrompt,
            shape: shape,
            askHistory: askHistory
        )

        var body: [String: Any] = [
            "model": settings.modelName,
            "messages": messages
        ]
        switch shape {
        case .classic:
            body["temperature"] = temperature
            body["max_tokens"] = maxTokens
        case .completionTokensNoTemperature:
            body["max_completion_tokens"] = maxTokens
        case .messagesOnly, .userOnly:
            break
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = settings.timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw PolishingError.timeout
        }

        guard let httpResponse = response as? HTTPURLResponse else { throw PolishingError.noResponse }
        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw PolishingError.httpError(httpResponse.statusCode, bodyText)
        }

        try Self.validateCompletion(data)
        if let content = Self.extractAssistantText(from: data) {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        // Probe: a valid 200 chat response proves the model/key/path even if content is empty.
        if allowEmptyContent, Self.hasChatChoices(in: data) {
            return ""
        }
        throw PolishingError.invalidResponse
    }


    private static func buildMessages(
        userText: String,
        systemPrompt: String,
        shape: RequestShape,
        askHistory: [AskConversationTurn]
    ) -> [[String: String]] {
        var turns: [[String: String]] = []
        for item in askHistory {
            let user = item.user.trimmingCharacters(in: .whitespacesAndNewlines)
            let assistant = item.assistant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty, !assistant.isEmpty else { continue }
            turns.append(["role": "user", "content": user])
            turns.append(["role": "assistant", "content": assistant])
        }

        switch shape {
        case .userOnly:
            var flat = systemPrompt
            if !turns.isEmpty {
                flat += "\n\n以下是此前对话（请在此基础上继续回复）："
                for message in turns {
                    let roleLabel = message["role"] == "assistant" ? "助手" : "用户"
                    let content = message["content"] ?? ""
                    flat += "\n" + roleLabel + "：" + content
                }
            }
            flat += "\n\n" + userText
            return [["role": "user", "content": flat]]
        default:
            var messages: [[String: String]] = [
                ["role": "system", "content": systemPrompt]
            ]
            messages.append(contentsOf: turns)
            messages.append(["role": "user", "content": userText])
            return messages
        }
    }

    /// Supports plain string content and multi-part content arrays used by some omni models.
    /// Empty / whitespace-only content is treated as missing (reasoning models often return null content first).
    static func extractAssistantText(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first
        else { return nil }

        if let message = first["message"] as? [String: Any] {
            if let content = message["content"] as? String {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return content }
            }
            if let parts = message["content"] as? [[String: Any]] {
                let texts = parts.compactMap { part -> String? in
                    if let text = part["text"] as? String { return text }
                    if let text = part["content"] as? String { return text }
                    return nil
                }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !texts.isEmpty {
                    return texts.joined()
                }
            }
        }
        if let text = first["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return text }
        }
        return nil
    }

    static func validateCompletion(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]], let first = choices.first else { return }
        if let reason = first["finish_reason"] as? String, ["length", "max_tokens", "content_filter"].contains(reason) {
            throw PolishingError.truncatedResponse
        }
    }

    static func hasChatChoices(in data: Data) -> Bool {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]]
        else { return false }
        return !choices.isEmpty
    }
}

enum PolishingError: Error, LocalizedError {
    case inputTooLong
    case truncatedResponse
    case contentChanged
    case invalidURL
    case noResponse
    case timeout
    case missingAPIKey
    case httpError(Int, String)
    case invalidResponse
    /// Ask mode returned empty/malformed/echo content.
    case invalidAskAnswer

    var errorDescription: String? {
        switch self {
        case .inputTooLong: return "文本过长，保留完整本地整理结果。"
        case .truncatedResponse: return "云端返回不完整，保留完整本地结果。"
        case .contentChanged: return "云端改动超出保真整理范围，已保留本地结果。"
        case .invalidURL: return "API 地址无效，请检查设置。"
        case .noResponse: return "API 无响应。"
        case .timeout: return "API 请求超时。"
        case .missingAPIKey: return "请先保存 API Key。"
        case .httpError(let code, let body):
            if body.isEmpty {
                return "API 返回错误 (\(code))。"
            }
            let snippet = Self.prettyErrorSnippet(body)
            let lower = snippet.lowercased()
            if lower.contains("unsupported model") {
                return "模型不被此接口支持：\(snippet)。请改用列表中的文本模型（如 mimo-v2.5）。"
            }
            return "API 返回错误 (\(code))：\(snippet)"
        case .invalidResponse: return "API 返回格式异常。"
        case .invalidAskAnswer: return "问答结果无效，请重试。"
        }
    }

    private static func prettyErrorSnippet(_ body: String) -> String {
        // Prefer nested message field when present.
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any] {
                let message = (error["message"] as? String)
                    ?? (error["msg"] as? String)
                    ?? ""
                let type = (error["type"] as? String) ?? ""
                let combined = [type, message].filter { !$0.isEmpty }.joined(separator: ": ")
                if !combined.isEmpty {
                    return clip(combined.replacingOccurrences(of: "\n", with: " "), limit: 220)
                }
            }
            if let message = json["message"] as? String, !message.isEmpty {
                return clip(message.replacingOccurrences(of: "\n", with: " "), limit: 220)
            }
        }
        let flat = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clip(flat, limit: 220)
    }

    private static func clip(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

/// Internal ask-mode envelope helpers: parse `{"answer":"..."}` (or plain text fallback).
enum AskAnswerParser {
    /// Extract a sendable answer. Rejects empty, JSON-looking garbage, and full-source echoes.
    static func parse(_ raw: String, sourceText: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PolishingError.invalidAskAnswer }

        let unwrapped = unwrapCodeFence(trimmed)
        if let data = unwrapped.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard let answer = object["answer"] as? String else {
                throw PolishingError.invalidAskAnswer
            }
            let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw PolishingError.invalidAskAnswer }
            if isEcho(cleaned, of: sourceText) {
                throw PolishingError.invalidAskAnswer
            }
            return cleaned
        }

        let looksLikeJSON = unwrapped.hasPrefix("{") || unwrapped.hasPrefix("[")
        if looksLikeJSON {
            throw PolishingError.invalidAskAnswer
        }

        if isEcho(trimmed, of: sourceText) {
            throw PolishingError.invalidAskAnswer
        }
        return trimmed
    }

    /// Transient failures worth one automatic retry in ask mode.
    static func isRetryable(_ error: Error) -> Bool {
        if let polishingError = error as? PolishingError {
            switch polishingError {
            case .timeout, .noResponse, .invalidResponse, .invalidAskAnswer:
                return true
            case .httpError(let code, let body):
                if code == 429 || code >= 500 {
                    return true
                }
                let lower = body.lowercased()
                if lower.contains("unsupported model") {
                    return false
                }
                return false
            case .invalidURL, .missingAPIKey, .inputTooLong, .truncatedResponse, .contentChanged:
                return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost:
                return true
            default:
                return false
            }
        }
        return false
    }

    static func isEcho(_ answer: String, of source: String) -> Bool {
        let normalizedAnswer = normalizeForComparison(answer)
        let normalizedSource = normalizeForComparison(source)
        guard !normalizedAnswer.isEmpty, !normalizedSource.isEmpty else { return false }
        return normalizedAnswer == normalizedSource
    }

    private static func unwrapCodeFence(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("```") else { return value }
        if let firstNewline = value.firstIndex(of: "\n") {
            value = String(value[value.index(after: firstNewline)...])
        } else {
            value = String(value.dropFirst(3))
        }
        if value.hasSuffix("```") {
            value = String(value.dropLast(3))
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeForComparison(_ text: String) -> String {
        let lowered = text.lowercased()
        let filtered = lowered.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF)
        }
        return String(String.UnicodeScalarView(filtered))
    }
}
