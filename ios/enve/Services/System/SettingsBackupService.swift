import Foundation

nonisolated struct SettingsBackupDocument: Codable {
    var version: Int
    var exportedAt: Date
    var preferences: UserPreferences
    var perBookSpeeds: [String: Double]
}

nonisolated enum SettingsBackupError: LocalizedError {
    case unreadable
    case unsupportedVersion(Int)
    case cannotUnlock
    case invalidPassphrase
    case invalidSource
    case emptyBackup
    case sourcesUnavailable

    var errorDescription: String? {
        switch self {
        case .unreadable: return "That file isn't an Enve settings backup."
        case .unsupportedVersion(let version): return "This backup uses an unsupported format (version \(version))."
        case .cannotUnlock: return "The passphrase is incorrect or the backup is damaged."
        case .invalidPassphrase: return "Use a passphrase of at least 12 characters and at most 1,024 UTF-8 bytes."
        case .invalidSource: return "The backup contains an invalid library source."
        case .emptyBackup: return "Choose settings or add a library source to back up."
        case .sourcesUnavailable: return "Enve couldn't save the imported sources. Your existing sources are still available."
        }
    }
}

@MainActor
final class SettingsBackupService {
    enum ImportFile {
        case settings(SettingsBackupDocument)
        case encrypted(EncryptedSettingsBackup)
    }

    struct RestoreResult {
        let settingsRestored: Bool
        let restoredSources: Int
        let skippedSources: Int
        let signInsNeeded: Int
        let sourcesToRefresh: [UUID]
        let restoredIntegrations: Int
        let keptIntegrations: Int
        let integrationsToReconnect: [String]
    }

    static let shared = SettingsBackupService()
    private static let formatVersion = 1
    private static let maximumFileSize = 16 * 1024 * 1024

    private init() {}

    private func settings() -> SettingsBackupDocument {
        var preferences = LibraryDisplayPreferencesStore.shared.loadPreferences()
        preferences.deviceIdentifier = ""
        preferences.obsidianVaultBookmarkData = nil
        preferences.obsidianLastSyncDates = [:]
        return SettingsBackupDocument(
            version: Self.formatVersion,
            exportedAt: Date(),
            preferences: preferences,
            perBookSpeeds: PlaybackSpeedMemory.shared.allSpeeds()
        )
    }

    func exportBackup() throws -> URL {
        try write(encoder().encode(settings()), named: "Enve Settings.json")
    }

    func exportPortableBackup(
        session: ProfileSession, includeSettings: Bool, includeSources: Bool, includeIntegrations: Bool,
        includeSignIns: Bool, passphrase: String
    ) async throws -> URL {
        let encrypted = try await encryptedBackup(
            session: session, includeSettings: includeSettings, includeSources: includeSources,
            includeIntegrations: includeIntegrations, includeSignIns: includeSignIns, passphrase: passphrase
        )
        return try write(encrypted, named: "Enve Backup.json")
    }

    func encryptedBackup(
        session: ProfileSession, includeSettings: Bool, includeSources: Bool, includeIntegrations: Bool,
        includeSignIns: Bool, passphrase: String
    ) async throws -> Data {
        guard session.isOwner, !session.isRetired else { throw SettingsBackupError.sourcesUnavailable }
        guard passphrase.count >= 12, passphrase.utf8.count <= 1024 else {
            throw SettingsBackupError.invalidPassphrase
        }
        let nativeSettings = includeSettings ? settings() : nil
        let backup = PortableSettingsBackup(
            settings: nativeSettings,
            sources: includeSources ? session.providerConnections.connections.compactMap {
                PortableSettingsBackup.Source($0, includeSignIns: includeSignIns)
            } : [],
            integrations: includeIntegrations ? integrationBackup(session: session, includeSignIns: includeSignIns) : nil,
            sharedSettings: nativeSettings.map { PortableSettingsBackup.SharedSettings($0.preferences) }
        )
        guard backup.settings != nil || !backup.sources.isEmpty || backup.integrations != nil else {
            throw SettingsBackupError.emptyBackup
        }
        let payload = try encoder().encode(backup)
        let encrypted = try await Task.detached(priority: .userInitiated) {
            try EncryptedSettingsBackup.seal(payload, passphrase: passphrase)
        }.value
        try Task.checkCancellation()
        let data = try encoder().encode(encrypted)
        guard data.count <= Self.maximumFileSize else { throw SettingsBackupError.unreadable }
        return data
    }

