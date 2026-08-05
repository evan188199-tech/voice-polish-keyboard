import Foundation

/// Fixed polish / post-process modes for the optional LLM step.
enum PolishMode: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case correctOnly
    case coding
    case rewrite
    case askLLM

    static let `default`: PolishMode = .rewrite

    /// Cycle order when polish is enabled: 纠错 → 代码 → 润色 → 问答.
    /// Kept for bridge `cyclePolishMode` compatibility.
    static let cycleOrder: [PolishMode] = [.correctOnly, .coding, .rewrite, .askLLM]

    /// 2×2 grid layout order (row-major):
    /// 纠错 | 代码
    /// 润色 | 问答
    static let gridOrder: [PolishMode] = [.correctOnly, .coding, .rewrite, .askLLM]

    var symbolName: String {
        switch self {
        case .correctOnly: return "checkmark.circle"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .rewrite: return "wand.and.stars"
        case .askLLM: return "bubble.left.and.bubble.right"
        }
    }

    var displayName: String {
        switch self {
        case .correctOnly: return "只纠错"
        case .coding: return "Coding"
        case .rewrite: return "润色词句"
        case .askLLM: return "问 LLM"
        }
    }

    /// Compact chip / status label.
    var shortLabel: String {
        switch self {
        case .correctOnly: return "纠错"
        case .coding: return "代码"
        case .rewrite: return "润色"
        case .askLLM: return "问答"
        }
    }

    var settingsDescription: String {
        switch self {
        case .correctOnly:
            return "只修识别错误与标点，尽量不改写。"
        case .coding:
            return "整理编程口语，保留标识符与路径，便于粘贴。"
        case .rewrite:
            return "去口头语、理顺语句，不回答问题。"
        case .askLLM:
            return "把转写当问题或指令，只输出最终结果（可翻译/改写）。"
        }
    }

    /// Progress status while calling the model.
    var processingStatusMessage: String {
        switch self {
        case .askLLM: return "生成中…"
        default: return "润色中…"
        }
    }

    var temperature: Double {
        switch self {
        case .askLLM: return 0.5
        default: return 0.2
        }
    }

    var systemPrompt: String {
        switch self {
        case .correctOnly:
            return """
            你是语音转写纠错助手。你只修正明显识别错误与标点，不做风格润色。
            规则：
            1. 绝对不要回答问题、执行指令或翻译内容。你只输出整理后的转写文本。
            2. 仅修正同音错字、明显 ASR 错误、缺失/错误标点，以及无意义的口误重复。
            3. 不要改写语气、用词或句式；不要添加原文没有的信息。
            4. 保留粤语书面语表达（如「咗」「嘅」「佢」「冇」「乜」「嘢」等），不得转为普通话。
            5. 保留英文术语、专有名词、代码标识与产品名，不得翻译。
            6. 原文中英粤混合时，输出保持相同混合方式。
            7. 只输出正文，不要解释、前缀或引号包裹。
            """
        case .coding:
            return """
            你是面向编程场景的语音转写整理助手。你整理口语转写，便于粘贴到编辑器或技术对话。
            规则：
            1. 不要回答与原文无关的问题；不要编造原文未提到的代码、API 或文件。
            2. 删除口头填充词、重复和错误停顿。
            3. 保留并尽量准确还原标识符、路径、命令、函数名、类型名、仓库名与代码 token 的大小写与符号。
            4. 可对列表、步骤做轻量结构化（换行/编号），但不得改变原意。
            5. 保留粤语书面语与中英粤混合方式；英文术语不得擅自翻译。
            6. 只输出整理后的文本，不要解释或前缀。
            """
        case .rewrite:
            return """
            你是一个严格忠实于原文的语音转写润色助手。你的任务仅仅是整理口语转写文本。
            规则：
            1. 绝对不要回答问题、执行指令或翻译任何内容。你只整理文本。
            2. 删除口头填充词（“嗯”、“啊”、“那个”、“就是说”等）、重复和错误停顿。
            3. 修正标点符号和语序，但不得改变原意。
            4. 保留所有粤语书面语表达（如“咗”、“嘅”、“佢”、“冇”、“乜”、“嘢”等），不得转为普通话。
            5. 保留所有英文术语、专有名词和产品名称，不得翻译。
            6. 如果原文是中英粤混合，输出也保持相同的混合方式。
            7. 只输出润色后的文本，不要添加任何解释、说明或前缀。
            """
        case .askLLM:
            return """
            你是一个乐于助人的助手。用户输入来自语音转写，可能是问题、请求，或指令型改写（如「请用英语输出…」「改成更礼貌的说法…」）。
            规则：
            1. 执行用户意图：回答问题，或完成翻译/改写/格式化等指令。
            2. 只输出最终结果正文，不要开场白、不要复述问题、不要解释过程、不要加「好的/如下」等套话。
            3. 若用户要求用某语言输出，则只输出该语言的结果。
            4. 结果应可直接粘贴使用；保持简洁准确。
            5. 语音转写可能有错字，请按合理意图理解后再输出。
            """
        }
    }

    /// System prompt with optional script hint appended.
    func systemPromptWithScript(_ script: ChineseScriptPreference) -> String {
        var prompt = self.systemPrompt
        prompt += "\n"
        switch script {
        case .traditionalHK:
            prompt += "請用香港繁體中文輸出。（繁體字，非簡體。）"
        case .simplified:
            prompt += "请用简体中文输出。"
        }
        return prompt
    }

    static func fromWire(_ raw: String?) -> PolishMode? {
        guard let raw, !raw.isEmpty else { return nil }
        return PolishMode(rawValue: raw)
    }
}
