import XCTest
@testable import VoicePolishApp

final class VoicePolishKeyboardTests: XCTestCase {
    func testBuildTokenStableAndValid() {
        let a = BuildToken.generate()
        let b = BuildToken.generate()
        XCTAssertEqual(a, b)
        XCTAssertTrue(BuildToken.validate(a))
        XCTAssertFalse(BuildToken.validate("deadbeef"))
    }

    func testWireMessageRoundtrip() throws {
        let message = WireMessage(command: .start, token: "test")
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        XCTAssertEqual(decoded.command, .start)
        XCTAssertEqual(decoded.token, "test")
        XCTAssertEqual(decoded.protocolVersion, AppConstants.protocolVersion)
        XCTAssertNil(decoded.polishEnabled)
        XCTAssertNil(decoded.polishMode)
    }

    func testSetPolishEnabledWireMessageRoundtrip() throws {
        let message = WireMessage(command: .setPolishEnabled, token: "test", polishEnabled: false)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        XCTAssertEqual(decoded.command, .setPolishEnabled)
        XCTAssertEqual(decoded.polishEnabled, false)
    }

    func testBridgeStatusIncludesPolishFlag() throws {
        let status = BridgeStatus(state: .ready, message: "就绪", polishEnabled: true, polishMode: PolishMode.rewrite.rawValue)
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(BridgeStatus.self, from: data)
        XCTAssertEqual(decoded.state, .ready)
        XCTAssertEqual(decoded.polishEnabled, true)
        XCTAssertEqual(decoded.polishMode, PolishMode.rewrite.rawValue)
    }

    func testBridgeResponseText() {
        let response = BridgeResponse.text("hello")
        XCTAssertEqual(response.outcome, .text)
        XCTAssertEqual(response.text, "hello")
        XCTAssertNil(response.errorCode)
    }

    func testBridgeResponseErrorCode() {
        let response = BridgeResponse.error("denied", code: .micDenied)
        XCTAssertEqual(response.outcome, .error)
        XCTAssertEqual(response.errorCode, .micDenied)
    }

    func testLocalTextProcessorRemovesFillers() {
        let cleaned = LocalTextProcessor.process("嗯 今天 啊 去 codex", vocabulary: "")
        XCTAssertFalse(cleaned.contains("嗯"))
        XCTAssertTrue(cleaned.contains("今天"))
        XCTAssertTrue(cleaned.contains("codex"))
    }


    func testLocalTextProcessorNormalizesAllCapsEnglish() {
        let mixed = LocalTextProcessor.process(
            "我聽日要去 CHECK 個 SERVER，同埋 UPDATE 個 FIRMWARE。",
            vocabulary: ""
        )
        XCTAssertTrue(mixed.contains("check"))
        XCTAssertTrue(mixed.contains("server"))
        XCTAssertTrue(mixed.contains("update"))
        XCTAssertTrue(mixed.contains("firmware"))
        XCTAssertFalse(mixed.contains("CHECK"))
        XCTAssertFalse(mixed.contains("SERVER"))

        let english = LocalTextProcessor.process("HELLO WORLD. OPEN THE APP.", vocabulary: "")
        XCTAssertEqual(english, "Hello world. Open the app.")

        let acronyms = LocalTextProcessor.process("CHECK THE API AND VPN PLEASE", vocabulary: "")
        XCTAssertTrue(acronyms.contains("API"))
        XCTAssertTrue(acronyms.contains("VPN"))
        XCTAssertTrue(acronyms.contains("check") || acronyms.hasPrefix("Check"))
        XCTAssertFalse(acronyms.contains("CHECK"))
    }

    func testLocalTextProcessorUsesVocabularyCasing() {
        let out = LocalTextProcessor.process(
            "OPEN CHATWOOT INBOX THEN CHECK TAILSCALE",
            vocabulary: "Chatwoot\nTailscale"
        )
        XCTAssertTrue(out.contains("Chatwoot"))
        XCTAssertTrue(out.contains("Tailscale"))
        XCTAssertFalse(out.contains("CHATWOOT"))
        XCTAssertFalse(out.contains("TAILSCALE"))
    }


