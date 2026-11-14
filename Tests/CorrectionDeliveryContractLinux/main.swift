import Foundation

// Compile the real wire response with minimal DTO stand-ins. The real protocol
// definition is unchanged; these are not a proposed or implemented wire schema.
struct ClipboardEntry: Codable, Sendable {}
struct PlaceNameSuggestion: Codable, Sendable {}
struct TranslationBridgePayload: Codable, Sendable {}
enum AppConstants { static let protocolVersion: UInt16 = 1 }

/// Executable specification only. This is deliberately not the shipping keyboard.
struct ContractHarness {
    struct Result { let id: UUID; let text: String; let needsReview: Bool; let targetVerified: Bool }
    private(set) var queue: [Result] = []
    private(set) var pending: Result?
    private(set) var held: String?
    private(set) var inserted: [String] = []
    mutating func enqueue(_ item: Result) { queue.append(item); pump() }
    mutating func pump() {
        guard pending == nil, held == nil, !queue.isEmpty else { return }
        let head = queue.removeFirst()
        if head.needsReview { pending = head }
        else if head.targetVerified { inserted.append(head.text); pump() }
        else { held = head.text }
    }
    mutating func confirm(id: UUID, text: String) {
        guard let item = pending, item.id == id else { return }
        pending = nil
        if item.targetVerified { inserted.append(text); pump() } else { held = text }
    }
    mutating func cancel(id: UUID) {
        guard pending?.id == id else { return }
        pending = nil; pump()
    }
}

@main enum CorrectionDeliveryContractChecks {
    static func main() throws {
        var failures = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            if value() { print("PASS: \(label)") } else { failures += 1; print("FAIL: \(label)") }
        }
        let first = UUID(), later = UUID()
        var h = ContractHarness()
        h.enqueue(.init(id: first, text: "虚构原文", needsReview: true, targetVerified: true))
        h.enqueue(.init(id: later, text: "后续一段", needsReview: false, targetVerified: true))
        check(h.pending?.id == first && h.inserted.isEmpty && h.queue.count == 1, "specified review blocks later result")
        h.confirm(id: first, text: "确定结果")
        h.confirm(id: first, text: "重复结果")
        check(h.inserted == ["确定结果", "后续一段"], "specified confirmation delivers once before later text")
        var c = ContractHarness()
        c.enqueue(.init(id: first, text: "原文", needsReview: true, targetVerified: true))
        c.enqueue(.init(id: later, text: "后续", needsReview: false, targetVerified: true))
        c.cancel(id: later)
        check(c.inserted.isEmpty && c.pending?.id == first, "unrelated cancel cannot skip review")
        c.cancel(id: first)
        check(c.inserted == ["后续"], "explicit cancellation releases next item")
        var uncertain = ContractHarness()
        uncertain.enqueue(.init(id: first, text: "原文", needsReview: true, targetVerified: false))
        uncertain.confirm(id: first, text: "确定结果")
        check(uncertain.inserted.isEmpty && uncertain.held == "确定结果", "unknown destination keeps confirmed text")
        var normal = ContractHarness()
        normal.enqueue(.init(id: first, text: "正常听写", needsReview: false, targetVerified: true))
        check(normal.inserted == ["正常听写"] && normal.pending == nil, "ordinary dictation bypasses review")
        // A notice attached to current host status is not bound to the result job.
        // The shipping DTO has no per-result correction metadata. This assertion
        // intentionally fails until the bridge owner supplies a real contract.
        let response = BridgeResponse.text("虚构原文", status: BridgeStatus(state: .ready, resultNotice: "纠字目标不明确"), jobID: first)
        let encoded = try JSONEncoder().encode(response)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        check(object["correctionReviewRequired"] != nil, "RED: actual BridgeResponse carries per-result correctionReviewRequired metadata")
        if failures > 0 { print("FAILED: \(failures) (shipping bridge integration is not implemented)"); exit(1) }
        print("Correction delivery contract passed")
    }
}
