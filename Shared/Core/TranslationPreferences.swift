import Foundation
import Combine

@MainActor final class TranslationPreferences: ObservableObject {
    static let shared = TranslationPreferences()
    @Published private(set) var targets: [TranslationTarget]
    @Published private(set) var consentServiceID: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "translation_targets_v1"), let saved = try? JSONDecoder().decode([TranslationTarget].self, from: data) {
            var seen = Set<TranslationTarget>()
            targets = saved.filter { $0.isValid && seen.insert($0).inserted }
        } else { targets = TranslationTarget.choices }
        consentServiceID = defaults.string(forKey: "translation_consent_service_v1")
    }
    func add(_ target: TranslationTarget) {
        guard target.isValid, !targets.contains(target) else { return }
        targets.append(target); save()
    }
    func remove(_ target: TranslationTarget) { targets.removeAll { $0 == target }; save() }
    func move(from index: Int, to destination: Int) {
        guard targets.indices.contains(index), destination >= 0, destination <= targets.count else { return }
        let target = targets.remove(at: index)
        targets.insert(target, at: min(destination > index ? destination - 1 : destination, targets.count)); save()
    }
    func consent(to serviceID: String?) {
        consentServiceID = serviceID
        if let serviceID { defaults.set(serviceID, forKey: "translation_consent_service_v1") }
        else { defaults.removeObject(forKey: "translation_consent_service_v1") }
    }
    private func save() { if let data = try? JSONEncoder().encode(targets) { defaults.set(data, forKey: "translation_targets_v1") } }
}
