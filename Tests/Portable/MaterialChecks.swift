import Foundation

actor DelayedMaterialAdapter: MaterialReadOnlyAdapter {
    private var pending: [String: CheckedContinuation<[ProductMaterial], Error>] = [:]
    func materials(for account: MaterialAccount, now: Date) async throws -> [ProductMaterial] {
        try await withCheckedThrowingContinuation { pending[account.id] = $0 }
    }
    func resolve(_ id: String) {
        pending.removeValue(forKey: id)?.resume(returning: [ProductMaterial(accountID: id, displayName: "虚构内容")])
    }
    func hasPending(_ id: String) -> Bool { pending[id] != nil }
}

actor CrossAccountMaterialAdapter: MaterialReadOnlyAdapter {
    func materials(for account: MaterialAccount, now: Date) async throws -> [ProductMaterial] {
        var wrongSource = ProductMaterial(accountID: account.id, displayName: "另一来源虚构素材")
        wrongSource.sourceScope = "foreign-source"
        return [ProductMaterial(accountID: account.id, displayName: "本账号虚构素材"),
                ProductMaterial(accountID: "foreign-fixture", displayName: "另账号虚构素材"), wrongSource]
    }
}

actor StableMaterialAdapter: MaterialReadOnlyAdapter {
    private let stableID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    func materials(for account: MaterialAccount, now: Date) async throws -> [ProductMaterial] {
        var item = ProductMaterial(accountID: account.id, displayName: "虚构稳定素材")
        item.id = stableID
        item.approvedSummary = "虚构摘要"
        item.customerURL = URL(string: "https://customer.example.test/fake")!
        item.customerAccessVerified = true
        item.attribution = "虚构来源"
        item.verification = .verified
        item.visibility = .customerApproved
        item.channels = ["customerDraft"]
        item.expiresAt = Date(timeIntervalSince1970: 4102444800)
        return [item]
    }
}

