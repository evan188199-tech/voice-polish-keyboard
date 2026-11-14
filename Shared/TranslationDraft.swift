import Foundation

protocol TextTranslating: Sendable {
    var capability: TranslationCapability { get async }
    func translate(_ request: TranslationRequest) async throws -> TranslationEvent
    func cancel(_ requestID: UUID) async
}
extension TextTranslating { func cancel(_ requestID: UUID) async {} }
struct DisabledTranslationService: TextTranslating {
    var capability: TranslationCapability { get async { .unavailable } }
    func translate(_ request: TranslationRequest) async throws -> TranslationEvent { throw TranslationFailure.unavailable }
}

enum TranslationLanguage: String, Codable, CaseIterable, Sendable { case english, chinese }
struct TranslationTarget: Codable, Hashable, Sendable, Identifiable {
    let language: TranslationLanguage
    let script: ChineseScriptPreference?
    var id: String { code }
    static let english = TranslationTarget(language: .english, script: nil)
    static let simplified = TranslationTarget(language: .chinese, script: .simplified)
    static let traditionalHK = TranslationTarget(language: .chinese, script: .traditionalHK)
    static let choices = [english, simplified, traditionalHK]
    var isValid: Bool { language == .english ? script == nil : script != nil }
    var code: String {
        language == .english ? "en" : (script == .traditionalHK ? "zh-Hant-HK" : "zh-Hans")
    }
    var displayName: String {
        language == .english ? "English" : (script == .traditionalHK ? "香港繁體中文" : "简体中文")
    }
    var instruction: String {
        language == .english ? "Translate into English. Output English; do not apply a Chinese output-script preference."
            : (script == .traditionalHK ? "翻譯成香港繁體中文，保留原有語氣。" : "翻译成简体中文，保留原有语气。")
    }
}
enum TranslationSourceKind: String, Codable, Sendable { case voice, typed }
enum TranslationDeliveryMode: String, Codable, Sendable { case automatic, preview }
struct TranslationContext: Codable, Equatable, Sendable {
    let id: UUID
    let target: TranslationTarget
    let sourceKind: TranslationSourceKind
    let deliveryMode: TranslationDeliveryMode
    let consentServiceID: String
    init(id: UUID = UUID(), target: TranslationTarget, sourceKind: TranslationSourceKind,
         deliveryMode: TranslationDeliveryMode = .automatic, consentServiceID: String) {
        self.id = id; self.target = target; self.sourceKind = sourceKind
        self.deliveryMode = deliveryMode; self.consentServiceID = consentServiceID
    }
}
struct TranslationRequest: Codable, Equatable, Sendable {
    static let maxSourceUTF8Bytes = 10_000
    let context: TranslationContext
    let source: String
}
enum TranslationFailure: String, Codable, Error, Sendable {
    case unavailable, notEnabled, missingConfiguration, noFullAccess, unsupportedTarget
    case emptySource, inputTooLong, offline, timeout, rejected, rateLimited
    case emptyResult, truncated, invalidResult, unsafeResult, cancelled, serviceChanged
    var message: String {
        switch self {
        case .unavailable: "翻译不可用：真实服务尚未接入，本轮仅验证 mock。"
        case .notEnabled: "翻译未启用，请在主应用确认服务与数据去向。"
        case .missingConfiguration: "翻译不可用：缺少已选择的服务、模型或密钥。"
        case .noFullAccess: "翻译不可用：键盘需要完全访问才能连接主应用。"
        case .unsupportedTarget: "当前服务尚未验证支持该目标语言。"
        case .emptySource: "请先输入或录入待译原文。"
        case .inputTooLong: "原文过长，已完整保留，未截断或发起请求。"
        case .offline: "网络不可用，原文已保留。"
        case .timeout: "翻译超时，原文已保留。"
        case .rejected: "服务拒绝请求，原文已保留。"
        case .rateLimited: "服务限流或额度不足，原文已保留。"
        case .emptyResult: "服务未返回译文，原文已保留。"
        case .truncated: "服务结果不完整，未插入，原文已保留。"
        case .invalidResult: "服务结果格式或目标语言不匹配，未插入。"
        case .unsafeResult: "译文未通过数字或受保护内容检查，未插入。"
        case .cancelled: "本次翻译已取消，原文已保留。"
        case .serviceChanged: "服务配置或授权已变化，请重新确认。"
        }
    }
}
struct TranslationCapability: Codable, Equatable, Sendable {
    let serviceID: String
    let serviceLabel: String
    let isAvailable: Bool
    let supportedTargets: [TranslationTarget]
    let orderedTargets: [TranslationTarget]
    let failure: TranslationFailure?
    static let unavailable = TranslationCapability(serviceID: "", serviceLabel: "未连接翻译服务", isAvailable: false,
        supportedTargets: [], orderedTargets: TranslationTarget.choices, failure: .unavailable)
}
struct TranslationEvent: Codable, Equatable, Sendable {
    let context: TranslationContext
    let source: String
    let translation: String?
    let failure: TranslationFailure?
    var isSuccess: Bool { failure == nil && translation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
}
struct TranslationBridgePayload: Codable, Sendable {
    enum Operation: String, Codable, Sendable { case capabilities, translateText, cancel }
    let operation: Operation
    let request: TranslationRequest?
    let requestID: UUID?
    init(operation: Operation, request: TranslationRequest? = nil, requestID: UUID? = nil) {
        self.operation = operation; self.request = request; self.requestID = requestID
    }
}

struct TranslationBridgeReply: Codable, Sendable {
    let capability: TranslationCapability?
    let event: TranslationEvent?
    let failure: TranslationFailure?
}

/// A single editable text request. Voice jobs have independent immutable contexts and
/// retain their global job order; changing a later target never rewrites an earlier job.
struct TranslationDraft: Codable, Equatable, Sendable {
    private(set) var source = ""
    private(set) var target = TranslationTarget.english
    private(set) var translation: String?
    private(set) var requestID: UUID?
    private(set) var failure: TranslationFailure?
    private(set) var isBusy = false
    private(set) var previewCanInsert = false
    private(set) var savedSource = ""
    mutating func editSource(_ text: String) { invalidate(); source = text }
    mutating func changeTarget(_ target: TranslationTarget) { invalidate(); self.target = target }
    mutating func begin(_ context: TranslationContext) -> TranslationRequest? {
        guard !isBusy, translation == nil, context.target == target else { return nil }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { failure = .emptySource; return nil }
        guard source.utf8.count <= TranslationRequest.maxSourceUTF8Bytes else { failure = .inputTooLong; return nil }
        requestID = context.id; isBusy = true; failure = nil; translation = nil; previewCanInsert = false
        savedSource = source
        return TranslationRequest(context: context, source: source)
    }
    @discardableResult mutating func receive(_ event: TranslationEvent) -> Bool {
        guard requestID == event.context.id, source == event.source, target == event.context.target else { return false }
        isBusy = false; failure = event.failure
        translation = event.isSuccess ? event.translation : nil
        previewCanInsert = event.isSuccess && event.context.deliveryMode == .preview
        return true
    }
    mutating func fail(_ reason: TranslationFailure, id: UUID?) {
        guard id == requestID else { return }
        isBusy = false; failure = reason; translation = nil; previewCanInsert = false
    }
    mutating func cancel() { invalidate(); failure = .cancelled }
    mutating func restoreSource() { let original = savedSource; invalidate(); source = original }
    mutating func consumePreview() -> String? {
        guard previewCanInsert, let translation else { return nil }
        previewCanInsert = false
        return translation
    }
    private mutating func invalidate() {
        requestID = nil; isBusy = false; translation = nil; failure = nil; previewCanInsert = false
    }
}

/// Shared policy for touch tests. Thresholds are project defaults, not measurements
/// of the reference product; a cancelled/sideways/short hold has no recording effect.
struct TranslationSpeakGesture: Equatable {
    enum Action: Equatable { case none, dictate, translate(Int) }
    static let holdDuration: TimeInterval = 0.35
    static let upwardDistance: Double = 45
    static func selection(elapsed: TimeInterval, horizontal: Double, vertical: Double,
                          width: Double, targetCount: Int) -> Int? {
        guard elapsed >= holdDuration, vertical <= -upwardDistance, width > 0, targetCount > 0,
              abs(horizontal) <= width / 2 else { return nil }
        return min(targetCount - 1, max(0, Int((horizontal + width / 2) / (width / Double(targetCount)))))
    }
    static func ended(elapsed: TimeInterval, horizontal: Double, vertical: Double,
                      width: Double, targetCount: Int, canTranslate: Bool) -> Action {
        if elapsed < holdDuration, abs(horizontal) < 18, abs(vertical) < 18 { return .dictate }
        if canTranslate, let index = selection(elapsed: elapsed, horizontal: horizontal, vertical: vertical, width: width, targetCount: targetCount) {
            return .translate(index)
        }
        return .none
    }
}
