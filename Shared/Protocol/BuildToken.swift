import Foundation
import CryptoKit

enum BuildToken {
    private static let secret = "voice-polish-keyboard-bridge-2026"

    static func generate() -> String {
        SHA256.hash(data: Data((secret + AppConstants.buildTokenSalt).utf8))
            .compactMap { String(format: "%02x", $0) }.joined()
    }

    static func validate(_ token: String) -> Bool {
        let expected = generate()
        guard token.count == expected.count else { return false }
        var diff: UInt8 = 0
        let a = Array(token.utf8)
        let b = Array(expected.utf8)
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
