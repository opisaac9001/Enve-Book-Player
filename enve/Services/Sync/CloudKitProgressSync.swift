import CloudKit
import Combine
import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif

@Observable
final class CloudKitProgressSync {
    static let shared = CloudKitProgressSync()

    @ObservationIgnored private let container: CKContainer
    @ObservationIgnored private let privateDatabase: CKDatabase
    @ObservationIgnored private let recordType = "BookPlaybackState"
    @ObservationIgnored private let customZoneName = "BookProgressZone"
    @ObservationIgnored private let pushSubscriptionID = "BookProgressChanges"

    private(set) var cachedRecords: [String: PlaybackStateRecord] = [:]
    private(set) var lastFetchDate: Date?
    private(set) var isSyncing = false
    private(set) var pushSubscriptionRegistered = false
    @ObservationIgnored private var customZone: CKRecordZone?

    private var cachedAccountAvailable: Bool?
    private var accountStatusCacheDate: Date?
    private let accountStatusCacheTTL: TimeInterval = 120

    private let changeTokenKey = "CloudKitProgressSync.changeToken"
    private var savedChangeToken: CKServerChangeToken? {
        get {
            guard let data = UserDefaults.standard.data(forKey: changeTokenKey) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        set {
            if let token = newValue,
                let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            {
                UserDefaults.standard.set(data, forKey: changeTokenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: changeTokenKey)
            }
        }
    }

    private let cacheValidityDuration: TimeInterval = 300

    private init() {
        self.container = CKContainer(identifier: "iCloud.com.enve.enve")
        self.privateDatabase = container.privateCloudDatabase
    }

    func isAvailable() async -> Bool {
        if let cached = cachedAccountAvailable,
            let cacheDate = accountStatusCacheDate,
            Date().timeIntervalSince(cacheDate) < accountStatusCacheTTL
        {
            return cached
        }

        do {
            AppLogger.sync.info("Checking CloudKit account status...")
            let status = try await container.accountStatus()
            AppLogger.sync.info("Account status: \(status.rawValue)")
            let available = status == .available

            cachedAccountAvailable = available
            accountStatusCacheDate = Date()

            if !available {
                AppLogger.sync.info("CloudKit not available - status: \(statusDescription(status))")
            } else {
                AppLogger.sync.info("CloudKit is available")
                await ensureCustomZoneExists()
            }
            return available
        } catch {
            AppLogger.sync.error("Account status check failed: \(error)")
            return false
        }
    }

    private func ensureCustomZoneExists() async {
        guard customZone == nil else { return }

        do {
            let zoneID = CKRecordZone.ID(zoneName: customZoneName, ownerName: CKCurrentUserDefaultName)

            do {
                let zones = try await privateDatabase.recordZones(for: [zoneID])
                if let zoneResult = zones[zoneID] {
                    switch zoneResult {
                    case .success(let zone):
                        customZone = zone
                        AppLogger.sync.info("Custom zone already exists: \(customZoneName)")
                        return
                    case .failure:
                        break
                    }
                }
            } catch {
                AppLogger.sync.info("Creating custom zone: \(customZoneName)")
            }

            let newZone = CKRecordZone(zoneID: zoneID)
            let savedZones = try await privateDatabase.modifyRecordZones(saving: [newZone], deleting: [])
            if let saveResult = savedZones.saveResults.first?.value {
                switch saveResult {
                case .success(let zone):
                    customZone = zone
                    AppLogger.sync.info("Created custom zone: \(customZoneName)")
                case .failure(let error):
                    AppLogger.sync.error("Failed to save zone: \(error)")
                }
            }

        } catch {
            AppLogger.sync.error("Failed to create custom zone: \(error)")
        }
    }

    private var zoneID: CKRecordZone.ID {
        customZone?.zoneID ?? CKRecordZone.default().zoneID
    }

    private func statusDescription(_ status: CKAccountStatus) -> String {
        switch status {
        case .couldNotDetermine: return "Could not determine"
        case .available: return "Available"
        case .restricted: return "Restricted"
        case .noAccount: return "No account"
        case .temporarilyUnavailable: return "Temporarily unavailable"
        @unknown default: return "Unknown (\(status.rawValue))"
        }
    }

    func saveProgress(
        identity: CanonicalBookIdentity,
        position: TimeInterval,
        playbackRate: Double = 1.0,
        completed: Bool = false,
        lastInteractionDate: Date = Date()
    ) async throws {
        guard await isAvailable() else {
            AppLogger.sync.warning("CloudKit not available, skipping save")
            return
        }

        let deviceID = currentDeviceID
        let deviceName = currentDeviceName

        AppLogger.sync.info("Attempting to save - recordID: \(identity.recordID.prefix(12))...")

        let recordIDInZone = CKRecord.ID(recordName: identity.recordID, zoneID: zoneID)

        var record: CKRecord
        var shouldUpdate = true

        do {
            record = try await privateDatabase.record(for: recordIDInZone)
            AppLogger.sync.info("Found existing record for: \(identity.originalTitle)")

            shouldUpdate = shouldUpdateRecord(
                record,
                localPosition: position,
                lastInteractionDate: lastInteractionDate,
                sourceLabel: "Cloud"
            )
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: recordType, recordID: recordIDInZone)
            AppLogger.sync.info("Creating new record for: \(identity.originalTitle)")
        } catch {
            AppLogger.sync.error("Error fetching record: \(error)")
            throw error
        }

        guard shouldUpdate else {
            AppLogger.sync.warning("Skipping save to prevent overwriting newer progress")
            return
        }

        applyFields(
            to: record,
            identity: identity,
            position: position,
            playbackRate: playbackRate,
            completed: completed,
            lastInteractionDate: lastInteractionDate,
            deviceID: deviceID,
            deviceName: deviceName
        )

        var lastSaveError: Error?
        for attempt in 0..<2 {
            do {
                let savedRecord = try await privateDatabase.save(record)
                AppLogger.sync.info("Saved progress: \(Int(position))s for \(identity.originalTitle)")
                AppLogger.sync.info("Record saved with ID: \(savedRecord.recordID.recordName.prefix(12))...")

                if let playbackRecord = PlaybackStateRecord(from: savedRecord) {
                    DispatchQueue.main.async {
                        self.cachedRecords[identity.recordID] = playbackRecord
                    }
                }

                DispatchQueue.main.async {
                    self.lastFetchDate = nil
                }
                return
            } catch let error as CKError where error.code == .serverRecordChanged && attempt == 0 {
                AppLogger.sync.warning("Server record changed while saving; retrying with latest server version")
                var latestServerRecord = self.latestServerRecord(from: error)
                if latestServerRecord == nil {
                    latestServerRecord = try? await privateDatabase.record(for: recordIDInZone)
                }
                guard let resolvedRecord = latestServerRecord else {
                    lastSaveError = error
                    break
                }

                let shouldRetry = shouldUpdateRecord(
                    resolvedRecord,
                    localPosition: position,
                    lastInteractionDate: lastInteractionDate,
                    sourceLabel: "Cloud (latest)"
                )
                guard shouldRetry else {
                    AppLogger.sync.warning("Skipping retry; server record is newer")
                    return
                }

                record = resolvedRecord
                applyFields(
                    to: record,
                    identity: identity,
                    position: position,
                    playbackRate: playbackRate,
                    completed: completed,
                    lastInteractionDate: lastInteractionDate,
                    deviceID: deviceID,
                    deviceName: deviceName
                )
                lastSaveError = error
            } catch {
                lastSaveError = error
                break
            }
        }

        if let lastSaveError {
            AppLogger.sync.error("Failed to save record: \(lastSaveError)")
            throw lastSaveError
        }
    }

