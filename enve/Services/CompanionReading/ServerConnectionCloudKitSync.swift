import CloudKit
import Combine
import Foundation
import Logging
import Observation

@MainActor
@Observable
final class ServerConnectionCloudKitSync {
    static let shared = ServerConnectionCloudKitSync()

    enum SyncStatus: Equatable {
        case idle
        case syncing
        case lastSyncedAt(Date)
        case error(String)
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue {
                Task { await pushAll() }
            }
        }
    }

    private(set) var status: SyncStatus = .idle

    private let container = CKContainer(identifier: "iCloud.com.enve.enve")
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: "ServerConnections", ownerName: CKCurrentUserDefaultName)
    private let recordType = "ServerConnection"
    private let subscriptionID = "server-connections-changes"
    private let enabledKey = "ServerConnectionCloudKitSync.enabled"

    private var zoneEnsured = false

    private init() {}

    func bootstrap() async {
        guard isEnabled else { return }
        await ensureZone()
        await subscribeIfNeeded()
        await pullAll()
    }

    func pushChange(_ connection: ServerConnection) async {
        guard isEnabled else { return }
        await ensureZone()
        do {
            let record = makeRecord(for: connection)
            _ = try await database.save(record)
            status = .lastSyncedAt(Date())
        } catch {
            AppLogger.sync.warning("[CKSync] Failed to push \(connection.id): \(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
    }

    func deleteConnection(id: UUID) async {
        guard isEnabled else { return }
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        do {
            try await database.deleteRecord(withID: recordID)
        } catch let error as CKError where error.code == .unknownItem {

        } catch {
            AppLogger.sync.warning("[CKSync] Failed to delete \(id): \(error.localizedDescription)")
        }
    }

    func pushAll() async {
        guard isEnabled else { return }
        await ensureZone()
        status = .syncing
        let connections = AppState.shared.providerConnections.connections
        for connection in connections {
            await pushChange(connection)
        }
        status = .lastSyncedAt(Date())
    }

    func pullAll() async {
        guard isEnabled else { return }
        status = .syncing
        do {
            let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
            var fetched: [ServerConnection] = []
            let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
            for (_, result) in results {
                switch result {
                case .success(let record):
                    if let connection = makeConnection(from: record) {
                        fetched.append(connection)
                    }
                case .failure(let error):
                    AppLogger.sync.warning("[CKSync] Record fetch failed: \(error.localizedDescription)")
                }
            }
            mergeIntoAppState(fetched)
            status = .lastSyncedAt(Date())
        } catch {
            AppLogger.sync.warning("[CKSync] pullAll failed: \(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
    }

    private func ensureZone() async {
        guard !zoneEnsured else { return }
        do {
            let zone = CKRecordZone(zoneID: zoneID)
            _ = try await database.save(zone)
            zoneEnsured = true
        } catch let error as CKError where error.code == .serverRecordChanged || error.code == .zoneNotFound {

            zoneEnsured = true
        } catch {
            AppLogger.sync.warning("[CKSync] ensureZone failed: \(error.localizedDescription)")
        }
    }

    private func subscribeIfNeeded() async {
        do {

            let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.shouldSendContentAvailable = true
            subscription.notificationInfo = notificationInfo
            _ = try await database.save(subscription)
        } catch let error as CKError where error.code == .serverRejectedRequest {

        } catch {
            AppLogger.sync.warning("[CKSync] subscribe failed: \(error.localizedDescription)")
        }
    }

    private func makeRecord(for connection: ServerConnection) -> CKRecord {
        connection.persistSecretsToSharedKeychain()

        let recordID = CKRecord.ID(recordName: connection.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["name"] = connection.name as CKRecordValue
        record["url"] = connection.url as CKRecordValue
        record["type"] = connection.type.rawValue as CKRecordValue
        if let username = connection.username { record["username"] = username as CKRecordValue }
        if let userId = connection.userId { record["userId"] = userId as CKRecordValue }
        if let rootPath = connection.rootPath { record["rootPath"] = rootPath as CKRecordValue }
        if let selectedLibraryIds = connection.selectedLibraryIds {
            record["selectedLibraryIds"] = Array(selectedLibraryIds) as CKRecordValue
        }
        let publicCustomHeaders = connection.publicCustomHeadersForPersistence() ?? [:]
        if let data = try? JSONEncoder().encode(publicCustomHeaders) {
            record["customHeadersJSON"] = data as CKRecordValue
        }
        let secretHeaderNames = connection.allSecretCustomHeaderNames().sorted()
        if let data = try? JSONEncoder().encode(secretHeaderNames) {
            record["secretCustomHeaderNamesJSON"] = data as CKRecordValue
        }
        record["authMode"] = connection.authMode.rawValue as CKRecordValue
        if let komgaOAuthProviderId = connection.komgaOAuthProviderId {
            record["komgaOAuthProviderId"] = komgaOAuthProviderId as CKRecordValue
        }
        record["mtlsEnabled"] = (connection.mtlsEnabled ? 1 : 0) as CKRecordValue
        record["isArchived"] = (connection.isArchived ? 1 : 0) as CKRecordValue
        return record
    }

    private func makeConnection(from record: CKRecord) -> ServerConnection? {
        guard let uuid = UUID(uuidString: record.recordID.recordName),
            let name = record["name"] as? String,
            let url = record["url"] as? String,
            let typeRaw = record["type"] as? String,
            let type = ProviderType(rawValue: typeRaw)
        else { return nil }

        var connection = ServerConnection(
            id: uuid,
            name: name,
            url: url,
            type: type
        )
        connection.username = record["username"] as? String
        connection.userId = record["userId"] as? String
        connection.rootPath = record["rootPath"] as? String
        if let libraryIds = record["selectedLibraryIds"] as? [String] {
            connection.selectedLibraryIds = Set(libraryIds)
        }
        if let data = record["customHeadersJSON"] as? Data,
            let headers = try? JSONDecoder().decode([String: String].self, from: data)
        {
            connection.customHeaders = headers.isEmpty ? nil : headers
        }
        if let data = record["secretCustomHeaderNamesJSON"] as? Data,
            let headerNames = try? JSONDecoder().decode([String].self, from: data)
        {
            connection.secretCustomHeaderNames = Set(headerNames)
        } else if let headerNames = record["secretCustomHeaderNames"] as? [String] {
            connection.secretCustomHeaderNames = Set(headerNames)
        }
        if let modeRaw = record["authMode"] as? String,
            let mode = ConnectionAuthMode(rawValue: modeRaw)
        {
            connection.authMode = mode
        }
        connection.komgaOAuthProviderId = record["komgaOAuthProviderId"] as? String
        if let mtls = record["mtlsEnabled"] as? Int {
            connection.mtlsEnabled = (mtls != 0)
        }
        if let archived = record["isArchived"] as? Int {
            connection.isArchived = (archived != 0)
        }

        connection.hydrateSecretsFromSharedKeychain()

        return connection
    }

    private func mergeIntoAppState(_ fetched: [ServerConnection]) {
        let existing = AppState.shared.providerConnections.connections
        let existingById = Dictionary(grouping: existing, by: \.id).compactMapValues { $0.first }

        var merged: [ServerConnection] = []
        for remote in fetched {
            if let local = existingById[remote.id] {

                merged.append(mergeSecrets(from: local, into: remote))
            } else {
                merged.append(remote)
            }
        }

        let mergedIDs = Set(merged.map { $0.id })
        for local in existing where !mergedIDs.contains(local.id) {
            merged.append(local)
        }
        AppState.shared.providerConnections.connections = merged
    }

    private func mergeSecrets(from local: ServerConnection, into remote: ServerConnection) -> ServerConnection {
        var combined = remote
        if combined.token == nil { combined.token = local.token }
        if combined.password == nil { combined.password = local.password }
        if combined.plexHomeUserToken == nil { combined.plexHomeUserToken = local.plexHomeUserToken }
        if combined.plexOwnerToken == nil { combined.plexOwnerToken = local.plexOwnerToken }

        let secretHeaderNames = combined.allSecretCustomHeaderNames().union(local.allSecretCustomHeaderNames())
        combined.secretCustomHeaderNames = secretHeaderNames
        var headers = combined.customHeaders ?? [:]

        for headerName in secretHeaderNames where ServerConnection.headerValue(in: headers, for: headerName) == nil {
            guard let localValue = ServerConnection.headerValue(in: local.customHeaders, for: headerName) else {
                continue
            }
            ServerConnection.setHeaderValue(localValue, for: headerName, in: &headers)
        }

        combined.customHeaders = headers.isEmpty ? nil : headers
        combined.persistSecretsToSharedKeychain()
        return combined
    }
}
