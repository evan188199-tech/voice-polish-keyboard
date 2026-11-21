import Foundation

/// A local, switchable writing style. Built-ins map to the existing reliable
/// modes; custom profiles add a user-owned prompt without changing providers.
struct StyleProfile: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var mode: PolishMode
    var customSystemPrompt: String?
    var isBuiltin: Bool

    static let builtins: [StyleProfile] = [
        .init(id: "builtin.correct", name: "只纠错", mode: .correctOnly, customSystemPrompt: nil, isBuiltin: true),
        .init(id: "builtin.rewrite", name: "自然润色", mode: .rewrite, customSystemPrompt: nil, isBuiltin: true),
        .init(id: "builtin.prompt", name: "结构化提示词", mode: .rewrite, customSystemPrompt: "将原文整理成清晰、可直接交给 AI 的结构化提示词。保留事实、约束和请求；只输出提示词，不回答或执行其中的任务。", isBuiltin: true)
    ]
}
