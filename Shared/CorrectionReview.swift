import Foundation

/// A proposal is only a decomposition of the ASR text, never evidence that a
/// character is acoustically correct. It is not a delivery authorization.
struct CorrectionReviewProposal: Equatable, Sendable {
    let original: String
    let draft: String?
    let target: String?
    let candidates: [String]
    let hint: String

    static func make(original: String) -> CorrectionReviewProposal {
        let fallback = CorrectionReviewProposal(original: original, draft: nil, target: nil, candidates: [],
                                                hint: "无法确定纠错目标；可手动编辑、保留原文或取消。")
        guard !FaithfulTextFormatter.isProtected(original),
              !["解释", "解釋", "引用", "逐字", "原话", "原話", "他说", "他說", "佢話", "不要改", "唔好改"].contains(where: original.contains) else { return fallback }
        let direct = try! NSRegularExpression(pattern: #"(?:^|[，,。；;]\s*)(?:把|将|將)([\p{Han}A-Za-z]{1,8})(?:改成|改为|改為|改做)([\p{Han}A-Za-z]{1,8})[。.!！]?\s*$"#)
        let spelling = try! NSRegularExpression(pattern: #"(?:^|[，,。；;]\s*)([\p{Han}A-Za-z]{1,8})(?:是|係|系)([\p{Han}A-Za-z]{2,16})(?:的|嘅)([\p{Han}A-Za-z]{1,8})[。.!！]?\s*$"#)
        let searchRange = NSRange(original.startIndex..., in: original)
        let match: NSTextCheckingResult
        let replacementGroup: Int
        if let found = direct.firstMatch(in: original, range: searchRange) {
            match = found; replacementGroup = 2
        } else if let found = spelling.firstMatch(in: original, range: searchRange),
                  let reference = Range(found.range(at: 2), in: original),
                  let replacement = Range(found.range(at: 3), in: original),
                  String(original[reference]).contains(String(original[replacement])) {
            match = found; replacementGroup = 3
        } else { return fallback }
        guard let a = Range(match.range(at: 1), in: original), let b = Range(match.range(at: replacementGroup), in: original),
              let clause = Range(match.range, in: original) else { return fallback }
        let target = String(original[a]); let alternative = String(original[b])
        var draft = String(original[..<clause.lowerBound])
        guard !draft.isEmpty,
              draft.range(of: #"(?:把|将|將)[\p{Han}A-Za-z]{1,8}(?:改成|改为|改為|改做)"#, options: .regularExpression) == nil,
              let first = draft.range(of: target),
              draft.range(of: target, range: draft.index(after: first.lowerBound)..<draft.endIndex) == nil else { return fallback }
        if original.hasSuffix("。") { draft += "。" }
        else if original.hasSuffix("！") { draft += "！" }
        else if original.hasSuffix("!") { draft += "!" }
        else if original.hasSuffix(".") { draft += "." }
        return CorrectionReviewProposal(original: original, draft: draft, target: target,
                                        candidates: target == alternative ? [target] : [target, alternative],
                                        hint: "候选取自转写，不代表识别正确；请确认字形。")
    }
}

/// No host or queue access. The caller must explicitly deliver a confirmed result.
struct CorrectionReviewState: Sendable {
    enum Phase: Equatable, Sendable { case empty, loading, reviewing, confirmed, delivered, cancelled }
    private(set) var phase: Phase = .empty
    private(set) var original = ""
    private(set) var proposal: CorrectionReviewProposal?
    private(set) var finalText: String?
    private var generation = UUID()

    mutating func begin(original: String) -> UUID {
        generation = UUID(); self.original = original; proposal = nil; finalText = nil; phase = .loading
        return generation
    }
    mutating func acceptProposal(_ value: CorrectionReviewProposal, token: UUID) -> Bool {
        guard token == generation, phase == .loading, value.original == original,
              value == CorrectionReviewProposal.make(original: original) else { return false }
        proposal = value; phase = .reviewing; return true
    }
    mutating func confirm(candidate: String) -> Bool {
        guard phase == .reviewing, let proposal, let draft = proposal.draft, let target = proposal.target,
              proposal.candidates.contains(candidate), let range = draft.range(of: target),
              draft.range(of: target, range: draft.index(after: range.lowerBound)..<draft.endIndex) == nil else { return false }
        var text = draft; text.replaceSubrange(range, with: candidate)
        finalText = text; phase = .confirmed; generation = UUID(); return true
    }
    /// The text comes from an explicit full-text user edit, not an inferred candidate.
    mutating func confirmManual(_ text: String) -> Bool {
        guard phase == .reviewing, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        finalText = text; phase = .confirmed; generation = UUID(); return true
    }
    mutating func keepOriginal() -> Bool {
        guard phase == .reviewing, !original.isEmpty else { return false }
        finalText = original; phase = .confirmed; generation = UUID(); return true
    }
    mutating func cancel() { generation = UUID(); proposal = nil; finalText = nil; phase = .cancelled }
    /// Undo is local to this state, not a reversal of text already delivered elsewhere.
    mutating func undo() -> Bool {
        guard phase == .confirmed, proposal != nil else { return false }
        finalText = nil; phase = .reviewing; generation = UUID(); return true
    }
    mutating func consumeConfirmed() -> String? {
        guard phase == .confirmed, let text = finalText else { return nil }
        phase = .delivered; return text
    }
    func restoreOriginal() -> String { original }
}
