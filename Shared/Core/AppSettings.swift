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
    @Published var styleProfiles: [StyleProfile] = StyleProfile.builtins
    @Published var activeStyleProfileID: String = "builtin.rewrite" {
        didSet {
            guard isLoaded else { return }
            if let style = activeStyleProfile {
                polishMode = style.mode
            }
            save()
        }
    }
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
    var vocabularyDestination: String {
        [activePolishProfileID, PolishingSettings.normalizeBaseURL(baseURL), modelName].joined(separator: "|")
    }
    var selectedPolishVocabulary: String? {
        let entries = VocabularyEntry.load()
        let ids = Set(entries.filter { $0.polishDestination == vocabularyDestination }.map(\.id))
        return PolishContextPolicy.payload(entries: entries, selectedIDs: ids)
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
    /// Auto-close the iOS voice session after idle (no hold-to-talk).
    @Published var sessionIdleTimeoutEnabled: Bool {
        didSet {
            guard isLoaded else { return }
            save()
        }
    }
    /// Idle seconds before auto deactivate. Default 300 (5 minutes).
    @Published var sessionIdleTimeoutSeconds: TimeInterval {
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
    /// Output script preference: simplified / traditionalHK.  Defaults to simplified.
    @Published var chineseScript: ChineseScriptPreference {
        didSet {
            guard isLoaded else { return }
            save()
        }
    }
    /// Auto-capture the system clipboard when the keyboard appears (default true).
    @Published var clipboardHistoryEnabled: Bool {
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
        if defaults.object(forKey: "session_idle_timeout_enabled") == nil {
            sessionIdleTimeoutEnabled = true
        } else {
            sessionIdleTimeoutEnabled = defaults.bool(forKey: "session_idle_timeout_enabled")
        }
        if !defaults.bool(forKey: "session_idle_timeout_migrated_v1") {
            defaults.set(true, forKey: "session_idle_timeout_migrated_v1")
            let rawIdle = defaults.object(forKey: "session_idle_timeout_seconds") as? Double
            if rawIdle == 300 {
                defaults.set(600.0, forKey: "session_idle_timeout_seconds")
            }
        }

        let idle = defaults.double(forKey: "session_idle_timeout_seconds")
        if idle > 0 {
            sessionIdleTimeoutSeconds = min(
                max(idle, AppConstants.minimumSessionIdleTimeoutSeconds),
                AppConstants.absoluteMaxSessionIdleTimeoutSeconds
            )
        } else {
            sessionIdleTimeoutSeconds = AppConstants.defaultSessionIdleTimeoutSeconds
        }
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
        if let rawScript = defaults.string(forKey: "chinese_script"),
           let pref = ChineseScriptPreference(rawValue: rawScript) {
            chineseScript = pref
        } else {
            chineseScript = .default
        }
        if defaults.object(forKey: "clipboard_history_enabled") == nil {
            clipboardHistoryEnabled = true
        } else {
            clipboardHistoryEnabled = defaults.bool(forKey: "clipboard_history_enabled")
        }

        loadOrMigrateProfiles(defaults: defaults)
        loadOrMigrateStyles(defaults: defaults)
        isLoaded = true
    }

    var activePolishProfile: PolishAPIProfile? {
        polishProfiles.first(where: { $0.id == activePolishProfileID }) ?? polishProfiles.first
    }

    var activeStyleProfile: StyleProfile? {
        styleProfiles.first(where: { $0.id == activeStyleProfileID })
            ?? styleProfiles.first(where: { $0.id == "builtin.rewrite" })
    }

    func saveStyle(_ style: StyleProfile) {
        guard !style.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let index = styleProfiles.firstIndex(where: { $0.id == style.id }) {
            styleProfiles[index] = style
        } else {
            styleProfiles.append(style)
        }
        activeStyleProfileID = style.id
        save()
    }

    func deleteStyle(id: String) {
        guard let index = styleProfiles.firstIndex(where: { $0.id == id }), !styleProfiles[index].isBuiltin else { return }
        styleProfiles.remove(at: index)
        if activeStyleProfileID == id { activeStyleProfileID = "builtin.rewrite" }
        save()
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

    private func loadOrMigrateStyles(defaults: UserDefaults) {
        let custom: [StyleProfile]
        if let data = defaults.data(forKey: "style_profiles_v1"),
           let decoded = try? JSONDecoder().decode([StyleProfile].self, from: data) {
            custom = decoded.filter { !$0.isBuiltin }
        } else {
            custom = []
        }
        styleProfiles = StyleProfile.builtins + custom
        let saved = defaults.string(forKey: "active_style_profile_id") ?? ""
        if styleProfiles.contains(where: { $0.id == saved }) {
            activeStyleProfileID = saved
        } else {
            activeStyleProfileID = builtinStyleID(for: polishMode)
        }
    }

    private func builtinStyleID(for mode: PolishMode) -> String {
        switch mode {
        case .correctOnly: return "builtin.correct"
        case .coding: return "builtin.coding"
        case .rewrite, .askLLM: return "builtin.rewrite"
        }
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
        defaults.set(sessionIdleTimeoutEnabled, forKey: "session_idle_timeout_enabled")
        defaults.set(sessionIdleTimeoutSeconds, forKey: "session_idle_timeout_seconds")
        defaults.set(polishEnabled, forKey: "polish_enabled")
        defaults.set(polishMode.rawValue, forKey: "polish_mode")
        defaults.set(compareWithSystemDictation, forKey: "compare_with_system_dictation")
        defaults.set(chineseScript.rawValue, forKey: "chinese_script")
        defaults.set(clipboardHistoryEnabled, forKey: "clipboard_history_enabled")
        defaults.set(activePolishProfileID, forKey: "active_polish_profile_id")
        defaults.set(activeStyleProfileID, forKey: "active_style_profile_id")
        let customStyles = styleProfiles.filter { !$0.isBuiltin }
        if let data = try? JSONEncoder().encode(customStyles) {
            defaults.set(data, forKey: "style_profiles_v1")
        }
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
