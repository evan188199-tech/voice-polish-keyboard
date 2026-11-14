#if os(iOS)
import Foundation
import CryptoKit
import Security

/// App-container-only encrypted storage. Never exposes the key to the keyboard.
/// iOS build, data protection and Keychain behavior require device validation.
final class ProtectedPrivateIndexStorage: PrivateIndexStorage, @unchecked Sendable {
    private static let lock = NSLock()
    private let directory: URL
    private let service = "com.voicepolish.private-index-key.v1"
    init(directory: URL) { self.directory = directory }

    func load(scope: PrivateIndexScope) throws -> PrivateIndexDocument? {
        try Self.lock.withLock {
            guard scope.isValid else { throw PrivateIndexError.invalid }
            let file = try fileURL(scope)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            guard let key = try existingKey(scope) else { throw PrivateIndexError.unavailable }
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_097_152 else { throw PrivateIndexError.invalid }
            let encrypted = try Data(contentsOf: file)
            guard encrypted.count <= 2_097_152 else { throw PrivateIndexError.invalid }
            let sealed = try AES.GCM.SealedBox(combined: encrypted)
            let plain = try AES.GCM.open(sealed, using: key)
            let result = try JSONDecoder().decode(PrivateIndexDocument.self, from: plain)
            guard result.scope == scope, result.isValid else { throw PrivateIndexError.wrongScope }
            return result
        }
    }
    func save(_ document: PrivateIndexDocument) throws {
        try Self.lock.withLock {
            guard document.isValid else { throw PrivateIndexError.invalid }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var protectedDirectory = directory
            var metadata = URLResourceValues(); metadata.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(metadata)
            let key = try existingKey(document.scope) ?? createKey(document.scope)
            let plain = try JSONEncoder().encode(document)
            guard plain.count <= 2_000_000 else { throw PrivateIndexError.invalid }
            guard let combined = try AES.GCM.seal(plain, using: key).combined else { throw PrivateIndexError.unavailable }
            let file = try fileURL(document.scope)
            let temporary = directory.appendingPathComponent(".pending-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try combined.write(to: temporary, options: [.atomic, .completeFileProtection])
            var protectedTemporary = temporary
            try protectedTemporary.setResourceValues(metadata)
            // Never remove the previous file if preparing the replacement fails.
            if FileManager.default.fileExists(atPath: file.path) {
                _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: file)
            }
        }
    }
    func remove(scope: PrivateIndexScope) throws {
        try Self.lock.withLock {
            guard scope.isValid else { throw PrivateIndexError.invalid }
            // Erase key first. A failed keychain deletion is reported, never called success.
            let attributes = try query(scope)
            let status = SecItemDelete(attributes as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw PrivateIndexError.unavailable }
            let file = try fileURL(scope)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
    private func identifier(_ scope: PrivateIndexScope) throws -> String {
        let data = try JSONEncoder().encode([scope.accountID, scope.sourceID])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func fileURL(_ scope: PrivateIndexScope) throws -> URL {
        directory.appendingPathComponent(try identifier(scope)).appendingPathExtension("index")
    }
    private func query(_ scope: PrivateIndexScope) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: try identifier(scope), kSecAttrSynchronizable as String: false]
    }
    private func existingKey(_ scope: PrivateIndexScope) throws -> SymmetricKey? {
        var q = try query(scope)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, data.count == 32 else { throw PrivateIndexError.unavailable }
        return SymmetricKey(data: data)
    }
    private func createKey(_ scope: PrivateIndexScope) throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        var q = try query(scope)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecValueData as String] = bytes
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw PrivateIndexError.unavailable }
        return key
    }
}
#endif
