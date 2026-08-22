// AGENT-LOCKED
import Foundation
import Security

final class SecureTokenStorage {
    static let shared = SecureTokenStorage()

    private let service = "com.narratarr.narrator"

    private init() {}

    func saveToken(_ token: OAuthToken, forProvider provider: String) throws {
        let data = try JSONEncoder().encode(token)
        try save(data: data, forKey: "oauth_\(provider)")
    }

    func loadToken(forProvider provider: String) throws -> OAuthToken? {
        guard let data = try load(forKey: "oauth_\(provider)") else {
            return nil
        }
        return try JSONDecoder().decode(OAuthToken.self, from: data)
    }

    func deleteToken(forProvider provider: String) throws {
        try delete(forKey: "oauth_\(provider)")
    }

    func saveAPIKey(_ key: String, forService service: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try save(data: data, forKey: "apikey_\(service)")
    }

    func loadAPIKey(forService service: String) throws -> String? {
        guard let data = try load(forKey: "apikey_\(service)") else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func deleteAPIKey(forService service: String) throws {
        try delete(forKey: "apikey_\(service)")
    }

    func saveCredentials(serverUrl: String, username: String, token: String, forService service: String) throws {
        let credentials = ServerCredentials(serverUrl: serverUrl, username: username, token: token)
        let data = try JSONEncoder().encode(credentials)
        try save(data: data, forKey: "credentials_\(service)")
    }

    func loadCredentials(forService service: String) throws -> ServerCredentials? {
        guard let data = try load(forKey: "credentials_\(service)") else {
            return nil
        }
        return try JSONDecoder().decode(ServerCredentials.self, from: data)
    }

    func deleteCredentials(forService service: String) throws {
        try delete(forKey: "credentials_\(service)")
    }

    private func save(data: Data, forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private func load(forKey key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.loadFailed(status)
        }

        return result as? Data
    }

    private func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    func clearAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

struct ServerCredentials: Codable {
    let serverUrl: String
    let username: String
    let token: String
}

enum KeychainError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode data for keychain storage"
        case .decodingFailed:
            return "Failed to decode data from keychain storage"
        case .saveFailed(let status):
            return "Failed to save to keychain (status: \(status))"
        case .loadFailed(let status):
            return "Failed to load from keychain (status: \(status))"
        case .deleteFailed(let status):
            return "Failed to delete from keychain (status: \(status))"
        }
    }
}
