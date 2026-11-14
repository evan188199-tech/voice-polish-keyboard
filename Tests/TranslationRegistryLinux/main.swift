import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor FixtureTransport: TranslationHTTPTransport {
    enum Mode { case success, wait, timeout }
    private var mode: Mode = .success
    private(set) var sent = 0
    func set(_ value: Mode) { mode = value }
    func count() -> Int { sent }
    func send(_ request: URLRequest) async throws -> TranslationHTTPReply {
        sent += 1
        switch mode {
        case .timeout: throw URLError(.timedOut)
        case .wait: try await Task.sleep(nanoseconds: 10_000_000_000)
        case .success: break
        }
        let outer = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = outer["messages"] as! [[String: String]]
        let source = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: String]
        let translated = source["source_text"] == "虚构甲" ? "Fictional alpha" : "Fictional beta"
        let inner = try JSONSerialization.data(withJSONObject: ["target": "en", "translation": translated])
        let reply: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": String(decoding: inner, as: UTF8.self)]]]]
        return TranslationHTTPReply(status: 200, body: try JSONSerialization.data(withJSONObject: reply))
    }
}

@main enum RegistryChecks {
    static func main() async throws {
        let fake = FixtureTransport(), registry = TranslationServiceRegistry()
        let settings = PolishingSettings(baseURL: "https://fixture.invalid", modelName: "fixture", apiKey: "fixture-only")
        let approval = TranslationServiceApproval(serviceID: "fixture", endpoint: settings.baseURL, model: settings.modelName, targets: [.english])
        func config(_ enabled: Bool = true, _ authorized: Bool = true) -> TranslationFactoryConfiguration {
            .init(settings: settings, serviceID: "fixture", serviceLabel: "fixture", verifiedTargets: [.english], approval: approval, userEnabled: enabled, networkAuthorized: authorized)
        }
        func request(_ source: String) -> TranslationRequest {
            .init(context: .init(target: .english, sourceKind: .typed, consentServiceID: "fixture"), source: source)
        }
        func check(_ condition: Bool, _ label: String) {
            guard condition else { print("FAIL: \(label)"); exit(1) }; print("PASS: \(label)")
        }
        let initial = await registry.capability
        check(!initial.isAvailable, "default registry is unavailable")
        do { _ = try await registry.translate(request("虚构甲")); check(false, "disabled request") } catch {}
        check(await fake.count() == 0, "disabled state does not call transport")
        await registry.configure(config(true, false), transport: fake)
        let denied = await registry.capability
        check(!denied.isAvailable, "missing network approval stays disabled")
        do { _ = try await registry.translate(request("虚构甲")); check(false, "unapproved request") } catch {}
        check(await fake.count() == 0, "unapproved request never calls transport")
        await registry.configure(config(), transport: fake)
        let bridge = TranslationBridgeHandler(service: registry)
        let available = await registry.capability
        check(available.isAvailable, "explicit fictional approval enables injected service")
        async let first = registry.translate(request("虚构甲"))
        async let second = registry.translate(request("虚构乙"))
        let (a, b) = try await (first, second)
        check(a.translation == "Fictional alpha" && b.translation == "Fictional beta" && a.context.id != b.context.id, "concurrent requests retain their own result")
        await fake.set(.timeout)
        do { _ = try await registry.translate(request("虚构甲")); check(false, "timeout") }
        catch { check((error as? TranslationFailure) == .timeout, "timeout remains explicit") }
        await fake.set(.wait)
        let cancelRequest = request("虚构甲"), beforeCancel = await fake.count()
        let cancelTask = Task { try await registry.translate(cancelRequest) }
        for _ in 0..<100 where await fake.count() == beforeCancel { try await Task.sleep(nanoseconds: 5_000_000) }
        check(await fake.count() > beforeCancel, "cancel fixture reached transport")
        _ = await bridge.handle(.init(operation: .cancel, requestID: cancelRequest.context.id), targets: [.english])
        do { _ = try await cancelTask.value; check(false, "cancel") }
        catch { check((error as? TranslationFailure) == .cancelled, "job cancellation reaches persistent service") }
        let pending = request("虚构乙"), beforeRevoke = await fake.count()
        let pendingTask = Task { try await registry.translate(pending) }
        for _ in 0..<100 where await fake.count() == beforeRevoke { try await Task.sleep(nanoseconds: 5_000_000) }
        check(await fake.count() > beforeRevoke, "revoke fixture reached transport")
        await registry.revoke()
        do { _ = try await pendingTask.value; check(false, "revoked request") }
        catch { check((error as? TranslationFailure) == .cancelled || (error as? TranslationFailure) == .serviceChanged, "revocation cancels pending work") }
        let afterRevoke = await fake.count()
        do { _ = try await registry.translate(request("虚构甲")); check(false, "post-revocation request") } catch {}
        check(await fake.count() == afterRevoke, "revoked state does not call transport")
        await registry.configure(config(), transport: fake)
        let changing = request("虚构甲"), beforeChange = await fake.count()
        let changingTask = Task { try await registry.translate(changing) }
        for _ in 0..<100 where await fake.count() == beforeChange { try await Task.sleep(nanoseconds: 5_000_000) }
        check(await fake.count() > beforeChange, "configuration change fixture reached transport")
        await registry.configure(config(false), transport: fake)
        do { _ = try await changingTask.value; check(false, "configuration change") }
        catch { check((error as? TranslationFailure) == .cancelled || (error as? TranslationFailure) == .serviceChanged, "configuration change cancels old work") }
        let changed = await registry.capability
        check(!changed.isAvailable, "disabled replacement remains unavailable")
        print("Translation registry checks passed")
    }
}
