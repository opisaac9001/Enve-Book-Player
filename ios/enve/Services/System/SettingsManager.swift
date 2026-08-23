import Foundation
import SwiftUI

extension Notification.Name {
    static let ebookReaderPresented = Notification.Name("ebookReaderPresented")
    static let ebookReaderDismissed = Notification.Name("ebookReaderDismissed")
}

public final class SettingsManager: @unchecked Sendable {
    public static let shared = SettingsManager()

    private let userDefaults = UserDefaults.standard

    private let autoMatchThresholdKey = "autoMatchThreshold"
    private let audibleCountryCodeKey = "audibleCountryCode"
    private let googleBooksApiKeyKey = "googleBooksApiKey"
    private let hardcoverApiKeyKey = "hardcoverApiKey"
    private let hardcoverIntroCardDismissedKey = "hardcoverIntroCardDismissed"
    private let allowCellularBookDownloadsKey = "allowCellularBookDownloads"
    private let allowCellularMetadataDownloadsKey = "allowCellularMetadataDownloads"
    private let hardcoverBookMatchesKey = "hardcoverBookMatches"
    private let comicVineApiKeyKey = "comicVineApiKey"
    private let metadataMatchProviderKey = "metadataMatchProvider"

    private let defaultAutoMatchThreshold: Double = 0.85
    private let defaultAudibleCountryCode: String = "us"
    private let defaultAllowCellularBookDownloads: Bool = false
    private let defaultAllowCellularMetadataDownloads: Bool = false
    private let defaultMetadataMatchProvider: MetadataProvider = MetadataProvider.getDefaultProvider()

    private init() {
        migrateAPIKeysToKeychainIfNeeded()
    }

    private func migrateAPIKeysToKeychainIfNeeded() {
        let migrationKey = "SettingsManager.apiKeysKeychainMigration.v1"
        guard !userDefaults.bool(forKey: migrationKey) else { return }

        for key in [googleBooksApiKeyKey, comicVineApiKeyKey] {
            if let oldValue = userDefaults.string(forKey: key), !oldValue.isEmpty {
                KeychainHelper.shared.set(oldValue, key: key)
                userDefaults.removeObject(forKey: key)
            }
        }
        userDefaults.set(true, forKey: migrationKey)
    }

    public var autoMatchThreshold: Double {
        get {
            guard userDefaults.object(forKey: autoMatchThresholdKey) != nil else {
                return defaultAutoMatchThreshold
            }
            let value = userDefaults.double(forKey: autoMatchThresholdKey)
            return max(0.0, min(1.0, value))
        }
        set {
            let clamped = max(0.0, min(1.0, newValue))
            userDefaults.set(clamped, forKey: autoMatchThresholdKey)
        }
    }

    public var autoMatchThresholdPercent: Int {
        get {
            return Int(autoMatchThreshold * 100)
        }
        set {
            autoMatchThreshold = Double(newValue) / 100.0
        }
    }

    public var audibleCountryCode: String {
        get {
            (userDefaults.string(forKey: audibleCountryCodeKey) ?? defaultAudibleCountryCode)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            userDefaults.set(value.isEmpty ? defaultAudibleCountryCode : value, forKey: audibleCountryCodeKey)
        }
    }

    public var googleBooksApiKey: String? {
        get { KeychainHelper.shared.get(googleBooksApiKeyKey) }
        set {
            let cleaned = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleaned, !cleaned.isEmpty {
                KeychainHelper.shared.set(cleaned, key: googleBooksApiKeyKey)
            } else {
                KeychainHelper.shared.delete(googleBooksApiKeyKey)
            }
        }
    }