    func testLocalTextProcessorPreservesIPhoneCasing() {
        let allCaps = LocalTextProcessor.process("UPDATE APP TO IPHONE AND IPAD", vocabulary: "")
        XCTAssertTrue(allCaps.contains("iPhone"), allCaps)
        XCTAssertTrue(allCaps.contains("iPad"), allCaps)
        XCTAssertFalse(allCaps.contains("IPHONE"))
        XCTAssertFalse(allCaps.contains("Iphone"))

        let sentenceStart = LocalTextProcessor.process("iphone is ready. ios build passed on macos.", vocabulary: "")
        XCTAssertTrue(sentenceStart.hasPrefix("iPhone") || sentenceStart.contains("iPhone"), sentenceStart)
        XCTAssertTrue(sentenceStart.contains("iOS"), sentenceStart)
        XCTAssertTrue(sentenceStart.contains("macOS"), sentenceStart)
    }

    func testLocalTextProcessorRestoresPronounI() {
        let out = LocalTextProcessor.process("I THINK I NEED HELP", vocabulary: "")
        // All-caps "I" stays; other words lowercased + sentence capital.
        XCTAssertTrue(out.contains("I think I need help") || out == "I think I need help")
    }

    func testJoinTranscriptSegmentsChineseBareGetsPeriod() {
        let joined = LocalTextProcessor.joinTranscriptSegments([
            "今天天气很好",
            "明天去公司"
        ])
        XCTAssertEqual(joined, "今天天气很好。明天去公司")
    }

    func testJoinTranscriptSegmentsDoesNotDoublePunctuation() {
        XCTAssertEqual(
            LocalTextProcessor.joinTranscriptSegments(["今天天气很好。", "明天去公司"]),
            "今天天气很好。明天去公司"
        )
        XCTAssertEqual(
            LocalTextProcessor.joinTranscriptSegments(["先走吧！", "我随后到"]),
            "先走吧！我随后到"
        )
        XCTAssertEqual(
            LocalTextProcessor.joinTranscriptSegments(["你去吗？", "我再想想"]),
            "你去吗？我再想想"
        )
    }

    func testJoinTranscriptSegmentsEnglishUsesSpace() {
        XCTAssertEqual(
            LocalTextProcessor.joinTranscriptSegments(["hello world", "open the app"]),
            "hello world open the app"
        )
    }

    func testJoinTranscriptSegmentsMixedBoundaries() {
        // CJK then Latin -> space
        XCTAssertEqual(
            LocalTextProcessor.joinTranscriptSegments(["先改 API", "然后 deploy"]),
            "先改 API 然后 deploy"
        )
        // Latin then CJK -> space
        XCTAssertEqual(
            LocalTextProcessor.joinTranscriptSegments(["deploy done", "然后重启服务"]),
            "deploy done 然后重启服务"
        )
        // pure CJK multi-segment still gets periods
        XCTAssertEqual(
            LocalTextProcessor.joinTranscriptSegments(["第一段", "第二段", "第三段"]),
            "第一段。第二段。第三段"
        )
    }

    func testJoinTranscriptSegmentsSkipsEmptyAndSingle() {
        XCTAssertEqual(LocalTextProcessor.joinTranscriptSegments([]), "")
        XCTAssertEqual(LocalTextProcessor.joinTranscriptSegments(["  ", ""]), "")
        XCTAssertEqual(LocalTextProcessor.joinTranscriptSegments(["只有一段"]), "只有一段")
        XCTAssertEqual(
            LocalTextProcessor.joinTranscriptSegments(["  你好  ", "", "  世界  "]),
            "你好。世界"
        )
    }

    func testLocalTextProcessorCollapsesCJKInternalSpaces() {
        let out = LocalTextProcessor.process("今天 天气 很好", vocabulary: "")
        XCTAssertEqual(out, "今天天气很好")
        // Latin tokens keep their spaces
        let mixed = LocalTextProcessor.process("打开 API 然后 deploy", vocabulary: "")
        XCTAssertTrue(mixed.contains("API"))
        XCTAssertTrue(mixed.contains("deploy"))
        XCTAssertFalse(mixed.contains("API然后") || mixed.contains("APdeploy"))
    }

    func testConstants() {
        XCTAssertEqual(AppConstants.absoluteMaxRecordingDuration, 90)
        XCTAssertEqual(AppConstants.polishingTimeout, 8)
        XCTAssertEqual(AppConstants.bridgePorts.count, 3)
        XCTAssertEqual(AppConstants.polishingProbeTimeout, 5)
    }

