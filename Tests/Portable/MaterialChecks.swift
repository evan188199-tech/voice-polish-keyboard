import Foundation

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
        let draft = try! session.draft(approved, confirmed: true)
        check(draft.contains("虚构") && draft.contains("https://customer.example.test/demo"), "eligible text is an editable draft, not a send action")
        let data = #"{"terms":[{"term":"桂林","kind":"place","internalNote":"fictional do not retain"},{"term":"虚构私人路线","kind":"privateRoute"},{"term":"phone 123456","kind":"general"},{"term":"https://fixture.invalid/private","kind":"general"}],"ignoredSource":"fictional"}"#.data(using: .utf8)!
        let preview = try! TermImportPreview.parse(data)
        check(preview.candidates.count == 2 && preview.rejectedCount == 2 && preview.ignoredFieldCount == 2, "whitelist preview ignores private extra fields and rejects unsafe terms")
        check(session.privateTerms.isEmpty, "preview never imports automatically")
        do { try session.confirmImport(preview, selected: [preview.candidates[0].id], expectedAccount: "fixture-A"); check(false, "review required") }
        catch { check(session.privateTerms.isEmpty, "manual review confirmation is enforced in core") }
        try! session.confirmImport(preview, selected: [preview.candidates[0].id], expectedAccount: "fixture-A", reviewed: true)
        check(session.privateTerms.count == 1 && session.privateTerms[0].term == "桂林", "only explicitly selected allowlisted term enters local index")
        let version = session.cacheVersion
        await session.useDemo("fixture-B")
        check(session.privateTerms.isEmpty && session.materials.allSatisfy { $0.accountID == "fixture-B" } && session.cacheVersion > version, "account switch clears cache and isolates workspaces")
        do { try session.confirmImport(preview, selected: [preview.candidates[0].id], expectedAccount: "fixture-A", reviewed: true); check(false, "stale preview must fail") }
        catch { check(true, "stale account import is blocked") }
        check(session.keyboardSnapshot(hasFullAccess: false) == nil && session.keyboardSnapshot(hasFullAccess: true) == nil, "private keyboard sharing fails closed without verified secure transport")
        let snapshot = MaterialKeyboardSnapshot(accountID: "fixture-B", version: 3, expiresAt: now.addingTimeInterval(20), items: [])
        check(snapshot.isValid(accountID: "fixture-B", version: 3, now: now)
              && !snapshot.isValid(accountID: "fixture-A", version: 3, now: now)
              && !snapshot.isValid(accountID: "fixture-B", version: 2, now: now)
              && !snapshot.isValid(accountID: "fixture-B", version: 3, now: now.addingTimeInterval(30)), "snapshot account/version/expiry gates")
        session.revoke()
        check(session.account == nil && session.privateTerms.isEmpty && session.materials.isEmpty, "revoke/logout removes all prototype cache")
    }
}