    public var hardcoverApiKey: String? {
        get { KeychainHelper.shared.get(hardcoverApiKeyKey) }
        set {
            var cleaned = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let c = cleaned, c.lowercased().hasPrefix("bearer ") {
                cleaned = String(c.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let cleaned, !cleaned.isEmpty {
                KeychainHelper.shared.set(cleaned, key: hardcoverApiKeyKey)
            } else {
                KeychainHelper.shared.delete(hardcoverApiKeyKey)
            }
        }
    }

    public func clearHardcoverAccess(reason: String? = nil) {

        KeychainHelper.shared.delete(hardcoverApiKeyKey)
        userDefaults.removeObject(forKey: hardcoverBookMatchesKey)
        userDefaults.set(false, forKey: hardcoverAutoSyncKey)
        Task {
            await HardcoverSyncService.shared.clearSyncTracking()
        }
    }

    public var hardcoverIntroCardDismissed: Bool {
        get { userDefaults.bool(forKey: hardcoverIntroCardDismissedKey) }
        set { userDefaults.set(newValue, forKey: hardcoverIntroCardDismissedKey) }
    }

    private let hardcoverAutoSyncKey = "hardcoverAutoSync"

    public var hardcoverAutoSyncEnabled: Bool {
        get { userDefaults.object(forKey: hardcoverAutoSyncKey) as? Bool ?? true }
        set { userDefaults.set(newValue, forKey: hardcoverAutoSyncKey) }
    }

    public var allowCellularBookDownloads: Bool {
        get {
            guard userDefaults.object(forKey: allowCellularBookDownloadsKey) != nil else {
                return defaultAllowCellularBookDownloads
            }
            return userDefaults.bool(forKey: allowCellularBookDownloadsKey)
        }
        set {
            userDefaults.set(newValue, forKey: allowCellularBookDownloadsKey)
        }
    }

    public var allowCellularMetadataDownloads: Bool {
        get {
            guard userDefaults.object(forKey: allowCellularMetadataDownloadsKey) != nil else {
                return defaultAllowCellularMetadataDownloads
            }
            return userDefaults.bool(forKey: allowCellularMetadataDownloadsKey)
        }
        set {
            userDefaults.set(newValue, forKey: allowCellularMetadataDownloadsKey)
        }
    }

    public var comicVineApiKey: String? {
        get { KeychainHelper.shared.get(comicVineApiKeyKey) }
        set {
            let cleaned = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleaned, !cleaned.isEmpty {
                KeychainHelper.shared.set(cleaned, key: comicVineApiKeyKey)
            } else {
                KeychainHelper.shared.delete(comicVineApiKeyKey)
            }
        }
    }

    public var metadataMatchProvider: MetadataProvider {
        get {
            guard let rawValue = userDefaults.string(forKey: metadataMatchProviderKey),
                let provider = MetadataProvider(rawValue: rawValue)
            else {
                return defaultMetadataMatchProvider
            }
            return provider
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: metadataMatchProviderKey)
        }
    }

    public var mergeAggressiveness: UserPreferences.MergeAggressiveness {
        get {
            guard let rawValue = userDefaults.string(forKey: "mergeAggressiveness"),
                let aggressiveness = UserPreferences.MergeAggressiveness(rawValue: rawValue)
            else {
                return .normal
            }
            return aggressiveness
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: "mergeAggressiveness")
        }
    }

    public func saveHardcoverMatches(_ storage: HardcoverMatchStorage) {
        if let encoded = try? JSONEncoder().encode(storage) {
            userDefaults.set(encoded, forKey: hardcoverBookMatchesKey)
        }
    }

    public func loadHardcoverMatches() -> HardcoverMatchStorage {
        guard let data = userDefaults.data(forKey: hardcoverBookMatchesKey),
            let storage = try? JSONDecoder().decode(HardcoverMatchStorage.self, from: data)
        else {
            return HardcoverMatchStorage()
        }
        return storage
    }

    public func addHardcoverMatch(_ match: HardcoverBookMatch) {
        var storage = loadHardcoverMatches()

        storage.matches.removeAll { $0.localBookId == match.localBookId }

        storage.matches.append(match)
        saveHardcoverMatches(storage)
    }

    public func removeHardcoverMatch(forLocalBookId bookId: String) {
        var storage = loadHardcoverMatches()
        storage.matches.removeAll { $0.localBookId == bookId }
        saveHardcoverMatches(storage)
    }

    public func getHardcoverMatch(forLocalBookId bookId: String) -> HardcoverBookMatch? {
        let storage = loadHardcoverMatches()
        return storage.matches.first { $0.localBookId == bookId }
    }

    public func getHardcoverMatch(forHardcoverBookId hardcoverBookId: Int) -> HardcoverBookMatch? {
        let storage = loadHardcoverMatches()
        return storage.matches.first { $0.hardcoverBookId == hardcoverBookId }
    }

    public func getAllHardcoverMatches() -> [HardcoverBookMatch] {
        return loadHardcoverMatches().matches
    }

}