    func testPolishSettingsNormalizeURL() {
        let settings = PolishingSettings(
            baseURL: " https://api.example.com/v1/ ",
            modelName: " gpt-test ",
            apiKey: " sk-test "
        )
        // Trailing slash + trailing /v1 stripped so we never double /v1.
        XCTAssertEqual(settings.baseURL, "https://api.example.com")
        XCTAssertEqual(settings.modelName, "gpt-test")
        XCTAssertEqual(settings.apiKey, "sk-test")
        XCTAssertEqual(
            settings.chatCompletionsURL?.absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
    }

    func testPolishSettingsAcceptsZenStyleBaseWithV1() {
        let settings = PolishingSettings(
            baseURL: "https://opencode.ai/zen/go/v1",
            modelName: "mimo-v2-omni",
            apiKey: "sk-test"
        )
        XCTAssertEqual(settings.baseURL, "https://opencode.ai/zen/go")
        XCTAssertEqual(
            settings.chatCompletionsURL?.absoluteString,
            "https://opencode.ai/zen/go/v1/chat/completions"
        )
    }

    func testPolishSettingsAcceptsFullChatCompletionsEndpoint() {
        let settings = PolishingSettings(
            baseURL: "https://proxy.example.com/openai/v1/chat/completions/",
            modelName: "m",
            apiKey: "k"
        )
        XCTAssertEqual(settings.baseURL, "https://proxy.example.com/openai")
        XCTAssertEqual(
            settings.chatCompletionsURL?.absoluteString,
            "https://proxy.example.com/openai/v1/chat/completions"
        )
    }

    func testPolishAvailabilityRejectsEmptyKey() async {
        let polisher = APITextPolisher()
        let settings = PolishingSettings(
            baseURL: "https://api.openai.com",
            modelName: "gpt-4o-mini",
            apiKey: "",
            timeout: 1
        )
        let result = await polisher.testAvailability(settings: settings)
        guard case .failure(let message) = result else {
            return XCTFail("expected failure for empty key")
        }
        XCTAssertTrue(message.contains("API Key") || message.contains("Key"))
    }

    func testPolishAvailabilityRejectsInvalidURL() async {
        let polisher = APITextPolisher()
        let settings = PolishingSettings(
            baseURL: "not a url",
            modelName: "gpt-4o-mini",
            apiKey: "sk-test",
            timeout: 1
        )
        let result = await polisher.testAvailability(settings: settings)
        guard case .failure(let message) = result else {
            return XCTFail("expected failure for invalid URL")
        }
        XCTAssertTrue(message.contains("地址") || message.contains("无效"))
    }

    func testPolishEnabledDefaultTrue() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "polish_enabled")
        defaults.removeObject(forKey: "polish_enabled")
        defer {
            if let previous {
                defaults.set(previous, forKey: "polish_enabled")
            } else {
                defaults.removeObject(forKey: "polish_enabled")
            }
        }
        let settings = AppSettings()
        XCTAssertTrue(settings.polishEnabled)
        settings.polishEnabled = false
        XCTAssertFalse(defaults.bool(forKey: "polish_enabled"))
        settings.polishEnabled = true
        XCTAssertTrue(defaults.bool(forKey: "polish_enabled"))
    }

    func testExtractAssistantTextFromStringContent() throws {
        let json = """
        {"choices":[{"message":{"role":"assistant","content":"  hello  "}}]}
        """
        let data = Data(json.utf8)
        XCTAssertEqual(APITextPolisher.extractAssistantText(from: data)?.trimmingCharacters(in: .whitespaces), "hello")
    }

    func testExtractAssistantTextFromMultipartContent() throws {
        let json = """
        {"choices":[{"message":{"content":[{"type":"text","text":"part1"},{"type":"text","text":"part2"}]}}]}
        """
        let data = Data(json.utf8)
        XCTAssertEqual(APITextPolisher.extractAssistantText(from: data), "part1part2")
    }

    func testExtractAssistantTextIgnoresEmptyOrNullContent() throws {
        let empty = Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8)
        let nullish = Data(#"{"choices":[{"message":{"content":null,"reasoning_content":"thinking"}}]}"#.utf8)
        XCTAssertNil(APITextPolisher.extractAssistantText(from: empty))
        XCTAssertNil(APITextPolisher.extractAssistantText(from: nullish))
        XCTAssertTrue(APITextPolisher.hasChatChoices(in: nullish))
    }

    func testUnsupportedModelErrorMessage() {
        let error = PolishingError.httpError(
            400,
            #"{"error":{"type":"server_error","message":"Error from provider (Console Go): Upstream request failed: [400] Unsupported model mimo-v2-omni"}}"#
        )
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("不被此接口支持") || message.contains("Unsupported model"))
        XCTAssertTrue(message.contains("mimo-v2-omni") || message.contains("mimo-v2.5"))
    }

    func testPolishProfilesSaveAndSwitch() {
        let defaults = UserDefaults.standard
        let keys = [
            "polish_api_profiles",
            "active_polish_profile_id",
            "api_base_url",
            "api_model_name",
            "polish_enabled"
        ]
        let backup = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in backup {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }

        let settings = AppSettings()
        XCTAssertFalse(settings.polishProfiles.isEmpty)

        settings.saveActivePolishProfile(
            name: "OpenAI",
            baseURL: "https://api.openai.com",
            modelName: "gpt-4o-mini",
            apiKey: "sk-a"
        )
        let firstID = settings.activePolishProfileID
        XCTAssertEqual(settings.baseURL, "https://api.openai.com")
        XCTAssertEqual(settings.modelName, "gpt-4o-mini")

        settings.saveAsNewPolishProfile(
            name: "Zen",
            baseURL: "https://opencode.ai/zen/go/v1",
            modelName: "mimo-v2.5",
            apiKey: "sk-b"
        )
        XCTAssertEqual(settings.polishProfiles.count, 2)
        XCTAssertEqual(settings.baseURL, "https://opencode.ai/zen/go")
        XCTAssertEqual(settings.modelName, "mimo-v2.5")
        XCTAssertEqual(settings.apiKey, "sk-b")

        settings.selectPolishProfile(id: firstID)
        XCTAssertEqual(settings.activePolishProfileID, firstID)
        XCTAssertEqual(settings.baseURL, "https://api.openai.com")
        XCTAssertEqual(settings.modelName, "gpt-4o-mini")
        XCTAssertEqual(settings.apiKey, "sk-a")
    }

    func testSetPolishModeWireMessageRoundtrip() throws {
        let message = WireMessage(
            command: .setPolishMode,
            token: "test",
            polishMode: PolishMode.coding.rawValue
        )
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        XCTAssertEqual(decoded.command, .setPolishMode)
        XCTAssertEqual(decoded.polishMode, PolishMode.coding.rawValue)
        XCTAssertNil(decoded.polishEnabled)
    }

    func testCyclePolishModeWireCommandExists() throws {
        let message = WireMessage(command: .cyclePolishMode, token: "test")
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        XCTAssertEqual(decoded.command, .cyclePolishMode)
    }

    func testPolishModeDefaultAndLabels() {
        XCTAssertEqual(PolishMode.default, .rewrite)
        XCTAssertEqual(PolishMode.correctOnly.shortLabel, "纠错")
        XCTAssertEqual(PolishMode.coding.shortLabel, "代码")
        XCTAssertEqual(PolishMode.rewrite.shortLabel, "润色")
        XCTAssertEqual(PolishMode.askLLM.shortLabel, "问答")
        XCTAssertEqual(PolishMode.cycleOrder.count, 4)
        XCTAssertEqual(PolishMode.fromWire("askLLM"), .askLLM)
        XCTAssertNil(PolishMode.fromWire("nope"))
    }

    func testPolishModeSystemPromptsDiffer() {
        let correct = APITextPolisher.systemPrompt(for: .correctOnly)
        let coding = APITextPolisher.systemPrompt(for: .coding)
        let rewrite = APITextPolisher.systemPrompt(for: .rewrite)
        let ask = APITextPolisher.systemPrompt(for: .askLLM)
        XCTAssertTrue(correct.contains("纠错") || correct.contains("识别错误"))
        XCTAssertTrue(coding.contains("编程") || coding.contains("标识符"))
        XCTAssertTrue(rewrite.contains("不要回答问题"))
        XCTAssertTrue(ask.contains("最终结果") || ask.contains("指令"))
        XCTAssertNotEqual(correct, ask)
        XCTAssertEqual(PolishMode.correctOnly.temperature, 0.2, accuracy: 0.0001)
        XCTAssertEqual(PolishMode.askLLM.temperature, 0.5, accuracy: 0.0001)
    }

    func testPolishModePersistsInSettings() {
        let defaults = UserDefaults.standard
        let keys = ["polish_mode", "polish_enabled"]
        let backup = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in backup {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }

        let settings = AppSettings()
        XCTAssertEqual(settings.polishMode, .rewrite)
        settings.polishMode = .askLLM
        XCTAssertEqual(defaults.string(forKey: "polish_mode"), PolishMode.askLLM.rawValue)

        let reloaded = AppSettings()
        XCTAssertEqual(reloaded.polishMode, .askLLM)
    }

    func testPolishSettingsCarriesMode() {
        let settings = PolishingSettings(
            baseURL: "https://api.openai.com",
            modelName: "gpt-4o-mini",
            apiKey: "sk-test",
            mode: .coding
        )
        XCTAssertEqual(settings.mode, .coding)
        XCTAssertEqual(settings.mode.temperature, 0.2, accuracy: 0.0001)
    }

    func testCyclePolishModeOrderIncludesOff() {
        let defaults = UserDefaults.standard
        let keys = ["polish_mode", "polish_enabled"]
        let backup = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in backup {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }

        let settings = AppSettings()
        settings.polishEnabled = false
        settings.polishMode = .rewrite

        let coordinator = VoiceSessionCoordinator()
        coordinator.setup(settings: settings)

        // off → correctOnly
        XCTAssertTrue(coordinator.cyclePolishMode())
        XCTAssertTrue(settings.polishEnabled)
        XCTAssertEqual(settings.polishMode, .correctOnly)
        XCTAssertEqual(coordinator.polishStateSummary, "纠错")

        // correctOnly → coding → rewrite → askLLM
        XCTAssertTrue(coordinator.cyclePolishMode())
        XCTAssertEqual(settings.polishMode, .coding)
        XCTAssertTrue(coordinator.cyclePolishMode())
        XCTAssertEqual(settings.polishMode, .rewrite)
        XCTAssertTrue(coordinator.cyclePolishMode())
        XCTAssertEqual(settings.polishMode, .askLLM)
        XCTAssertEqual(coordinator.polishStateSummary, "问答")

        // askLLM → off (mode retained)
        XCTAssertTrue(coordinator.cyclePolishMode())
        XCTAssertFalse(settings.polishEnabled)
        XCTAssertEqual(settings.polishMode, .askLLM)
        XCTAssertEqual(coordinator.polishStateSummary, "润色关")

        // off again → correctOnly
        XCTAssertTrue(coordinator.cyclePolishMode())
        XCTAssertTrue(settings.polishEnabled)
        XCTAssertEqual(settings.polishMode, .correctOnly)
    }

    // MARK: - ASR A/B compare helpers

    func testASRCompareSnapshotHoldsParallelFields() {
        var snap = ASRCompareSnapshot.empty
        snap.primaryText = "我聽日要去 check 個 server"
        snap.compareText = "我听日要去 check 个 server"
        snap.primaryLatencyMs = 420
        snap.compareLatencyMs = 380
        snap.compareError = "系统语音识别权限被拒绝"
        snap.compareLocaleIdentifier = "zh-HK"
        snap.compareEngineDisplayName = AppleSpeechLocaleSelector.displayName(for: "zh-HK")

        XCTAssertEqual(snap.primaryText, "我聽日要去 check 個 server")
        XCTAssertEqual(snap.compareText, "我听日要去 check 个 server")
        XCTAssertEqual(snap.primaryLatencyMs, 420)
        XCTAssertEqual(snap.compareLatencyMs, 380)
        XCTAssertEqual(snap.compareError, "系统语音识别权限被拒绝")
        XCTAssertEqual(snap.compareLocaleIdentifier, "zh-HK")
        XCTAssertTrue(snap.compareEngineDisplayName.contains("zh-HK"))
    }

    func testAppleSpeechLocalePrefersZhHKWhenAvailable() {
        let available = ["en-US", "zh-CN", "zh-HK", "ja-JP"]
        XCTAssertEqual(
            AppleSpeechLocaleSelector.preferredLocaleIdentifier(from: available),
            "zh-HK"
        )
    }

    func testAppleSpeechLocaleFallsBackWithoutZhHK() {
        let available = ["en-US", "zh-CN", "ja-JP"]
        XCTAssertEqual(
            AppleSpeechLocaleSelector.preferredLocaleIdentifier(from: available),
            "zh-CN"
        )

        let englishOnly = ["en-GB", "en-US"]
        XCTAssertEqual(
            AppleSpeechLocaleSelector.preferredLocaleIdentifier(from: englishOnly),
            "en-GB"
        )

        XCTAssertNil(AppleSpeechLocaleSelector.preferredLocaleIdentifier(from: []))
    }

    func testCompareWithSystemDictationDefaultOff() {
        let defaults = UserDefaults.standard
        let key = "compare_with_system_dictation"
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let settings = AppSettings()
        XCTAssertFalse(settings.compareWithSystemDictation)
        settings.compareWithSystemDictation = true
        XCTAssertTrue(defaults.bool(forKey: key))
        settings.compareWithSystemDictation = false
        XCTAssertFalse(defaults.bool(forKey: key))
    }



    func testJobIDWireRoundtrip() throws {
        let jobID = UUID()
        let message = WireMessage(command: .status, token: "test", jobID: jobID)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        XCTAssertEqual(decoded.command, .status)
        XCTAssertEqual(decoded.jobID, jobID)
        XCTAssertNil(decoded.polishEnabled)
    }

    func testBridgeStatusPendingCountAndJobID() throws {
        let jobID = UUID()
        let status = BridgeStatus(
            state: .transcribing,
            message: "识别中… · 待处理 2 段",
            polishEnabled: true,
            polishMode: PolishMode.rewrite.rawValue,
            jobID: jobID,
            pendingCount: 2,
            chineseScript: ChineseScriptPreference.simplified.rawValue
        )
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(BridgeStatus.self, from: data)
        XCTAssertEqual(decoded.jobID, jobID)
        XCTAssertEqual(decoded.pendingCount, 2)
        XCTAssertEqual(decoded.chineseScript, ChineseScriptPreference.simplified.rawValue)
    }

    func testBridgeResponseJobIDRoundtrip() throws {
        let jobID = UUID()
        let response = BridgeResponse.ok(message: "已提交", jobID: jobID)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(BridgeResponse.self, from: data)
        XCTAssertEqual(decoded.outcome, .ok)
        XCTAssertEqual(decoded.jobID, jobID)
    }

    func testOrderedDeliveryCursorSequential() {
        var cursor = OrderedDeliveryCursor()
        XCTAssertTrue(cursor.canDeliver(sequence: 1))
        XCTAssertFalse(cursor.canDeliver(sequence: 2))
        cursor.advance()
        XCTAssertTrue(cursor.canDeliver(sequence: 2))
        cursor.advance()
        XCTAssertTrue(cursor.canDeliver(sequence: 3))
        cursor.reset()
        XCTAssertTrue(cursor.canDeliver(sequence: 1))
    }

    func testVoiceJobStatusTextIncludesPendingCount() {
        let one = VoiceJobStatusText.processingMessage(
            phase: .transcribing,
            polishMode: .rewrite,
            pendingCount: 1
        )
        XCTAssertEqual(one, "识别中…")
        let many = VoiceJobStatusText.processingMessage(
            phase: .polishing,
            polishMode: .askLLM,
            pendingCount: 3
        )
        XCTAssertTrue(many.contains("生成中"))
        XCTAssertTrue(many.contains("3"))
        let polish = VoiceJobStatusText.processingMessage(
            phase: .polishing,
            polishMode: .rewrite,
            pendingCount: 2
        )
        XCTAssertTrue(polish.contains("润色中"))
    }

    func testCloudPolishConcurrencyConstant() {
        XCTAssertEqual(AppConstants.localASRConcurrency, 1)
        XCTAssertEqual(AppConstants.cloudPolishConcurrency, 2)
    }

    func testFailedPhaseStatusText() {
        let msg = VoiceJobStatusText.processingMessage(
            phase: .failed,
            polishMode: .rewrite,
            pendingCount: 2
        )
        XCTAssertTrue(msg.contains("处理失败"))
        XCTAssertTrue(msg.contains("2"))
    }

    func testReadyPhaseStatusTextPendingInsert() {
        let msg = VoiceJobStatusText.processingMessage(
            phase: .ready,
            polishMode: .coding,
            pendingCount: 1
        )
        XCTAssertEqual(msg, "待插入…")
    }

}
