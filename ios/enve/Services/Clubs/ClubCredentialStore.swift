#if os(iOS)
import Foundation
import Security

struct ClubCredentialStore {
    let profileID: String
    let service: URL

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Enve.BookClubs",
         kSecAttrAccount as String: "\(profileID)|\(service.absoluteString)"]
    }

    func load() throws -> ClubCredentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw URLError(.cannotDecodeContentData) }
        return try JSONDecoder().decode(ClubCredentials.self, from: data)
    }

    func save(_ credentials: ClubCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes = [kSecValueData as String: data] as CFDictionary
        let result = SecItemUpdate(query as CFDictionary, attributes)
        if result == errSecItemNotFound {
            var new = query
            new[kSecValueData as String] = data
            new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(new as CFDictionary, nil))
        } else {
            try check(result)
        }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw ClubsResponseError(status: 0, message: "Enve couldn’t access your Clubs sign-in on this device.")
        }
    }
}
#endif
