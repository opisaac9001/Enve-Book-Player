import CommonCrypto
import Foundation
import Security

struct AdultPINCredential: Codable {
    let salt: Data
    let verifier: Data
    var failedAttempts: Int
    var lockedUntil: Date?

    static func create(pin: String) throws -> AdultPINCredential {
        guard (4...12).contains(pin.utf8.count), pin.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw AdultPINError.invalidFormat
        }
        var salt = Data(count: 32)
        let result = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard result == errSecSuccess else { throw AdultPINError.secureStorageFailed }
        return AdultPINCredential(salt: salt, verifier: derive(pin: pin, salt: salt), failedAttempts: 0, lockedUntil: nil)
    }

    mutating func verify(_ pin: String, at date: Date) throws {
        if let lockedUntil, date < lockedUntil { throw AdultPINError.locked(until: lockedUntil) }
        let candidate = Self.derive(pin: pin, salt: salt)
        let difference = zip(candidate, verifier).reduce(UInt8(candidate.count == verifier.count ? 0 : 1)) {
            $0 | ($1.0 ^ $1.1)
        }
        if difference == 0 {
            failedAttempts = 0
            lockedUntil = nil
            return
        }
        failedAttempts += 1
        if failedAttempts >= 5 {
            let exponent = min(failedAttempts - 5, 6)
            lockedUntil = date.addingTimeInterval(TimeInterval(30 * (1 << exponent)))
        }
        throw AdultPINError.incorrect
    }

    private static func derive(pin: String, salt: Data) -> Data {
        var result = Data(count: 32)
        let password = Array(pin.utf8)
        result.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000,
                    output.bindMemory(to: UInt8.self).baseAddress, output.count
                )
            }
        }
        return result
    }
}

enum AdultPINError: Error, Equatable {
    case invalidFormat
    case incorrect
    case locked(until: Date)
    case notConfigured
    case secureStorageFailed
    case deviceAuthenticationFailed
}
