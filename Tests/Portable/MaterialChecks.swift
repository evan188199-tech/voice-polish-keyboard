import Foundation

private struct FailingTermStorage: PrivateTermStorage {
    enum Operation { case load, save, clear }
    let failure: Operation
    func load() throws -> PrivateTermArchive? {
        if failure == .load { throw CocoaError(.fileReadNoPermission) }
        return nil
    }
    func save(_ archive: PrivateTermArchive) throws {
        if failure == .save { throw CocoaError(.fileWriteNoPermission) }
    }
    func clear() throws {
        if failure == .clear { throw CocoaError(.fileWriteNoPermission) }
    }
}

@MainActor enum MaterialChecks {
    static func run() async {
        let check = KeyboardChecks.check
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("material-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LocalPrivateTermStorage(directory: directory)
        let session = PrivateMaterialSession(storage: storage)
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
        session.closeScreen()
        check(session.account == nil && session.privateTerms.isEmpty, "closing screen clears transient account and terms")
        let restored = PrivateMaterialSession(storage: storage)
        await restored.useDemo("fixture-A")
        check(restored.privateTerms.count == 1 && restored.privateTerms[0].term == "桂林", "confirmed terms survive closing screen and a new session for the same account")
        await session.useDemo("fixture-A")
        let saved = try! Data(contentsOf: directory.appendingPathComponent("terms.json"))
        check(!String(decoding: saved, as: UTF8.self).contains("fictional do not retain") && !String(decoding: saved, as: UTF8.self).contains("虚构私人路线"), "unselected and ignored source fields never reach storage")
        let version = session.cacheVersion
        await session.useDemo("fixture-B")
        check(session.privateTerms.isEmpty && session.materials.allSatisfy { $0.accountID == "fixture-B" } && session.cacheVersion > version, "account switch clears cache and isolates workspaces")
        let switchedBack = PrivateMaterialSession(storage: storage)
        await switchedBack.useDemo("fixture-A")
        check(switchedBack.privateTerms.isEmpty, "switching accounts removes the previous account's persisted terms")
        do { try session.confirmImport(preview, selected: [preview.candidates[0].id], expectedAccount: "fixture-A", reviewed: true); check(false, "stale preview must fail") }
        catch { check(true, "stale account import is blocked") }
        check(session.keyboardSnapshot(hasFullAccess: false) == nil && session.keyboardSnapshot(hasFullAccess: true) == nil, "private keyboard sharing fails closed without verified secure transport")
        let snapshot = MaterialKeyboardSnapshot(accountID: "fixture-B", version: 3, expiresAt: now.addingTimeInterval(20), items: [])
        check(snapshot.isValid(accountID: "fixture-B", version: 3, now: now)
              && !snapshot.isValid(accountID: "fixture-A", version: 3, now: now)
              && !snapshot.isValid(accountID: "fixture-B", version: 2, now: now)
              && !snapshot.isValid(accountID: "fixture-B", version: 3, now: now.addingTimeInterval(30)), "snapshot account/version/expiry gates")
        try! session.confirmImport(preview, selected: [preview.candidates[0].id], expectedAccount: "fixture-B", reviewed: true)
        session.revoke()
        check(session.account == nil && session.privateTerms.isEmpty && session.materials.isEmpty, "revoke/logout removes all prototype cache")
        check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("terms.json").path), "revoke removes the persisted archive")
        let failing = PrivateMaterialSession(storage: FailingTermStorage(failure: .save))
        await failing.useDemo("fixture-A")
        do { try failing.confirmImport(preview, selected: [preview.candidates[0].id], expectedAccount: "fixture-A", reviewed: true); check(false, "storage failure must be reported") }
        catch { check(failing.privateTerms.isEmpty, "failed save does not import into memory") }
        let unreadable = PrivateMaterialSession(storage: FailingTermStorage(failure: .load))
        await unreadable.useDemo("fixture-A")
        check(unreadable.account == nil && unreadable.status == MaterialPrototypeError.storageFailed.localizedDescription, "read failure does not appear as an empty account")
        let undeletable = PrivateMaterialSession(storage: FailingTermStorage(failure: .clear))
        await undeletable.useDemo("fixture-A")
        undeletable.logout()
        check(undeletable.account == nil && undeletable.status == MaterialPrototypeError.clearFailed.localizedDescription, "failed deletion is reported instead of claiming cache was cleared")
        undeletable.closeScreen()
        check(undeletable.status == MaterialPrototypeError.clearFailed.localizedDescription, "closing the screen does not hide a failed deletion")
        await undeletable.useDemo("fixture-A")
        check(undeletable.account == nil && undeletable.status == MaterialPrototypeError.clearFailed.localizedDescription, "failed logout cannot reopen an account until deletion succeeds")
        let corruptFile = directory.appendingPathComponent("terms.json")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! Data("broken".utf8).write(to: corruptFile)
        let corrupt = PrivateMaterialSession(storage: storage)
        await corrupt.useDemo("fixture-A")
        check(corrupt.account == nil && corrupt.privateTerms.isEmpty, "corrupt archive fails closed")
        corrupt.logout()
        check(!FileManager.default.fileExists(atPath: corruptFile.path), "logout can remove an unreadable archive")
    }
}