    private func applyFields(
        to record: CKRecord,
        identity: CanonicalBookIdentity,
        position: TimeInterval,
        playbackRate: Double,
        completed: Bool,
        lastInteractionDate: Date,
        deviceID: String,
        deviceName: String
    ) {
        record["title"] = identity.originalTitle
        record["author"] = identity.originalAuthor ?? ""
        record["normalizedTitle"] = identity.normalizedTitle
        record["normalizedAuthor"] = identity.normalizedAuthor
        record["duration"] = identity.durationSeconds
        record["seriesName"] = identity.seriesName
        record["seriesIndex"] = identity.seriesIndex
        record["playbackPosition"] = position
        record["lastUpdated"] = lastInteractionDate
        record["playbackRate"] = playbackRate
        record["completed"] = completed
        record["deviceID"] = deviceID
        record["deviceName"] = deviceName
    }

    private func shouldUpdateRecord(
        _ record: CKRecord,
        localPosition: TimeInterval,
        lastInteractionDate: Date,
        sourceLabel: String
    ) -> Bool {
        guard let existingDate = record["lastUpdated"] as? Date else {
            return true
        }

        let existingPosition = (record["playbackPosition"] as? Double) ?? 0
        let timeDiff = lastInteractionDate.timeIntervalSince(existingDate)
        let positionDiff = abs(localPosition - existingPosition)

        AppLogger.sync.info("Conflict check against \(sourceLabel):")
        AppLogger.sync.info("Local: \(Int(localPosition))s at \(lastInteractionDate)")
        AppLogger.sync.info("Remote: \(Int(existingPosition))s at \(existingDate)")
        AppLogger.sync.info("Time diff: \(Int(timeDiff))s, Position diff: \(Int(positionDiff))s")

        if timeDiff < -5 && positionDiff > 60 {
            AppLogger.sync.warning("BLOCKED: \(sourceLabel) progress is newer - not overwriting")
            AppLogger.sync.info("Remote was updated \(Int(-timeDiff))s after our last interaction")
            return false
        }

        return true
    }