    func readBackup(from url: URL) throws -> ImportFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard data.count + chunk.count <= Self.maximumFileSize else { throw SettingsBackupError.unreadable }
            data.append(chunk)
        }
        if let encrypted = try? decoder().decode(EncryptedSettingsBackup.self, from: data),
            encrypted.format == EncryptedSettingsBackup.format
        {
            return .encrypted(encrypted)
        }
        guard let settings = try? decoder().decode(SettingsBackupDocument.self, from: data) else {
            throw SettingsBackupError.unreadable
        }
        try validate(settings)
        return .settings(settings)
    }

    func unlock(_ encrypted: EncryptedSettingsBackup, passphrase: String) async throws -> PortableSettingsBackup {
        let data = try await Task.detached(priority: .userInitiated) {
            try encrypted.open(passphrase: passphrase)
        }.value
        try Task.checkCancellation()
        guard let backup = try? decoder().decode(PortableSettingsBackup.self, from: data) else {
            throw SettingsBackupError.unreadable
        }
        guard Set(backup.sources.map(\.id)).count == backup.sources.count else { throw SettingsBackupError.unreadable }
        if let settings = backup.settings { try validate(settings) }
        return backup
    }

    func restore(
        _ backup: PortableSettingsBackup, includeSettings: Bool, sourceIDs: Set<UUID>,
        integrations: Set<PortableSettingsBackup.Integrations.Kind>, session: ProfileSession
    ) throws -> RestoreResult {
        guard session.isOwner, !session.isRetired else { throw SettingsBackupError.sourcesUnavailable }
        var settings = includeSettings ? backup.settings : nil
        if includeSettings, settings == nil, let shared = backup.sharedSettings {
            var local = self.settings()
            shared.apply(to: &local.preferences)
            settings = local
        }
        if let settings { try validate(settings) }
        let store = session.providerConnections
        let selected = backup.sources.filter { sourceIDs.contains($0.id) }
        var existing = [PortableSettingsBackup.SourceIdentity: UUID]()
        for connection in store.connections {
            existing[.init(connection)] = connection.id
        }
        var restored: [ServerConnection] = []
        var mappedIDs: [UUID: UUID] = [:]
        var needsSignIn: Set<UUID> = []
        for source in selected where mappedIDs[source.id] == nil {
            let connection = try source.connection(id: UUID())
            let identity = PortableSettingsBackup.SourceIdentity(connection)
            if let duplicate = existing[identity] {
                mappedIDs[source.id] = duplicate
                continue
            }
            existing[identity] = connection.id
            mappedIDs[source.id] = connection.id
            restored.append(connection)
            if source.needsSignIn && !connection.isArchived {
                needsSignIn.insert(connection.id)
            }
        }
        if !restored.isEmpty {
            try store.addRestoredSources(restored, needsSignIn: needsSignIn)
        }
        if let settings {
            restoreSettings(settings, mappedIDs: mappedIDs)
        }
        let integrationResult = restoreIntegrations(backup.integrations, selected: integrations, session: session)
        return RestoreResult(
            settingsRestored: settings != nil, restoredSources: restored.count,
            skippedSources: selected.count - restored.count, signInsNeeded: needsSignIn.count,
            sourcesToRefresh: restored.filter { !$0.isArchived && !needsSignIn.contains($0.id) }.map(\.id),
            restoredIntegrations: integrationResult.restored, keptIntegrations: integrationResult.kept,
            integrationsToReconnect: integrationResult.reconnect
        )
    }

    private func integrationBackup(session: ProfileSession, includeSignIns: Bool) -> PortableSettingsBackup.Integrations? {
        let hardcoverKey = SettingsManager.shared.hardcoverApiKey
        let readwiseKey = session.readwise.backupToken
        var koreader = KOReaderSyncService.shared.config
        koreader.serverURL = koreader.baseURL.flatMap { PortableSettingsBackup.Source.portableAddress($0.absoluteString) } ?? ""
        if !includeSignIns {
            koreader.passwordHash = ""
        }
        let backup = PortableSettingsBackup.Integrations(
            hasHardcover: hardcoverKey?.isEmpty == false, hardcoverKey: includeSignIns ? hardcoverKey : nil,
            hasReadwise: readwiseKey?.isEmpty == false, readwiseKey: includeSignIns ? readwiseKey : nil,
            koreader: koreader.serverURL.isEmpty ? nil : koreader
        )
        return backup.available.isEmpty ? nil : backup
    }

    private func restoreIntegrations(
        _ backup: PortableSettingsBackup.Integrations?, selected: Set<PortableSettingsBackup.Integrations.Kind>,
        session: ProfileSession
    ) -> (restored: Int, kept: Int, reconnect: [String]) {
        guard let backup else { return (0, 0, []) }
        var restored = 0
        var kept = 0
        var reconnect: [String] = []
        for kind in backup.available where selected.contains(kind) {
            switch kind {
            case .hardcover:
                if SettingsManager.shared.hardcoverApiKey?.isEmpty == false {
                    kept += 1
                } else if let key = backup.hardcoverKey, !key.isEmpty, !key.contains(where: \.isNewline) {
                    SettingsManager.shared.hardcoverApiKey = key
                    if SettingsManager.shared.hardcoverApiKey == key {
                        HardcoverSyncService.shared.clearSyncTracking()
                        restored += 1
                    } else {
                        reconnect.append(kind.name)
                    }
                } else {
                    reconnect.append(kind.name)
                }
            case .readwise:
                if session.readwise.backupToken?.isEmpty == false {
                    kept += 1
                } else if let key = backup.readwiseKey, session.readwise.restoreBackupToken(key) {
                    restored += 1
                } else {
                    reconnect.append(kind.name)
                }
            case .koreader:
                let service = KOReaderSyncService.shared
                if !service.config.serverURL.isEmpty {
                    kept += 1
                } else if var config = backup.koreader, let url = config.baseURL,
                    let endpoint = PortableSettingsBackup.Source.portableAddress(url.absoluteString)
                {
                    config.serverURL = endpoint
                    if config.passwordHash.count != 32 || !config.passwordHash.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
                        config.passwordHash = ""
                    }
                    service.restoreBackupConfig(config)
                    restored += 1
                    if !config.isConfigured { reconnect.append(kind.name) }
                } else {
                    reconnect.append(kind.name)
                }
            }
        }
        return (restored, kept, reconnect)
    }

    private func restoreSettings(_ document: SettingsBackupDocument, mappedIDs: [UUID: UUID]) {
        var preferences = document.preferences
        let current = LibraryDisplayPreferencesStore.shared.loadPreferences()
        preferences.deviceIdentifier = current.deviceIdentifier
        preferences.obsidianVaultBookmarkData = current.obsidianVaultBookmarkData
        preferences.obsidianLastSyncDates = current.obsidianLastSyncDates
        if current.obsidianVaultBookmarkData == nil {
            preferences.obsidianSyncEnabled = false
            preferences.obsidianAutoExportEnabled = false
        }
        if let defaultBackend = preferences.defaultBackendId, let id = UUID(uuidString: defaultBackend),
            let destination = mappedIDs[id]
        {
            preferences.defaultBackendId = destination.uuidString
        }
        for key in preferences.podcastAutoQueueSettings.keys {
            preferences.podcastAutoQueueSettings[key]?.baselinePublishedAt = nil
        }
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
        Theme.currentPreferences = preferences
        var speeds: [String: Double] = [:]
        for (key, speed) in document.perBookSpeeds {
            var parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if parts.count == 3, let sourceID = UUID(uuidString: parts[1]), let newID = mappedIDs[sourceID] {
                parts[1] = newID.uuidString
            }
            speeds[parts.joined(separator: ":")] = speed
        }
        PlaybackSpeedMemory.shared.restore(speeds)
    }

    private func validate(_ settings: SettingsBackupDocument) throws {
        guard settings.version == Self.formatVersion else {
            throw SettingsBackupError.unsupportedVersion(settings.version)
        }
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        guard data.count <= Self.maximumFileSize else { throw SettingsBackupError.unreadable }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
