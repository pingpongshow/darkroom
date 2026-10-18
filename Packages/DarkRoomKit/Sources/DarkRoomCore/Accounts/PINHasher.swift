import Foundation
import CommonCrypto
import Security

/// Salted PBKDF2-HMAC-SHA256 hashing for DarkRoom PINs. PINs never leave the Mac and are never
/// stored in plain text.
public struct PINHash: Codable, Equatable, Sendable {
    public var salt: Data
    public var hash: Data
    public var iterations: UInt32
}

public enum PINHasher {
    public static let defaultIterations: UInt32 = 310_000
    public static let validLengths = 4...6

    public static func isValidFormat(_ pin: String) -> Bool {
        validLengths.contains(pin.count) && pin.allSatisfy(\.isASCII) && pin.allSatisfy(\.isNumber)
    }

    public static func make(_ pin: String, iterations: UInt32 = defaultIterations) -> PINHash {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return PINHash(salt: salt, hash: derive(pin, salt: salt, iterations: iterations), iterations: iterations)
    }

    public static func verify(_ pin: String, against stored: PINHash) -> Bool {
        let candidate = derive(pin, salt: stored.salt, iterations: stored.iterations)
        guard candidate.count == stored.hash.count else { return false }
        // Constant-time comparison
        var diff: UInt8 = 0
        for (a, b) in zip(candidate, stored.hash) { diff |= a ^ b }
        return diff == 0
    }

    static func derive(_ pin: String, salt: Data, iterations: UInt32) -> Data {
        var out = Data(count: 32)
        let password = Array(pin.utf8)
        let status = out.withUnsafeMutableBytes { outBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     password.map { Int8(bitPattern: $0) }, password.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     outBytes.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return out
    }
}
