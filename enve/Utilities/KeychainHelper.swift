// AGENT-LOCKED
import Foundation
import Logging
import Security

final class KeychainHelper: Sendable {
    static let shared = KeychainHelper()
    private let service = "com.narratarr.app"

    private init() {}

    func set(_ data: Data, key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        SecItemDelete(query as CFDictionary)

        SecItemAdd(query as CFDictionary, nil)
    }

    func set(_ string: String, key: String) {
        if let data = string.data(using: .utf8) {
            set(data, key: key)
        }
    }

    func set(_ bool: Bool, key: String) {
        let string = bool ? "true" : "false"
        set(string, key: key)
    }

    func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var dataTypeRef: AnyObject?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    func getData(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var dataTypeRef: AnyObject?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return data
        }
        return nil
    }

    func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)
    }

    func clearAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            AppLogger.general.info("KeychainHelper: All items cleared for service \(service)")
        } else {
            AppLogger.general.info("KeychainHelper: clearAll returned status \(status)")
        }
    }

    func remove(_ key: String) throws {
        delete(key)
    }

    subscript(key: String) -> String? {
        get { get(key) }
        set {
            if let newValue = newValue {
                set(newValue, key: key)
            } else {
                delete(key)
            }
        }
    }
}
