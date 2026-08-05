import Foundation
import Combine
import Security

struct PolishAPIProfile: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var baseURL: String
    var modelName: String

    static func make(
        name: String,
        baseURL: String,
        modelName: String,
        id: String = UUID().uuidString
    ) -> PolishAPIProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return PolishAPIProfile(
            id: id,
            name: trimmedName.isEmpty ? "配置" : trimmedName,
            baseURL: PolishingSettings.normalizeBaseURL(baseURL),
            modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

final class AppSettings: ObservableObject {
    private var isLoaded = false
    private var isApplyingProfile = false

    @Published var polishProfiles: [PolishAPIProfile] = []
    @Published var activePolishProfileID: String = "" {
        didSet {
            guard isLoaded, !isApplyingProfile else { return }
            applyActiveProfileToFields()
            save()
        }
    }

    /// Active profile base URL (kept for coordinator compatibility).
    @Published var baseURL: String = "https://api.openai.com" {
        didSet {
            guard isLoaded, !isApplyingProfile else { return }
            save()
        }
    }
    @Published var modelName: String = "gpt-4o-mini" {
        didSet {
            guard isLoaded, !isApplyingProfile else { return }
            save()
        }
    }
    @Published var customVocabulary: String {
        didSet {
            guard isLoaded else { return }
            save()
        }
    }
    @Published var maxRecordingDuration: TimeInterval {
        didSet {
            guard isLoaded else { return }
            save()
        }
    }
    /// When false, skip polish API and insert local transcription only.
    @Published var polishEnabled: Bool {
        didSet {
            guard isLoaded else { return }
            save()
        }
    }
    /// Active polish/processing mode when polish is enabled.
    @Published var polishMode: PolishMode {
        didSet {
            guard isLoaded else { return }
            save()
        }
    }
    /// iOS main app only: run Apple on-device dictation in parallel for A/B comparison.
    /// Default off; keyboard/IME insert path always uses SenseVoice only.
    @Published var compareWithSystemDictation: Bool {
        didSet {
            guard isLoaded else { return }
            save()
        }
    }
    /// iOS keyboard: offer Apple on-device alternatives before optional polish.
    @Published var voiceCandidateReviewEnabled: Bool {
        didSet {
            guard isLoaded else { return }
            save()
        }
    }
    /// macOS: launch companion at login (default true).
    @Published var launchAtLogin: Bool {
        didSet {
            guard isLoaded else { return }
            save()
            #if os(macOS)
            LaunchAtLoginHelper.setEnabled(launchAtLogin)
            #endif
        }
    }
    /// macOS: global Right Option push-to-talk fallback (default true).
    /// When false, companion stops listening for Right Option outside the IME path.
    @Published var rightOptionHotkeyEnabled: Bool {
        didSet {
            guard isLoaded else { return }
            save()
            #if os(macOS)
            NotificationCenter.default.post(
                name: .voicePolishRightOptionHotkeyEnabledDidChange,
                object: nil,
                userInfo: ["enabled": rightOptionHotkeyEnabled]
            )
            #endif
        }
    }

    /// Output script preference: simplified / traditionalHK.  Defaults to simplified.
    @Published var chineseScript: ChineseScriptPreference {
        didSet {
            guard isLoaded else { return }
            save()
        }
    }
    init() {
        let defaults = UserDefaults.standard
        customVocabulary = defaults.string(forKey: "custom_vocabulary") ?? ""
        let duration = defaults.double(forKey: "max_recording_duration")
        maxRecordingDuration = duration > 0 ? duration : AppConstants.defaultMaxRecordingDuration
        if defaults.object(forKey: "polish_enabled") == nil {
            polishEnabled = true
        } else {
            polishEnabled = defaults.bool(forKey: "polish_enabled")
        }
        if let rawMode = defaults.string(forKey: "polish_mode"),
           let mode = PolishMode(rawValue: rawMode) {
            polishMode = mode
        } else {
            polishMode = .default
        }
        if defaults.object(forKey: "compare_with_system_dictation") == nil {
            compareWithSystemDictation = false
        } else {
            compareWithSystemDictation = defaults.bool(forKey: "compare_with_system_dictation")
        }
        if defaults.object(forKey: "voice_candidate_review_enabled") == nil {
            voiceCandidateReviewEnabled = true
        } else {
            voiceCandidateReviewEnabled = defaults.bool(forKey: "voice_candidate_review_enabled")
        }
        if defaults.object(forKey: "launch_at_login") == nil {
            launchAtLogin = true
        } else {
            launchAtLogin = defaults.bool(forKey: "launch_at_login")
        }
        if defaults.object(forKey: "right_option_hotkey_enabled") == nil {
            rightOptionHotkeyEnabled = true
        } else {
            rightOptionHotkeyEnabled = defaults.bool(forKey: "right_option_hotkey_enabled")
        }
        if let rawScript = defaults.string(forKey: "chinese_script"),
           let pref = ChineseScriptPreference(rawValue: rawScript) {
            chineseScript = pref
        } else {
            chineseScript = .default
        }

        loadOrMigrateProfiles(defaults: defaults)
        isLoaded = true
    }

    var activePolishProfile: PolishAPIProfile? {
        polishProfiles.first(where: { $0.id == activePolishProfileID }) ?? polishProfiles.first
    }

    var hasAPIKey: Bool {
        guard let key = apiKey else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Active profile API key (keychain).
    var apiKey: String? {
        get {
            let id = activePolishProfile?.id ?? activePolishProfileID
            if !id.isEmpty,
               let value = KeychainHelper.read(service: Self.keychainService(for: id)),
               !value.isEmpty {
                return value
            }
            return KeychainHelper.read(service: "com.voicepolish.apikey")
        }
        set {
            let id = activePolishProfile?.id ?? activePolishProfileID
            let service = id.isEmpty ? "com.voicepolish.apikey" : Self.keychainService(for: id)
            if let value = newValue, !value.isEmpty {
                KeychainHelper.save(service: service, value: value)
                KeychainHelper.save(service: "com.voicepolish.apikey", value: value)
            } else {
                if !id.isEmpty {
                    KeychainHelper.delete(service: service)
                }
                KeychainHelper.delete(service: "com.voicepolish.apikey")
            }
        }
    }

    /// Save/overwrite the currently selected profile with draft fields.
    func saveActivePolishProfile(name: String, baseURL: String, modelName: String, apiKey: String) {
        let normalizedURL = PolishingSettings.normalizeBaseURL(baseURL)
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        isApplyingProfile = true
        if let index = polishProfiles.firstIndex(where: { $0.id == activePolishProfileID }) {
            var profile = polishProfiles[index]
            profile.name = trimmedName.isEmpty ? profile.name : trimmedName
            profile.baseURL = normalizedURL
            profile.modelName = trimmedModel
            polishProfiles[index] = profile
        } else {
            let profile = PolishAPIProfile.make(
                name: trimmedName.isEmpty ? defaultName(for: trimmedModel, baseURL: normalizedURL) : trimmedName,
                baseURL: normalizedURL,
                modelName: trimmedModel
            )
            polishProfiles.append(profile)
            activePolishProfileID = profile.id
        }
        self.baseURL = normalizedURL
        self.modelName = trimmedModel
        isApplyingProfile = false
        self.apiKey = trimmedKey.isEmpty ? nil : trimmedKey
        save()
    }

    /// Create a new profile from draft and switch to it.
    @discardableResult
    func saveAsNewPolishProfile(name: String, baseURL: String, modelName: String, apiKey: String) -> PolishAPIProfile {
        let normalizedURL = PolishingSettings.normalizeBaseURL(baseURL)
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = PolishAPIProfile.make(
            name: trimmedName.isEmpty ? defaultName(for: trimmedModel, baseURL: normalizedURL) : trimmedName,
            baseURL: normalizedURL,
            modelName: trimmedModel
        )
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        isApplyingProfile = true
        polishProfiles.append(profile)
        activePolishProfileID = profile.id
        self.baseURL = profile.baseURL
        self.modelName = profile.modelName
        isApplyingProfile = false
        self.apiKey = trimmedKey.isEmpty ? nil : trimmedKey
        save()
        return profile
    }

    func selectPolishProfile(id: String) {
        guard polishProfiles.contains(where: { $0.id == id }) else { return }
        if id == activePolishProfileID {
            applyActiveProfileToFields()
            return
        }
        activePolishProfileID = id
    }

    func deletePolishProfile(id: String) {
        guard polishProfiles.count > 1 else { return }
        guard let index = polishProfiles.firstIndex(where: { $0.id == id }) else { return }
        KeychainHelper.delete(service: Self.keychainService(for: id))
        polishProfiles.remove(at: index)
        if activePolishProfileID == id {
            activePolishProfileID = polishProfiles[0].id
        } else {
            save()
        }
    }

    /// Backward-compatible single-shot apply used by older call sites.
    func applyPolishAPI(baseURL: String, modelName: String, apiKey: String) {
        let name = activePolishProfile?.name ?? defaultName(for: modelName, baseURL: baseURL)
        saveActivePolishProfile(name: name, baseURL: baseURL, modelName: modelName, apiKey: apiKey)
    }

    private func loadOrMigrateProfiles(defaults: UserDefaults) {
        if let data = defaults.data(forKey: "polish_api_profiles"),
           let decoded = try? JSONDecoder().decode([PolishAPIProfile].self, from: data),
           !decoded.isEmpty {
            polishProfiles = decoded.map { raw in
                var profile = raw
                profile.baseURL = PolishingSettings.normalizeBaseURL(profile.baseURL)
                profile.modelName = profile.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
                if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    profile.name = "配置"
                }
                return profile
            }
            let savedActive = defaults.string(forKey: "active_polish_profile_id") ?? ""
            if polishProfiles.contains(where: { $0.id == savedActive }) {
                activePolishProfileID = savedActive
            } else {
                activePolishProfileID = polishProfiles[0].id
            }
            applyActiveProfileToFields()
            return
        }

        let legacyURL = PolishingSettings.normalizeBaseURL(
            defaults.string(forKey: "api_base_url") ?? "https://api.openai.com"
        )
        let legacyModel = (defaults.string(forKey: "api_model_name") ?? "gpt-4o-mini")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = PolishAPIProfile.make(
            name: defaultName(for: legacyModel, baseURL: legacyURL),
            baseURL: legacyURL,
            modelName: legacyModel
        )
        polishProfiles = [profile]
        activePolishProfileID = profile.id
        baseURL = profile.baseURL
        modelName = profile.modelName

        if let legacyKey = KeychainHelper.read(service: "com.voicepolish.apikey"), !legacyKey.isEmpty {
            KeychainHelper.save(service: Self.keychainService(for: profile.id), value: legacyKey)
        }
        save()
    }

    private func applyActiveProfileToFields() {
        guard let profile = activePolishProfile else { return }
        isApplyingProfile = true
        baseURL = profile.baseURL
        modelName = profile.modelName
        isApplyingProfile = false
        if let key = KeychainHelper.read(service: Self.keychainService(for: profile.id)), !key.isEmpty {
            KeychainHelper.save(service: "com.voicepolish.apikey", value: key)
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(baseURL, forKey: "api_base_url")
        defaults.set(modelName, forKey: "api_model_name")
        defaults.set(customVocabulary, forKey: "custom_vocabulary")
        defaults.set(maxRecordingDuration, forKey: "max_recording_duration")
        defaults.set(polishEnabled, forKey: "polish_enabled")
        defaults.set(polishMode.rawValue, forKey: "polish_mode")
        defaults.set(compareWithSystemDictation, forKey: "compare_with_system_dictation")
        defaults.set(voiceCandidateReviewEnabled, forKey: "voice_candidate_review_enabled")
        defaults.set(launchAtLogin, forKey: "launch_at_login")
        defaults.set(rightOptionHotkeyEnabled, forKey: "right_option_hotkey_enabled")
        defaults.set(chineseScript.rawValue, forKey: "chinese_script")
        defaults.set(activePolishProfileID, forKey: "active_polish_profile_id")
        if let data = try? JSONEncoder().encode(polishProfiles) {
            defaults.set(data, forKey: "polish_api_profiles")
        }
    }

    private func defaultName(for model: String, baseURL: String) -> String {
        if !model.isEmpty { return model }
        if let host = URL(string: baseURL)?.host, !host.isEmpty { return host }
        return "配置"
    }

    private static func keychainService(for profileID: String) -> String {
        "com.voicepolish.apikey.profile.\(profileID)"
    }
}

enum KeychainHelper {
    static func read(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(service: String, value: String) {
        delete(service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(service: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ] as CFDictionary)
    }
}

#if os(macOS)
import ServiceManagement

extension Notification.Name {
    static let voicePolishRightOptionHotkeyEnabledDidChange =
        Notification.Name("voicePolishRightOptionHotkeyEnabledDidChange")
}

enum LaunchAtLoginHelper {
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LaunchAtLogin failed: \(error.localizedDescription)")
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
#endif
