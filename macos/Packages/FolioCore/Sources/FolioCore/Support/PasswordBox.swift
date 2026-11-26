import CommonCrypto
import CryptoKit
import Foundation

/// Text locked with a password (PBKDF2-HMAC-SHA256 → AES-256-GCM): the API keys of a settings package. The Windows app's
/// is the same.
public struct PasswordBox: Codable, Sendable, Equatable {
    public var salt: Data
    public var rounds: Int
    /// Nonce, ciphertext, tag.
    public var sealed: Data

    public init(_ plain: Data, password: String, rounds: Int = 600_000) throws {
        salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        self.rounds = rounds
        sealed = try AES.GCM.seal(plain, using: Self.key(password, salt, rounds)).combined!
    }

    /// What is in it; nil: the password is wrong.
    public func open(password: String) -> Data? {
        // Whoever made the file says how many rounds: not so many that it never ends.
        guard (1...10_000_000).contains(rounds), let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: Self.key(password, salt, rounds))
    }

    private static func key(_ password: String, _ salt: Data, _ rounds: Int) -> SymmetricKey {
        let password = Array(password.precomposedStringWithCanonicalMapping.utf8).map { CChar(bitPattern: $0) }, salt = [UInt8](salt)
        var key = [UInt8](repeating: 0, count: 32)
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.count, salt, salt.count,
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &key, key.count)
        return SymmetricKey(data: key)
    }
}