    private func latestServerRecord(from error: CKError) -> CKRecord? {
        error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
    }

    func fetchProgress(for identity: CanonicalBookIdentity, bypassCache: Bool = false) async throws -> PlaybackStateRecord? {
        if !bypassCache {
            if let cached = cachedRecords[identity.recordID],
                let lastFetch = lastFetchDate,
                Date().timeIntervalSince(lastFetch) < cacheValidityDuration
            {
                return cached
            }
        }

        guard await isAvailable() else {
            return nil
        }

        AppLogger.sync.info("Fetching fresh progress for: \(identity.originalTitle)")

        let recordID = CKRecord.ID(recordName: identity.recordID, zoneID: zoneID)

        do {
            let record = try await privateDatabase.record(for: recordID)
            if let playbackRecord = PlaybackStateRecord(from: record) {
                AppLogger.sync.info("Found record: \(Int(playbackRecord.playbackPosition))s from \(playbackRecord.deviceName ?? "unknown")")
                DispatchQueue.main.async {
                    self.cachedRecords[identity.recordID] = playbackRecord
                }
                return playbackRecord
            }
        } catch let error as CKError where error.code == .unknownItem {
            AppLogger.sync.info("No record found for: \(identity.originalTitle)")
            return nil
        } catch {
            AppLogger.sync.error("Error fetching record: \(error)")
            throw error
        }

        return nil
    }

    func fetchAllRecords() async throws -> [PlaybackStateRecord] {
        guard await isAvailable() else {
            return []
        }

        if let lastFetch = lastFetchDate,
            Date().timeIntervalSince(lastFetch) < cacheValidityDuration,
            !cachedRecords.isEmpty
        {
            AppLogger.sync.info("Returning \(cachedRecords.count) cached records")
            return Array(cachedRecords.values)
        }

        AppLogger.sync.info("Fetching all playback records from CloudKit...")

        if customZone != nil {
            AppLogger.sync.info("Using custom zone for fetch")
            return try await fetchFromCustomZone()
        } else {
            AppLogger.sync.info("Using query-based fetch")
            return try await fetchWithQuery()
        }
    }

    private func fetchFromCustomZone() async throws -> [PlaybackStateRecord] {

        return try await fetchFromCustomZone(retriesRemaining: 2)
    }