@MainActor enum MaterialChecks {
    static func run() async {
        let check = KeyboardChecks.check
        let session = PrivateMaterialSession()
        session.connectProduction()
        check(!session.productionConnected && session.account == nil, "production account remains genuinely disconnected")
        await session.useDemo("fixture-A")
        let approved = session.materials[0]
        let now = Date()
        func denial(_ value: ProductMaterial, confirmed: Bool = true) -> String? {
            MaterialGate.rejection(value, account: session.account, channel: "customerDraft", action: .textDraft, userConfirmed: confirmed, now: now)
        }
        check(denial(approved) == nil && denial(approved, confirmed: false) != nil, "mock approved material still requires this-use confirmation")
        var invalid = approved; invalid.verification = .unverified
        check(denial(invalid) != nil, "unverified material blocked")
        invalid = approved; invalid.visibility = .pending
        check(denial(invalid) != nil, "pending visibility blocked")
        invalid.visibility = .internalOnly
        check(denial(invalid) != nil, "internal material blocked")
        invalid = approved; invalid.expiresAt = now.addingTimeInterval(-1)
        check(denial(invalid) != nil, "expired material blocked")
        invalid = approved; invalid.channels = ["other"]
        check(denial(invalid) != nil, "wrong channel blocked")
        invalid = approved; invalid.customerAccessVerified = false
        check(denial(invalid) != nil, "readable page is not proof of customer file access")
        for url in ["https://notion.so/internal", "https://drive.google.com/file/a", "https://customer.example.test/a?token=fixture", "http://customer.example.test/a", "https://user:pass@customer.example.test/a", "https://127.0.0.1/a"] {
            invalid = approved; invalid.customerURL = URL(string: url)
            check(denial(invalid) != nil, "internal/token/insecure/credential/IP URL blocked")
        }
        var forged = approved
        forged.id = UUID()
        do { _ = try session.select(forged); check(false, "unregistered material must be rejected") }
        catch { check(true, "unregistered material cannot masquerade as an approved reference") }
        let approvedSelection = try! session.select(approved)
        let textReference = try! session.textReference(approved, selection: approvedSelection, confirmed: true)
        let imageReference = try! session.imageReference(approved, selection: approvedSelection, confirmed: true)
        check(textReference.sourceVersion == approved.version && imageReference.materialID == approved.id && imageReference.sourceScope == "demo",
              "text and image references retain only current approved source identity")
        let draft = try! session.draft(approved, selection: approvedSelection, confirmed: true)
        check(session.rejection(approved, selection: approvedSelection, action: .textDraft, confirmed: true,
                                now: now.addingTimeInterval(3600)) != nil,
              "expired material is blocked again at actual use")
        var alteredVersion = approved; alteredVersion.version += 1
        check(session.rejection(alteredVersion, selection: approvedSelection, action: .textDraft, confirmed: true) != nil,
              "material version or fields cannot be altered after confirmation")
        check(session.rejection(approved, selection: approvedSelection, action: .image, confirmed: false) != nil,
              "image action requires explicit confirmation")
        check(draft.contains("虚构") && draft.contains("https://customer.example.test/demo"), "eligible text is an editable draft, not a send action")
        let data = #"{"terms":[{"term":"桂林","kind":"place","internalNote":"fictional do not retain"},{"term":"虚构私人路线","kind":"privateRoute"},{"term":"phone 123456","kind":"general"},{"term":"https://fixture.invalid/private","kind":"general"}],"ignoredSource":"fictional"}"#.data(using: .utf8)!
        let preview = try! session.previewImport(data)
        check(preview.candidates.count == 2 && preview.rejectedCount == 2 && preview.ignoredFieldCount == 2, "whitelist preview ignores private extra fields and rejects unsafe terms")
        check(session.privateTerms.isEmpty, "preview never imports automatically")
        do { try session.confirmImport(preview, selected: [preview.candidates[0].id], expectedAccount: "fixture-A"); check(false, "review required") }
        catch { check(session.privateTerms.isEmpty, "manual review confirmation is enforced in core") }
        try! session.confirmImport(preview, selected: [preview.candidates[0].id], expectedAccount: "fixture-A", reviewed: true)
        check(session.privateTerms.count == 1 && session.privateTerms[0].term == "桂林", "only explicitly selected allowlisted term enters local index")
        check(session.searchTerms("桂").map(\.term) == ["桂林"] && session.searchTerms("无匹配").isEmpty,
              "private index search is limited to confirmed current-session terms")
        check(session.searchMaterials("虚构").count == 2, "material search stays within current local snapshot")
        let replacedPreview = try! session.previewImport(data)
        let stalePreview = try! session.previewImport(data)
        do { try session.confirmImport(replacedPreview, selected: [replacedPreview.candidates[0].id], expectedAccount: "fixture-A", reviewed: true); check(false, "replaced preview must not import") }
        catch { check(true, "new file preview invalidates the previous source preview") }
        let forgedPreview = TermImportPreview(id: stalePreview.id,
            candidates: [PrivateTermCandidate(term: "伪造词汇", kind: .privateRoute)],
            rejectedCount: stalePreview.rejectedCount, ignoredFieldCount: stalePreview.ignoredFieldCount)
        do { try session.confirmImport(forgedPreview, selected: [forgedPreview.candidates[0].id], expectedAccount: "fixture-A", reviewed: true); check(false, "modified preview must not import") }
        catch { check(true, "preview must match the exact registered source selection") }
        let version = session.cacheVersion
        await session.useDemo("fixture-B")
        check(session.privateTerms.isEmpty && session.materials.allSatisfy { $0.accountID == "fixture-B" } && session.cacheVersion > version, "account switch clears cache and isolates workspaces")
        do { try session.confirmImport(preview, selected: [preview.candidates[0].id], expectedAccount: "fixture-A", reviewed: true); check(false, "stale preview must fail") }
        catch { check(true, "stale account import is blocked") }
        await session.useDemo("fixture-A")
        do { try session.confirmImport(stalePreview, selected: [stalePreview.candidates[0].id], expectedAccount: "fixture-A", reviewed: true); check(false, "same account reopened must reject old preview") }
        catch { check(true, "account A-B-A cannot revive an old import preview") }
        check(session.rejection(approved, selection: approvedSelection, action: .textDraft, confirmed: true) != nil,
              "old material confirmation cannot survive account switch and return")
        check(session.keyboardSnapshot(hasFullAccess: false) == nil && session.keyboardSnapshot(hasFullAccess: true) == nil, "private keyboard sharing fails closed without verified secure transport")
        let snapshot = MaterialKeyboardSnapshot(accountID: "fixture-B", version: 3, expiresAt: now.addingTimeInterval(20), items: [])
        check(snapshot.isValid(accountID: "fixture-B", version: 3, now: now)
              && !snapshot.isValid(accountID: "fixture-A", version: 3, now: now)
              && !snapshot.isValid(accountID: "fixture-B", version: 2, now: now)
              && !snapshot.isValid(accountID: "fixture-B", version: 3, now: now.addingTimeInterval(30)), "snapshot account/version/expiry gates")
        session.revoke()
        check(session.account == nil && session.privateTerms.isEmpty && session.materials.isEmpty, "revoke/logout removes all prototype cache")

        let crossAccount = PrivateMaterialSession(adapter: CrossAccountMaterialAdapter())
        await crossAccount.useDemo("fixture-current")
        check(crossAccount.materials.count == 1 && crossAccount.materials.allSatisfy { $0.accountID == "fixture-current" },
              "adapter cannot expose another account or source in local search")

        let stable = PrivateMaterialSession(adapter: StableMaterialAdapter())
        await stable.useDemo("stable-A")
        let firstStable = stable.materials[0]
        let oldPermit = try! stable.select(firstStable)
        await stable.useDemo("stable-B")
        await stable.useDemo("stable-A")
        check(stable.materials[0] == firstStable, "fictional source can return the exact same item after account cycle")
        check(stable.rejection(firstStable, selection: oldPermit, action: .textDraft, confirmed: true) != nil,
              "identical material and account cannot revive a previous session permit")
        let newPermit = try! stable.select(stable.materials[0])
        check(stable.rejection(stable.materials[0], selection: newPermit, action: .textDraft, confirmed: true) == nil,
              "fresh session selection can authorize an eligible fictional reference")
        stable.revoke()
        check(stable.rejection(firstStable, selection: newPermit, action: .textDraft, confirmed: true) != nil,
              "revocation invalidates material permits immediately")

        let delayed = DelayedMaterialAdapter()
        let isolated = PrivateMaterialSession(adapter: delayed)
        let first = Task { await isolated.useDemo("fiction-A") }
        while !(await delayed.hasPending("fiction-A")) { await Task.yield() }
        let second = Task { await isolated.useDemo("fiction-B") }
        while !(await delayed.hasPending("fiction-B")) { await Task.yield() }
        await delayed.resolve("fiction-B"); await second.value
        await delayed.resolve("fiction-A"); await first.value
        check(isolated.account?.id == "fiction-B" && isolated.materials.allSatisfy { $0.accountID == "fiction-B" },
              "late old account result cannot overwrite newer account")
        let revoked = Task { await isolated.useDemo("fiction-C") }
        while !(await delayed.hasPending("fiction-C")) { await Task.yield() }
        isolated.revoke()
        await delayed.resolve("fiction-C"); await revoked.value
        check(isolated.account == nil && isolated.materials.isEmpty && isolated.privateTerms.isEmpty,
              "late mock response cannot restore revoked account data")
    }
}
