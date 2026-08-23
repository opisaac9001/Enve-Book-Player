// AGENT-LOCKED
import Foundation
import Logging
import Security

final class SharedKeychainStore: Sendable {
    static let shared = SharedKeychainStore()

    private let service = "com.enve.enve.connections"
    private let accessGroup = "group.com.enve.enve"

    private init() {}

    @discardableResult
    func setToken(_ token: String, forConnectionId connectionId: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        return setData(data, key: tokenKey(for: connectionId))
    }

    func token(forConnectionId connectionId: String) -> String? {
        guard let data = getData(key: tokenKey(for: connectionId)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func deleteToken(forConnectionId connectionId: String) -> Bool {
        delete(key: tokenKey(for: connectionId))
    }

    @discardableResult
    func setPassword(_ password: String, forConnectionId connectionId: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        return setData(data, key: passwordKey(for: connectionId))
    }

    func password(forConnectionId connectionId: String) -> String? {
        guard let data = getData(key: passwordKey(for: connectionId)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func deletePassword(forConnectionId connectionId: String) -> Bool {
        delete(key: passwordKey(for: connectionId))
    }

    @discardableResult
    func setPlexHomeUserToken(_ token: String, forConnectionId connectionId: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        return setData(data, key: plexHomeUserTokenKey(for: connectionId))
    }

    func plexHomeUserToken(forConnectionId connectionId: String) -> String? {
        guard let data = getData(key: plexHomeUserTokenKey(for: connectionId)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func deletePlexHomeUserToken(forConnectionId connectionId: String) -> Bool {
        delete(key: plexHomeUserTokenKey(for: connectionId))
    }

    @discardableResult
    func setPlexOwnerToken(_ token: String, forConnectionId connectionId: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        return setData(data, key: plexOwnerTokenKey(for: connectionId))
    }

    func plexOwnerToken(forConnectionId connectionId: String) -> String? {
        guard let data = getData(key: plexOwnerTokenKey(for: connectionId)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func deletePlexOwnerToken(forConnectionId connectionId: String) -> Bool {
        delete(key: plexOwnerTokenKey(for: connectionId))
    }

    @discardableResult
    func setCustomHeaderValue(_ value: String, headerName: String, forConnectionId connectionId: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return setData(data, key: customHeaderKey(for: connectionId, headerName: headerName))
    }

    func customHeaderValue(headerName: String, forConnectionId connectionId: String) -> String? {
        guard let data = getData(key: customHeaderKey(for: connectionId, headerName: headerName)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func deleteCustomHeaderValue(headerName: String, forConnectionId connectionId: String) -> Bool {
        delete(key: customHeaderKey(for: connectionId, headerName: headerName))
    }

    func deleteCustomHeaderValues(headerNames: Set<String>, forConnectionId connectionId: String) {
        for headerName in headerNames {
            _ = deleteCustomHeaderValue(headerName: headerName, forConnectionId: connectionId)
        }
    }

    func deleteAll(forConnectionId connectionId: String) {
        _ = deleteToken(forConnectionId: connectionId)
        _ = deletePassword(forConnectionId: connectionId)
        _ = deletePlexHomeUserToken(forConnectionId: connectionId)
        _ = deletePlexOwnerToken(forConnectionId: connectionId)
    }

    private func tokenKey(for id: String) -> String { "token_\(id)" }
    private func passwordKey(for id: String) -> String { "password_\(id)" }
    private func plexHomeUserTokenKey(for id: String) -> String { "plexHomeUserToken_\(id)" }
    private func plexOwnerTokenKey(for id: String) -> String { "plexOwnerToken_\(id)" }

    private func customHeaderKey(for id: String, headerName: String) -> String {
        let normalized = headerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let encoded = Data(normalized.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "customHeader_\(id)_\(encoded)"
    }

    private func baseQuery(key: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func setData(_ data: Data, key: String) -> Bool {
        let status = setData(data, key: key, accessGroup: accessGroup)
        if status == errSecSuccess { return true }

        if status == errSecMissingEntitlement {
            let fallbackStatus = setData(data, key: key, accessGroup: nil)
            if fallbackStatus == errSecSuccess { return true }
            AppLogger.general.warning("[SharedKeychain] Fallback save failed for key=\(key), status=\(fallbackStatus)")
            return false
        }

        AppLogger.general.warning("[SharedKeychain] Save failed for key=\(key), status=\(status)")
        return false
    }

    private func getData(key: String) -> Data? {
        if let data = getData(key: key, accessGroup: accessGroup).data {
            return data
        }
        return getData(key: key, accessGroup: nil).data
    }

    @discardableResult
    private func delete(key: String) -> Bool {
        let primaryStatus = delete(key: key, accessGroup: accessGroup)
        let fallbackStatus = delete(key: key, accessGroup: nil)
        return [primaryStatus, fallbackStatus].contains { $0 == errSecSuccess || $0 == errSecItemNotFound }
    }

    private func setData(_ data: Data, key: String, accessGroup: String?) -> OSStatus {
        var query = baseQuery(key: key, accessGroup: accessGroup)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil)
    }

    private func getData(key: String, accessGroup: String?) -> (data: Data?, status: OSStatus) {
        var query = baseQuery(key: key, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (nil, status) }
        return (result as? Data, status)
    }

    private func delete(key: String, accessGroup: String?) -> OSStatus {
        let query = baseQuery(key: key, accessGroup: accessGroup)
        return SecItemDelete(query as CFDictionary)
    }
}