    private func fetchFromCustomZone(retriesRemaining: Int) async throws -> [PlaybackStateRecord] {
        do {
            var fetchedRecords: [PlaybackStateRecord] = []
            var changeToken: CKServerChangeToken? = savedChangeToken
            var moreComing = true

            while moreComing {
                let changes = try await privateDatabase.recordZoneChanges(
                    inZoneWith: zoneID,
                    since: changeToken
                )

                for (_, result) in changes.modificationResultsByID {
                    if case .success(let modification) = result {
                        let record = modification.record
                        if record.recordType == recordType {
                            if let playbackRecord = PlaybackStateRecord(from: record) {
                                fetchedRecords.append(playbackRecord)
                                let recordID = playbackRecord.recordID
                                DispatchQueue.main.async {
                                    self.cachedRecords[recordID] = playbackRecord
                                }
                            }
                        }
                    }
                }

                for deletion in changes.deletions {
                    let name = deletion.recordID.recordName
                    DispatchQueue.main.async {
                        self.cachedRecords.removeValue(forKey: name)
                    }
                }

                changeToken = changes.changeToken
                moreComing = changes.moreComing
            }

            if let finalToken = changeToken {
                savedChangeToken = finalToken
            }

            DispatchQueue.main.async {
                self.lastFetchDate = Date()
            }

            if !fetchedRecords.isEmpty {
                AppLogger.sync.info("Fetched \(fetchedRecords.count) changed records from custom zone")
            } else {
                AppLogger.sync.info("No new changes in custom zone")
            }

            return Array(cachedRecords.values)

        } catch let error as CKError where error.code == .changeTokenExpired {
            guard retriesRemaining > 0 else {
                AppLogger.sync.error("Change token expired repeatedly; falling back to query-based fetch")
                savedChangeToken = nil
                DispatchQueue.main.async { self.cachedRecords.removeAll() }
                return try await fetchWithQuery()
            }
            AppLogger.sync.warning("Change token expired - clearing and retrying full fetch")
            savedChangeToken = nil
            DispatchQueue.main.async {
                self.cachedRecords.removeAll()
            }
            return try await fetchFromCustomZone(retriesRemaining: retriesRemaining - 1)
        } catch {
            AppLogger.sync.error("Custom zone fetch failed: \(error)")
            return try await fetchWithQuery()
        }
    }

    private func fetchWithQuery() async throws -> [PlaybackStateRecord] {
        do {
            let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
            query.sortDescriptors = [NSSortDescriptor(key: "lastUpdated", ascending: false)]

            var allRecords: [PlaybackStateRecord] = []
            var cursor: CKQueryOperation.Cursor?

            repeat {
                let results: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)

                if let cursor = cursor {
                    results = try await privateDatabase.records(continuingMatchFrom: cursor)
                } else {
                    results = try await privateDatabase.records(matching: query, desiredKeys: nil)
                }

                for (_, result) in results.matchResults {
                    switch result {
                    case .success(let record):
                        if let playbackRecord = PlaybackStateRecord(from: record) {
                            allRecords.append(playbackRecord)
                        }
                    case .failure(let error):
                        AppLogger.sync.error("Failed to fetch individual record: \(error)")
                    }
                }

                cursor = results.queryCursor
            } while cursor != nil

            AppLogger.sync.info("Fetched \(allRecords.count) playback records via query")
            return allRecords

        } catch let error as CKError where error.code == .invalidArguments {
            AppLogger.sync.info("Schema not yet indexed - no records available")
            return []
        }
    }

    func invalidateCache() {
        cachedRecords.removeAll()
        lastFetchDate = nil
        AppLogger.sync.info("Cache invalidated")
    }

    func invalidateAccountStatusCache() {
        cachedAccountAvailable = nil
        accountStatusCacheDate = nil
        pushSubscriptionRegistered = false
    }

    func deleteAllRecords() async throws {
        guard await isAvailable() else {
            AppLogger.sync.warning("CloudKit not available, skipping delete")
            return
        }

        AppLogger.sync.info("Deleting all records...")

        let records = try await fetchAllRecords()

        if records.isEmpty {
            AppLogger.sync.info("No records to delete")
            return
        }

        for record in records {
            let recordID = CKRecord.ID(recordName: record.recordID, zoneID: zoneID)
            do {
                try await privateDatabase.deleteRecord(withID: recordID)
                AppLogger.sync.debug("Deleted CloudKit playback record")
            } catch {
                AppLogger.sync.error("Failed to delete CloudKit playback record: \(error)")
            }
        }

        invalidateCache()

        AppLogger.sync.info("Deleted \(records.count) records")
    }

    var currentDeviceID: String {
        #if os(iOS)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        return UUID().uuidString
        #endif
    }

    private var currentDeviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return "Mac"
        #endif
    }

    func registerForPushNotifications() async {
        guard !pushSubscriptionRegistered else { return }
        guard await isAvailable() else { return }

        do {
            _ = try await privateDatabase.subscription(for: pushSubscriptionID)
            pushSubscriptionRegistered = true
            AppLogger.sync.info("Push subscription already exists")
            return
        } catch {

            AppLogger.sync.debug("CloudKit push subscription not found; will create: \(error.localizedDescription)")
        }

        let subscription = CKDatabaseSubscription(subscriptionID: pushSubscriptionID)

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        do {
            _ = try await privateDatabase.save(subscription)
            pushSubscriptionRegistered = true
            AppLogger.sync.info("Registered push subscription for real-time sync")
        } catch {

            AppLogger.sync.error("Failed to register push subscription: \(error)")
        }
    }

    func handlePushNotification() async {
        guard await isAvailable() else { return }

        AppLogger.sync.info("Processing push notification...")

        do {
            let updatedRecords = try await fetchAllRecords()

            if !updatedRecords.isEmpty {
                AppLogger.sync.info("Push delivered \(updatedRecords.count) updated records")
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .cloudKitProgressDidChange,
                        object: nil,
                        userInfo: ["records": updatedRecords]
                    )
                }
            } else {
                AppLogger.sync.info("Push processed - no new changes")
            }
        } catch {
            AppLogger.sync.error("Failed to process push: \(error)")
        }
    }
}

