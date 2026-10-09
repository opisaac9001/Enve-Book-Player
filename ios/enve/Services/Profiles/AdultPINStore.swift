import Foundation
#if !os(tvOS)
import LocalAuthentication
#endif
import Security

@MainActor
final class AdultPINStore {
    static let shared = AdultPINStore()

    private let service: String
    private let account = "adultPIN.v1"

    init(service: String = "com.enve.enve.familyProfiles") {
        self.service = service
    }

    func isConfigured() throws -> Bool { try load() != nil }

    func configure(_ pin: String) throws {
        guard try load() == nil else { throw AdultPINError.secureStorageFailed }
        try save(AdultPINCredential.create(pin: pin))
    }

    func verify(_ pin: String, at date: Date = Date()) throws {
        guard var credential = try load() else { throw AdultPINError.notConfigured }
        do {
            try credential.verify(pin, at: date)
        } catch {
            try save(credential)
            throw error
        }
        try save(credential)
    }

    func change(_ newPIN: String, currentPIN: String) throws {
        let replacement = try AdultPINCredential.create(pin: newPIN)
        try verify(currentPIN)
        try save(replacement)
    }

    func reset(_ newPIN: String) async throws {
        #if os(tvOS)
        throw AdultPINError.deviceAuthenticationFailed
        #else
        let replacement = try AdultPINCredential.create(pin: newPIN)
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            throw AdultPINError.deviceAuthenticationFailed
        }
        do {
            guard try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Reset the adult profile PIN"
            ) else {
                throw AdultPINError.deviceAuthenticationFailed
            }
        } catch {
            throw AdultPINError.deviceAuthenticationFailed
        }
        try save(replacement)
        #endif
    }

    private func load() throws -> AdultPINCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
            let credential = try? JSONDecoder().decode(AdultPINCredential.self, from: data)
        else {
            throw AdultPINError.secureStorageFailed
        }
        return credential
    }

    private func save(_ credential: AdultPINCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw AdultPINError.secureStorageFailed }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
            throw AdultPINError.secureStorageFailed
        }
    }
}
