import Foundation

enum BridgeCommand: String, Codable, Sendable {
    case ping
    case start
    case finish
    case cancel
    case status
    /// Toggle optional polish API on the companion/main app.
    case setPolishEnabled
    /// Set polish mode raw value (`correctOnly` / `coding` / `rewrite` / `askLLM`).
    case setPolishMode
    /// Cycle: off → 纠错 → 代码 → 润色 → 问答 → off.
    case cyclePolishMode
    /// Set Chinese script preference raw value (`simplified` / `traditionalHK`).
    case setChineseScript
    /// Arm the next ask-mode capture as a serial follow-up.
    case armAskFollowUp
    /// Clear ask-mode conversation history.
    case clearAskConversation
}

/// Machine-readable error codes shared by iOS keyboard and macOS input method.
enum BridgeErrorCode: String, Codable, Sendable, Equatable {
    case companionNotRunning
    case micDenied
    case modelNotReady
    case inputSessionInvalid
    case notRecording
    case unauthorized
    case busy
    /// A newer capture superseded this job; clients should stop polling silently.
    case discarded
    case unknown
}

struct BridgeStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case inactive
        case ready
        case recording
        case transcribing
        case polishing
        case error
    }

    let state: State
    let elapsedSeconds: TimeInterval?
    let message: String?
    /// Whether optional polish is currently enabled on the companion/main app.
    let polishEnabled: Bool?
    /// Active polish mode raw value when available.
    let polishMode: String?
    /// Optional job identity for async multi-segment pipelines.
    let jobID: UUID?
    /// Number of submitted jobs not yet consumed by a client.
    let pendingCount: Int?
    /// Active Chinese script preference raw value when available.
    let chineseScript: String?
    /// Whether a prior ask answer is available for follow-up.
    let askFollowUpAvailable: Bool?
    /// Whether the next ask capture will include conversation history.
    let askFollowUpArmed: Bool?

    init(
        state: State,
        elapsedSeconds: TimeInterval? = nil,
        message: String? = nil,
        polishEnabled: Bool? = nil,
        polishMode: String? = nil,
        jobID: UUID? = nil,
        pendingCount: Int? = nil,
        chineseScript: String? = nil,
        askFollowUpAvailable: Bool? = nil,
        askFollowUpArmed: Bool? = nil
    ) {
        self.state = state
        self.elapsedSeconds = elapsedSeconds
        self.message = message
        self.polishEnabled = polishEnabled
        self.polishMode = polishMode
        self.jobID = jobID
        self.pendingCount = pendingCount
        self.chineseScript = chineseScript
        self.askFollowUpAvailable = askFollowUpAvailable
        self.askFollowUpArmed = askFollowUpArmed
    }
}

struct BridgeResponse: Codable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case ok
        case text
        case error
        case unauthorized
    }

    let outcome: Outcome
    let text: String?
    let status: BridgeStatus?
    let message: String?
    /// Optional machine-readable error; UI still uses `message`.
    let errorCode: BridgeErrorCode?
    /// Optional async job identity.
    let jobID: UUID?

    static func ok(
        status: BridgeStatus? = nil,
        message: String? = nil,
        jobID: UUID? = nil
    ) -> BridgeResponse {
        BridgeResponse(
            outcome: .ok,
            text: nil,
            status: status,
            message: message,
            errorCode: nil,
            jobID: jobID
        )
    }

    static func text(
        _ value: String,
        status: BridgeStatus? = nil,
        jobID: UUID? = nil
    ) -> BridgeResponse {
        BridgeResponse(
            outcome: .text,
            text: value,
            status: status,
            message: nil,
            errorCode: nil,
            jobID: jobID
        )
    }

    static func error(
        _ msg: String,
        status: BridgeStatus? = nil,
        code: BridgeErrorCode = .unknown,
        jobID: UUID? = nil
    ) -> BridgeResponse {
        BridgeResponse(
            outcome: .error,
            text: nil,
            status: status,
            message: msg,
            errorCode: code,
            jobID: jobID
        )
    }

    static let unauthorized = BridgeResponse(
        outcome: .unauthorized,
        text: nil,
        status: nil,
        message: "Bad token",
        errorCode: .unauthorized,
        jobID: nil
    )
}

struct WireMessage: Codable, Sendable {
    let protocolVersion: UInt16
    let requestID: UUID
    let command: BridgeCommand
    let token: String
    /// Payload for `setPolishEnabled`.
    let polishEnabled: Bool?
    /// Payload for `setPolishMode` (raw value).
    let polishMode: String?
    /// Optional job identity for `status` polling (and echoed on finish).
    let jobID: UUID?
    /// Payload for `setChineseScript` (raw value).
    let chineseScript: String?

    init(
        command: BridgeCommand,
        token: String,
        requestID: UUID = UUID(),
        polishEnabled: Bool? = nil,
        polishMode: String? = nil,
        jobID: UUID? = nil,
        chineseScript: String? = nil
    ) {
        self.protocolVersion = AppConstants.protocolVersion
        self.requestID = requestID
        self.command = command
        self.token = token
        self.polishEnabled = polishEnabled
        self.polishMode = polishMode
        self.jobID = jobID
        self.chineseScript = chineseScript
    }
}

struct WireResponse: Codable, Sendable {
    let protocolVersion: UInt16
    let requestID: UUID
    let response: BridgeResponse

    init(requestID: UUID, response: BridgeResponse) {
        self.protocolVersion = AppConstants.protocolVersion
        self.requestID = requestID
        self.response = response
    }
}
