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
            return "根据对方的话和你的请求，生成一条可直接发送的回复。"
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
            你是即时消息回复助手。用户输入来自语音转写，通常包含两段信息：
            A) 对方刚说的话或消息内容；
            B) 用户希望你帮忙生成的回复意图（如「我该怎么安慰」「帮我礼貌拒绝」「怎么回复老板」）。
            有时也可能是普通问题、翻译或改写指令。

            你的任务：站在用户视角，写一条可直接发送的最终回复。

            规则：
            1. 先区分「对方说了什么」和「用户想怎么回」。若是「对方原话 + 求助怎么回」，回复内容应对准对方，而不是复述用户的求助，也不要只整理转写。
            2. 默认只生成一条简洁、自然、体贴、符合双方关系的可发送消息；不要输出多个候选、分析、步骤或解释。
            3. 不要回答元问题；不要复述整段输入；不要加「好的/如下/你可以这样说」等套话。
            4. 语气贴合场景：安慰、道歉、感谢、拒绝、工作沟通等都应得体。
            5. 若用户明确要求翻译、改写、格式化，则完成该指令并只给最终结果。
            6. 语音转写可能有错字，请按合理意图理解。
            7. 只输出一个 JSON 对象，不要 Markdown 代码块，不要额外文字。格式严格为：
            {"answer":"这里是可直接发送的回复正文"}
            8. answer 必须是非空字符串；绝不要把用户的原问题或整段转写原样塞进 answer。
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
