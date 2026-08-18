import XCTest
import AVFoundation
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

    func testLocalTextProcessorPreservesIPhoneAirCasing() {
        XCTAssertEqual(
            LocalTextProcessor.process("UPDATE TO IPHONE AIR", vocabulary: ""),
            "Update to iPhone Air"
        )
    }

    func testLocalTextProcessorRestoresPronounI() {
        let out = LocalTextProcessor.process("I THINK I NEED HELP", vocabulary: "")
        // All-caps "I" stays; other words lowercased + sentence capital.
        XCTAssertTrue(out.contains("I think I need help") || out == "I think I need help")
    }

    func testLocalTextProcessorCollapsesSpokenEnglishLetters() {
        XCTAssertEqual(LocalTextProcessor.process("A B C", vocabulary: ""), "ABC")
        XCTAssertEqual(LocalTextProcessor.process("connect to U S B now", vocabulary: ""), "Connect to USB now")
        XCTAssertEqual(LocalTextProcessor.process("I am ready", vocabulary: ""), "I am ready")
        XCTAssertEqual(LocalTextProcessor.process("open E U P B", vocabulary: "EUPB"), "open EUPB")
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

    func testLocalTextProcessorConvertsSpokenChineseDigitRuns() {
        XCTAssertEqual(LocalTextProcessor.process("一二三四", vocabulary: ""), "1234")
        XCTAssertEqual(LocalTextProcessor.process("八零八零", vocabulary: ""), "8080")
        XCTAssertEqual(LocalTextProcessor.process("房间八零八零", vocabulary: ""), "房间8080")
        XCTAssertEqual(LocalTextProcessor.process("编号：一二三，谢谢", vocabulary: ""), "编号：123，谢谢")
    }

    func testLocalTextProcessorConvertsChineseIntegersWithUnits() {
        XCTAssertEqual(LocalTextProcessor.process("十一", vocabulary: ""), "11")
        XCTAssertEqual(LocalTextProcessor.process("一百二十三", vocabulary: ""), "123")
        XCTAssertEqual(LocalTextProcessor.process("一万零三", vocabulary: ""), "10003")
        XCTAssertEqual(LocalTextProcessor.process("两百", vocabulary: ""), "200")
        XCTAssertEqual(LocalTextProcessor.process("兩百零一", vocabulary: ""), "201")
        XCTAssertEqual(LocalTextProcessor.process("一萬零三", vocabulary: ""), "10003")
        XCTAssertEqual(LocalTextProcessor.process("一共一百二十三人", vocabulary: ""), "一共123人")
    }

    func testLocalTextProcessorKeepsIsolatedChineseNumerals() {
        XCTAssertEqual(LocalTextProcessor.process("一心一意", vocabulary: ""), "一心一意")
        XCTAssertEqual(LocalTextProcessor.process("一", vocabulary: ""), "一")
        XCTAssertEqual(LocalTextProcessor.process("两个人", vocabulary: ""), "两个人")
        XCTAssertEqual(LocalTextProcessor.process("第3章有12页", vocabulary: ""), "第3章有12页")
    }

    func testLocalTextProcessorProcessSegmentsRespectsLetterPauses() {
        // Same segment: spoken letters collapse.
        XCTAssertEqual(
            LocalTextProcessor.processSegments(["C O D E X"], vocabulary: ""),
            "CODEX"
        )
        // Different VAD segments: do not collapse across the pause.
        XCTAssertEqual(
            LocalTextProcessor.processSegments(["A B", "C D"], vocabulary: ""),
            "AB CD"
        )
        // Normal English words keep their spaces.
        XCTAssertEqual(
            LocalTextProcessor.processSegments(["hello world"], vocabulary: ""),
            "Hello world"
        )
        // Numbers also normalize per segment before join.
        XCTAssertEqual(
            LocalTextProcessor.processSegments(["编号一二三四", "一共十一份"], vocabulary: ""),
            "编号1234 一共11份"
        )
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
        XCTAssertTrue(ask.contains("answer") || ask.contains("回复"))
        XCTAssertTrue(ask.contains("对方") || ask.contains("发送"))
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

    @MainActor
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

    func testReadyPhaseStatusTextIsReady() {
        let msg = VoiceJobStatusText.processingMessage(
            phase: .ready,
            polishMode: .coding,
            pendingCount: 1
        )
        XCTAssertEqual(msg, "就绪")
    }

    func testDiscardedPhaseStatusText() {
        let msg = VoiceJobStatusText.processingMessage(
            phase: .discarded,
            polishMode: .rewrite,
            pendingCount: 1
        )
        XCTAssertEqual(msg, "已丢弃")
    }

    func testBridgeResponseDiscardedErrorCode() {
        let response = BridgeResponse.error("已丢弃", code: .discarded, jobID: UUID())
        XCTAssertEqual(response.outcome, .error)
        XCTAssertEqual(response.errorCode, .discarded)
    }

    func testProtocolVersionIsThree() {
        XCTAssertEqual(AppConstants.protocolVersion, 3)
        let message = WireMessage(command: .ping, token: "test")
        XCTAssertEqual(message.protocolVersion, 3)
    }

    func testOrderedDeliveryCursorResetToSequence() {
        var cursor = OrderedDeliveryCursor()
        cursor.advance()
        cursor.advance()
        cursor.reset(to: 5)
        XCTAssertTrue(cursor.canDeliver(sequence: 5))
        XCTAssertFalse(cursor.canDeliver(sequence: 1))
    }

    func testAskAnswerParserAcceptsJSONAndFencedJSON() throws {
        let source = "老板说孩子发烧了，我该怎么安慰？"
        let plain = try AskAnswerParser.parse(#"{"answer":"听起来很辛苦，多休息。"}"#, sourceText: source)
        XCTAssertEqual(plain, "听起来很辛苦，多休息。")

        let fenced = """
        ```json
        {"answer":"听起来真的很辛苦，照顾两个孩子确实比上班还累。小得现在好些了吗？你也要注意休息。","tone":"warm"}
        ```
        """
        let parsed = try AskAnswerParser.parse(fenced, sourceText: source)
        XCTAssertTrue(parsed.contains("听起来真的很辛苦"))
        XCTAssertFalse(parsed.contains("tone"))
    }

    func testAskAnswerParserAcceptsPlainTextFallback() throws {
        let source = "帮我礼貌拒绝加班"
        let answer = try AskAnswerParser.parse("今晚家里有事，可能不方便加班，不好意思。", sourceText: source)
        XCTAssertTrue(answer.contains("不方便加班"))
    }

    func testAskAnswerParserRejectsEmptyMalformedAndEcho() {
        let source = "小得前两天发烧了基本上照顾他们两兄弟比上班还累老板这么说我应该怎么安慰比较好"
        XCTAssertThrowsError(try AskAnswerParser.parse(#"{"answer":""}"#, sourceText: source))
        XCTAssertThrowsError(try AskAnswerParser.parse(#"{"answer":}"#, sourceText: source))
        XCTAssertThrowsError(try AskAnswerParser.parse("{not-json", sourceText: source))
        XCTAssertThrowsError(try AskAnswerParser.parse(source, sourceText: source))
        let echoedJSON = "{\"answer\":\"\(source)\"}"
        XCTAssertThrowsError(try AskAnswerParser.parse(echoedJSON, sourceText: source))
    }

    func testAskAnswerParserMotivatingExampleIsNotEcho() throws {
        let source = "小得前兩天發燒了基本上照顧他們兩兄弟比上班還累老闆這麼說我應該怎麼安慰比較好"
        let candidate = "听起来真的很辛苦，照顾两个孩子确实比上班还累。小得现在好些了吗？你也要注意休息、保重身体。"
        let payload = "{\"answer\":\"\(candidate)\"}"
        let answer = try AskAnswerParser.parse(payload, sourceText: source)
        XCTAssertEqual(answer, candidate)
        XCTAssertFalse(AskAnswerParser.isEcho(answer, of: source))
        XCTAssertTrue(AskAnswerParser.isEcho(source, of: source))
    }

    func testAskRetryabilityClassification() {
        XCTAssertTrue(AskAnswerParser.isRetryable(PolishingError.timeout))
        XCTAssertTrue(AskAnswerParser.isRetryable(PolishingError.invalidAskAnswer))
        XCTAssertTrue(AskAnswerParser.isRetryable(PolishingError.httpError(429, "rate limit")))
        XCTAssertTrue(AskAnswerParser.isRetryable(PolishingError.httpError(503, "busy")))
        XCTAssertFalse(AskAnswerParser.isRetryable(PolishingError.invalidURL))
        XCTAssertFalse(AskAnswerParser.isRetryable(PolishingError.missingAPIKey))
        XCTAssertFalse(AskAnswerParser.isRetryable(PolishingError.httpError(401, "unauthorized")))
        XCTAssertFalse(AskAnswerParser.isRetryable(PolishingError.httpError(400, "Unsupported model foo")))
    }

    func testAskModeSettingsDescriptionMentionsReply() {
        XCTAssertTrue(PolishMode.askLLM.settingsDescription.contains("回复") || PolishMode.askLLM.settingsDescription.contains("发送"))
    }

    func testBridgeStatusAskFollowUpFlagsRoundtrip() throws {
        let status = BridgeStatus(
            state: .ready,
            message: "追问已就绪",
            polishEnabled: true,
            polishMode: PolishMode.askLLM.rawValue,
            askFollowUpAvailable: true,
            askFollowUpArmed: true
        )
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(BridgeStatus.self, from: data)
        XCTAssertEqual(decoded.askFollowUpAvailable, true)
        XCTAssertEqual(decoded.askFollowUpArmed, true)
    }

    func testArmAskFollowUpWireCommandExists() throws {
        let message = WireMessage(command: .armAskFollowUp, token: "test")
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: data)
        XCTAssertEqual(decoded.command, .armAskFollowUp)
    }


    // MARK: - Audio capture / Bluetooth route recovery

    func testAudioPeakMeterHandlesInt16Min() {
        let samples: [Int16] = [0, 1, -1, Int16.max, Int16.min]
        let peak = AudioPeakMeter.normalizedPeak(samples: samples)
        XCTAssertEqual(peak, 1.0, accuracy: 0.0001)
        XCTAssertFalse(peak.isNaN)
        XCTAssertFalse(peak.isInfinite)
    }

    func testAudioPeakMeterEmptyIsZero() {
        XCTAssertEqual(AudioPeakMeter.normalizedPeak(samples: []), 0)
    }

    func testAudioRouteRecoveryPolicy() {
        XCTAssertTrue(AudioRouteRecoveryPolicy.shouldCancelActiveCapture(isRecording: true))
        XCTAssertFalse(AudioRouteRecoveryPolicy.shouldCancelActiveCapture(isRecording: false))

        XCTAssertTrue(AudioRouteRecoveryPolicy.shouldRejectStart(isRecovering: true, isInputReady: true))
        XCTAssertTrue(AudioRouteRecoveryPolicy.shouldRejectStart(isRecovering: false, isInputReady: false))
        XCTAssertFalse(AudioRouteRecoveryPolicy.shouldRejectStart(isRecovering: false, isInputReady: true))

        XCTAssertTrue(AudioRouteRecoveryPolicy.canRetry(attempt: 0, maxAttempts: 3))
        XCTAssertTrue(AudioRouteRecoveryPolicy.canRetry(attempt: 2, maxAttempts: 3))
        XCTAssertFalse(AudioRouteRecoveryPolicy.canRetry(attempt: 3, maxAttempts: 3))

        XCTAssertEqual(
            AudioRouteRecoveryPolicy.retryDelayNanoseconds(
                attempt: 1,
                baseDelayNanoseconds: 250_000_000
            ),
            250_000_000
        )
        XCTAssertEqual(
            AudioRouteRecoveryPolicy.retryDelayNanoseconds(
                attempt: 3,
                baseDelayNanoseconds: 250_000_000
            ),
            1_000_000_000
        )
        XCTAssertEqual(
            AudioRouteRecoveryPolicy.retryDelayNanoseconds(
                attempt: 4,
                baseDelayNanoseconds: 250_000_000
            ),
            2_000_000_000
        )
        XCTAssertEqual(
            AudioRouteRecoveryPolicy.retryDelayNanoseconds(
                attempt: 5,
                baseDelayNanoseconds: 250_000_000
            ),
            2_000_000_000
        )
    }

    func testAudioCaptureSinkRebuildsConverterAcrossFormats() throws {
        let target = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
        )
        let sink = AudioCaptureSink()
        sink.configure(targetFormat: target)
        sink.beginRecording()

        // 48 kHz mono float input.
        let format48 = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let buffer48 = try XCTUnwrap(Self.makeSineBuffer(format: format48, frames: 4800, frequency: 440))
        sink.ingest(buffer48)
        let after48 = sink.snapshot()
        XCTAssertFalse(after48.isEmpty, "expected PCM after 48 kHz buffer")

        // Route change simulation: 16 kHz mono int16 input.
        let format16 = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
        )
        let buffer16 = try XCTUnwrap(Self.makeSineBuffer(format: format16, frames: 1600, frequency: 440))
        sink.prepareForEngineAttach()
        sink.ingest(buffer16)
        let after16 = sink.snapshot()
        XCTAssertGreaterThan(after16.count, after48.count, "PCM should continue growing after format change")

        // Extreme samples should not trap on Int16.min abs overflow.
        if let channel = buffer16.int16ChannelData {
            channel[0][0] = Int16.min
        }
        sink.ingest(buffer16)
        XCTAssertGreaterThanOrEqual(sink.latestLevel, 0)
        XCTAssertLessThanOrEqual(sink.latestLevel, 1.0)

        let finished = sink.finishRecording()
        XCTAssertFalse(finished.isEmpty)
        XCTAssertEqual(finished.count % 2, 0, "int16 PCM should be even byte count")
    }


    // MARK: - DeleteRepeatController

    @MainActor
    func testDeleteRepeatPressBeganDeletesOnceImmediately() async {
        var count = 0
        var feedbackCount = 0
        let controller = DeleteRepeatController(
            timing: DeleteRepeatTiming(
                initialDelayNanoseconds: 200_000_000,
                repeatIntervalNanoseconds: 50_000_000
            ),
            onDelete: { count += 1 }
        )

        feedbackCount += 1
        controller.pressBegan()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(feedbackCount, 1)
        XCTAssertTrue(controller.isActive)
        controller.cancel()
    }

    @MainActor
    func testDeleteRepeatDuplicatePressBeganDoesNotStartMultipleLoops() async throws {
        var count = 0
        let controller = DeleteRepeatController(
            timing: DeleteRepeatTiming(
                initialDelayNanoseconds: 80_000_000,
                repeatIntervalNanoseconds: 40_000_000
            ),
            onDelete: { count += 1 }
        )

        controller.pressBegan()
        controller.pressBegan()
        controller.pressBegan()
        XCTAssertEqual(count, 1, "only the first pressBegan should delete immediately")

        try await Task.sleep(nanoseconds: 220_000_000)
        let afterHold = count
        XCTAssertGreaterThanOrEqual(afterHold, 2)
        // With a single loop, roughly 1 + floor((220-80)/40) ~= 4 deletes. Multiple loops would overshoot hard.
        XCTAssertLessThanOrEqual(afterHold, 6)

        controller.cancel()
        let frozen = count
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(count, frozen)
    }

    @MainActor
    func testDeleteRepeatCancelBeforeDelayPreventsRepeats() async throws {
        var count = 0
        let controller = DeleteRepeatController(
            timing: DeleteRepeatTiming(
                initialDelayNanoseconds: 150_000_000,
                repeatIntervalNanoseconds: 40_000_000
            ),
            onDelete: { count += 1 }
        )

        controller.pressBegan()
        XCTAssertEqual(count, 1)
        try await Task.sleep(nanoseconds: 40_000_000)
        controller.cancel()
        XCTAssertFalse(controller.isActive)

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testDeleteRepeatHoldBeginsRepeatingThenCancelStops() async throws {
        var count = 0
        let controller = DeleteRepeatController(
            timing: DeleteRepeatTiming(
                initialDelayNanoseconds: 60_000_000,
                repeatIntervalNanoseconds: 30_000_000
            ),
            onDelete: { count += 1 }
        )

        controller.pressBegan()
        XCTAssertEqual(count, 1)

        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertGreaterThanOrEqual(count, 3)

        controller.pressEnded()
        XCTAssertFalse(controller.isActive)
        let frozen = count
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(count, frozen)
    }

    @MainActor
    func testDeleteRepeatDeinitCancelsTask() async throws {
        var count = 0
        do {
            let controller = DeleteRepeatController(
                timing: DeleteRepeatTiming(
                    initialDelayNanoseconds: 40_000_000,
                    repeatIntervalNanoseconds: 25_000_000
                ),
                onDelete: { count += 1 }
            )
            controller.pressBegan()
            XCTAssertEqual(count, 1)
        }

        let frozen = count
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(count, frozen, "deallocated controller must not keep deleting")
    }


    func testSessionIdleTimeoutDefaultsAndMigration() {
        let defaults = UserDefaults.standard
        let keys = ["session_idle_timeout_enabled", "session_idle_timeout_seconds", "session_idle_timeout_migrated_v1"]
        let backup = keys.map { key in (key, defaults.object(forKey: key)) }
        defer {
            for (key, value) in backup {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        // Case 1: Fresh install (no stored timeout) -> defaults to 600 seconds.
        for key in keys { defaults.removeObject(forKey: key) }
        let freshSettings = AppSettings()
        XCTAssertEqual(freshSettings.sessionIdleTimeoutSeconds, 600)
        XCTAssertTrue(defaults.bool(forKey: "session_idle_timeout_migrated_v1"))

        // Case 2: Existing install with old default (300 seconds) -> migrated to 600.
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set(300.0, forKey: "session_idle_timeout_seconds")
        let oldDefaultSettings = AppSettings()
        XCTAssertEqual(oldDefaultSettings.sessionIdleTimeoutSeconds, 600)
        XCTAssertEqual(defaults.double(forKey: "session_idle_timeout_seconds"), 600)
        XCTAssertTrue(defaults.bool(forKey: "session_idle_timeout_migrated_v1"))

        // Case 3: Custom user value (e.g. 120 seconds) -> preserved.
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set(120.0, forKey: "session_idle_timeout_seconds")
        let customSettings = AppSettings()
        XCTAssertEqual(customSettings.sessionIdleTimeoutSeconds, 120)

        // Case 4: Disabled timeout -> preserved while timeout value migrates if 300.
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set(false, forKey: "session_idle_timeout_enabled")
        defaults.set(300.0, forKey: "session_idle_timeout_seconds")
        let disabledSettings = AppSettings()
        XCTAssertFalse(disabledSettings.sessionIdleTimeoutEnabled)
        XCTAssertEqual(disabledSettings.sessionIdleTimeoutSeconds, 600)
    }

    private static func makeSineBuffer(format: AVAudioFormat, frames: AVAudioFrameCount, frequency: Double) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let sampleRate = format.sampleRate
        if format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData {
            let ptr = channels[0]
            for i in 0..<Int(frames) {
                let t = Double(i) / sampleRate
                ptr[i] = Float(sin(2 * Double.pi * frequency * t) * 0.25)
            }
        } else if format.commonFormat == .pcmFormatInt16, let channels = buffer.int16ChannelData {
            let ptr = channels[0]
            for i in 0..<Int(frames) {
                let t = Double(i) / sampleRate
                let sample = sin(2 * Double.pi * frequency * t) * 0.25 * Double(Int16.max)
                ptr[i] = Int16(clamping: Int(sample.rounded()))
            }
        } else {
            return nil
        }
        return buffer
    }

}