struct PlaybackStateRecord: Codable, Sendable {
    let recordID: String
    let title: String
    let author: String
    let normalizedTitle: String
    let normalizedAuthor: String
    let duration: Int
    let seriesName: String?
    let seriesIndex: Double?
    let playbackPosition: TimeInterval
    let lastUpdated: Date
    let playbackRate: Double
    let completed: Bool
    let deviceID: String
    let deviceName: String?

    init?(from record: CKRecord) {
        guard let title = record["title"] as? String,
            let normalizedTitle = record["normalizedTitle"] as? String,
            let playbackPosition = record["playbackPosition"] as? Double,
            let lastUpdated = record["lastUpdated"] as? Date
        else {
            return nil
        }

        self.recordID = record.recordID.recordName
        self.title = title
        self.author = record["author"] as? String ?? ""
        self.normalizedTitle = normalizedTitle
        self.normalizedAuthor = record["normalizedAuthor"] as? String ?? ""
        self.duration = record["duration"] as? Int ?? 0
        self.seriesName = record["seriesName"] as? String
        self.seriesIndex = record["seriesIndex"] as? Double
        self.playbackPosition = playbackPosition
        self.lastUpdated = lastUpdated
        self.playbackRate = record["playbackRate"] as? Double ?? 1.0
        self.completed = record["completed"] as? Bool ?? false
        self.deviceID = record["deviceID"] as? String ?? ""
        self.deviceName = record["deviceName"] as? String
    }

    func toCanonicalIdentity() -> CanonicalBookIdentity {
        CanonicalBookIdentity(
            title: title,
            author: author.isEmpty ? nil : author,
            duration: TimeInterval(duration),
            seriesName: seriesName,
            seriesIndex: seriesIndex
        )
    }

    var progressPercentage: Double {
        guard duration > 0 else { return 0 }
        return min(playbackPosition / Double(duration), 1.0)
    }

    var timeRemaining: TimeInterval {
        max(0, Double(duration) - playbackPosition)
    }
}

extension Notification.Name {
    static let cloudKitProgressDidChange = Notification.Name("cloudKitProgressDidChange")
}

extension PlaybackStateRecord: CustomStringConvertible {
    var description: String {
        let positionFormatted = formatTime(playbackPosition)
        let durationFormatted = formatTime(Double(duration))
        return "PlaybackState(\(title) by \(author): \(positionFormatted)/\(durationFormatted), device: \(deviceName ?? deviceID))"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
