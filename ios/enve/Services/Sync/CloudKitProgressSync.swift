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
    @ObservationIgnored private let audiobookRecordType = "BookPlaybackState"
    @ObservationIgnored private let ebookRecordType = "BookReadingState"
    @ObservationIgnored private let customZoneName = "BookProgressZone"
    @ObservationIgnored private let pushSubscriptionID = "BookProgressChanges"

    private(set) var cachedRecords: [String: PlaybackStateRecord] = [:]
    private(set) var lastFetchDate: Date?
    private(set) var isSyncing = false
    private(set) var pushSubscriptionRegistered = false
    @ObservationIgnored private var isCustomZoneReady = false

    private var cachedAccountAvailable: Bool?
    private var accountStatusCacheDate: Date?
    private let accountStatusCacheTTL: TimeInterval = 120

    @ObservationIgnored private var changeToken: CKServerChangeToken?
    @ObservationIgnored private var didCheckLegacyDefaultZone = false

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
            }
            return available
        } catch {
            AppLogger.sync.error("Account status check failed: \(error)")
            return false
        }
    }

    private func ensureCustomZoneExists() async throws {
        guard !isCustomZoneReady else { return }

        do {
            let zoneID = CKRecordZone.ID(zoneName: customZoneName, ownerName: CKCurrentUserDefaultName)

            do {
                let zones = try await privateDatabase.recordZones(for: [zoneID])
                if let zoneResult = zones[zoneID] {
                    switch zoneResult {
                    case .success:
                        isCustomZoneReady = true
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
            guard let saveResult = savedZones.saveResults[zoneID] else {
                throw CloudKitProgressError.zoneSetupFailed
            }
            switch saveResult {
            case .success:
                isCustomZoneReady = true
                AppLogger.sync.info("Created custom zone: \(customZoneName)")
            case .failure(let error):
                throw error
            }

        } catch {
            AppLogger.sync.error("Failed to create custom zone: \(error)")
            throw error
        }
    }

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: customZoneName, ownerName: CKCurrentUserDefaultName)
    }

    private func recordID(for identity: CanonicalBookIdentity, domain: ProgressSyncDomain) -> CKRecord.ID {
        CKRecord.ID(recordName: Self.recordName(for: identity, domain: domain), zoneID: zoneID)
    }

    static func recordName(for identity: CanonicalBookIdentity, domain: ProgressSyncDomain) -> String {
        guard domain == .ebook else { return identity.recordID }
        let ebookIdentity = CanonicalBookIdentity(
            title: identity.originalTitle,
            author: identity.originalAuthor,
            duration: nil,
            seriesName: identity.seriesName,
            seriesIndex: identity.seriesIndex
        )
        return "\(ebookIdentity.recordID)-ebook"
    }

    private func recordType(for domain: ProgressSyncDomain) -> CKRecord.RecordType {
        domain == .audiobook ? audiobookRecordType : ebookRecordType
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
        contentHash: String? = nil,
        position: TimeInterval,
        progress: Double,
        locator: String?,
        domain: ProgressSyncDomain,
        playbackRate: Double = 1.0,
        completed: Bool = false,
        lastInteractionDate: Date = Date()
    ) async throws {
        guard await isAvailable() else {
            AppLogger.sync.warning("CloudKit not available, skipping save")
            throw CloudKitProgressError.accountUnavailable
        }
        try await ensureCustomZoneExists()

        let deviceID = currentDeviceID
        let deviceName = currentDeviceName

        AppLogger.sync.info("Attempting to save - recordID: \(identity.recordID.prefix(12))...")

        var recordIDInZone = recordID(for: identity, domain: domain)

        var record: CKRecord
        var shouldUpdate = true

        do {
            record = try await privateDatabase.record(for: recordIDInZone)
            AppLogger.sync.info("Found existing record for: \(identity.originalTitle)")

            shouldUpdate = shouldUpdateRecord(
                record,
                localPosition: position,
                localProgress: progress,
                domain: domain,
                lastInteractionDate: lastInteractionDate,
                sourceLabel: "Cloud"
            )
        } catch let error as CKError where error.code == .unknownItem {
            if let contentHash,
                let matching = try await fetchAllRecords(bypassCache: true)
                    .filter({ $0.domain == domain && $0.contentHash == contentHash })
                    .max(by: { $0.lastUpdated < $1.lastUpdated })
            {
                recordIDInZone = CKRecord.ID(recordName: matching.recordID, zoneID: zoneID)
                record = try await privateDatabase.record(for: recordIDInZone)
                shouldUpdate = shouldUpdateRecord(
                    record,
                    localPosition: position,
                    localProgress: progress,
                    domain: domain,
                    lastInteractionDate: lastInteractionDate,
                    sourceLabel: "Cloud"
                )
                AppLogger.sync.info("Found existing record by content hash")
            } else {
                record = CKRecord(recordType: recordType(for: domain), recordID: recordIDInZone)
                AppLogger.sync.info("Creating new record for: \(identity.originalTitle)")
            }
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
            contentHash: contentHash,
            position: position,
            progress: progress,
            locator: locator,
            domain: domain,
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
                    cachedRecords[playbackRecord.recordID] = playbackRecord
                }

                lastFetchDate = nil
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
                    localProgress: progress,
                    domain: domain,
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
                    contentHash: contentHash,
                    position: position,
                    progress: progress,
                    locator: locator,
                    domain: domain,
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
        contentHash: String?,
        position: TimeInterval,
        progress: Double,
        locator: String?,
        domain: ProgressSyncDomain,
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
        if let contentHash {
            record["contentHash"] = contentHash
        }
        record["playbackPosition"] = position
        record["normalizedProgress"] = min(max(progress, 0), 1)
        record["progressDomain"] = domain.rawValue
        record["locator"] = locator
        record["lastUpdated"] = lastInteractionDate
        record["playbackRate"] = playbackRate
        record["completed"] = completed
        record["deviceID"] = deviceID
        record["deviceName"] = deviceName
    }

    private func shouldUpdateRecord(
        _ record: CKRecord,
        localPosition: TimeInterval,
        localProgress: Double,
        domain: ProgressSyncDomain,
        lastInteractionDate: Date,
        sourceLabel: String
    ) -> Bool {
        guard let existingDate = record["lastUpdated"] as? Date else {
            return true
        }

        let existingPosition = (record["playbackPosition"] as? Double) ?? 0
        let existingProgress = (record["normalizedProgress"] as? Double)
            ?? ((record["duration"] as? Int).flatMap { $0 > 0 ? existingPosition / Double($0) : nil } ?? 0)
        let timeDiff = lastInteractionDate.timeIntervalSince(existingDate)
        let progressDiff = abs(localProgress - existingProgress)
        let hasMeaningfulDifference = domain == .ebook
            ? progressDiff > 0.005
            : abs(localPosition - existingPosition) > 60

        AppLogger.sync.info("Conflict check against \(sourceLabel):")
        AppLogger.sync.info("Local: \(Int(localPosition))s at \(lastInteractionDate)")
        AppLogger.sync.info("Remote: \(Int(existingPosition))s at \(existingDate)")
        AppLogger.sync.info("Time diff: \(Int(timeDiff))s, Progress diff: \(Int(progressDiff * 100))%")

        if timeDiff < -5 && hasMeaningfulDifference {
            AppLogger.sync.warning("BLOCKED: \(sourceLabel) progress is newer - not overwriting")
            AppLogger.sync.info("Remote was updated \(Int(-timeDiff))s after our last interaction")
            return false
        }

        return true
    }

    private func latestServerRecord(from error: CKError) -> CKRecord? {
        error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
    }

    func fetchProgress(
        for identity: CanonicalBookIdentity,
        domain: ProgressSyncDomain = .audiobook,
        contentHash: String? = nil,
        bypassCache: Bool = false
    ) async throws -> PlaybackStateRecord? {
        let cacheKey = Self.recordName(for: identity, domain: domain)
        if !bypassCache {
            if let cached = cachedRecords[cacheKey],
                let lastFetch = lastFetchDate,
                Date().timeIntervalSince(lastFetch) < cacheValidityDuration
            {
                return cached
            }
        }

        guard await isAvailable() else {
            return nil
        }
        try await ensureCustomZoneExists()

        AppLogger.sync.info("Fetching fresh progress for: \(identity.originalTitle)")

        let recordID = recordID(for: identity, domain: domain)

        do {
            let record = try await privateDatabase.record(for: recordID)
            if let playbackRecord = PlaybackStateRecord(from: record) {
                AppLogger.sync.info("Found record: \(Int(playbackRecord.playbackPosition))s from \(playbackRecord.deviceName ?? "unknown")")
                cachedRecords[cacheKey] = playbackRecord
                return playbackRecord
            }
        } catch let error as CKError where error.code == .unknownItem {
            if let contentHash {
                return try await fetchAllRecords(bypassCache: bypassCache)
                    .filter { $0.domain == domain && $0.contentHash == contentHash }
                    .max(by: { $0.lastUpdated < $1.lastUpdated })
            }
            AppLogger.sync.info("No record found for: \(identity.originalTitle)")
            return nil
        } catch {
            AppLogger.sync.error("Error fetching record: \(error)")
            throw error
        }

        return nil
    }

    func fetchAllRecords(bypassCache: Bool = false) async throws -> [PlaybackStateRecord] {
        guard await isAvailable() else {
            return []
        }
        try await ensureCustomZoneExists()

        if !bypassCache,
            let lastFetch = lastFetchDate,
            Date().timeIntervalSince(lastFetch) < cacheValidityDuration,
            !cachedRecords.isEmpty
        {
            AppLogger.sync.info("Returning \(cachedRecords.count) cached records")
            return Array(cachedRecords.values)
        }

        AppLogger.sync.info("Fetching all playback records from CloudKit...")

        AppLogger.sync.info("Using custom zone for fetch")
        _ = try await fetchFromCustomZone()

        if !didCheckLegacyDefaultZone {
            do {
                let legacyRecords = try await fetchWithQuery(
                    recordType: audiobookRecordType,
                    zoneID: CKRecordZone.default().zoneID,
                    cacheResults: false
                )
                didCheckLegacyDefaultZone = true
                for record in legacyRecords {
                    if let current = cachedRecords[record.recordID], current.lastUpdated >= record.lastUpdated {
                        continue
                    }
                    cachedRecords[record.recordID] = record
                }
            } catch {
                AppLogger.sync.warning("Legacy CloudKit zone check deferred: \(error.localizedDescription)")
            }
        }

        return Array(cachedRecords.values)
    }

    private func fetchFromCustomZone() async throws -> [PlaybackStateRecord] {
        try await fetchFromCustomZone(retriesRemaining: 2, returnOnlyChanges: false)
    }

    private func fetchChangedRecords() async throws -> [PlaybackStateRecord] {
        guard await isAvailable() else { return [] }
        try await ensureCustomZoneExists()
        guard changeToken != nil else {
            _ = try await fetchFromCustomZone(retriesRemaining: 2, returnOnlyChanges: false)
            return []
        }
        return try await fetchFromCustomZone(retriesRemaining: 2, returnOnlyChanges: true)
    }

    private func fetchFromCustomZone(
        retriesRemaining: Int,
        returnOnlyChanges: Bool
    ) async throws -> [PlaybackStateRecord] {
        do {
            var fetchedRecords: [PlaybackStateRecord] = []
            var nextChangeToken: CKServerChangeToken? = changeToken
            var moreComing = true

            while moreComing {
                let changes = try await privateDatabase.recordZoneChanges(
                    inZoneWith: zoneID,
                    since: nextChangeToken
                )

                for (_, result) in changes.modificationResultsByID {
                    if case .success(let modification) = result {
                        let record = modification.record
                        if record.recordType == audiobookRecordType || record.recordType == ebookRecordType {
                            if let playbackRecord = PlaybackStateRecord(from: record) {
                                fetchedRecords.append(playbackRecord)
                                let recordID = playbackRecord.recordID
                                cachedRecords[recordID] = playbackRecord
                            }
                        }
                    }
                }

                for deletion in changes.deletions {
                    let name = deletion.recordID.recordName
                    cachedRecords.removeValue(forKey: name)
                }

                nextChangeToken = changes.changeToken
                moreComing = changes.moreComing
            }

            changeToken = nextChangeToken

            lastFetchDate = Date()

            if !fetchedRecords.isEmpty {
                AppLogger.sync.info("Fetched \(fetchedRecords.count) changed records from custom zone")
            } else {
                AppLogger.sync.info("No new changes in custom zone")
            }

            return returnOnlyChanges ? fetchedRecords : Array(cachedRecords.values)

        } catch let error as CKError where error.code == .changeTokenExpired {
            guard retriesRemaining > 0 else {
                AppLogger.sync.error("Change token expired repeatedly; falling back to query-based fetch")
                changeToken = nil
                cachedRecords.removeAll()
                return try await fetchWithQuery()
            }
            AppLogger.sync.warning("Change token expired - clearing and retrying full fetch")
            changeToken = nil
            cachedRecords.removeAll()
            return try await fetchFromCustomZone(
                retriesRemaining: retriesRemaining - 1,
                returnOnlyChanges: returnOnlyChanges
            )
        } catch {
            AppLogger.sync.error("Custom zone fetch failed: \(error)")
            return try await fetchWithQuery()
        }
    }

    private func fetchWithQuery() async throws -> [PlaybackStateRecord] {
        var records: [PlaybackStateRecord] = []
        for type in [audiobookRecordType, ebookRecordType] {
            records.append(
                contentsOf: try await fetchWithQuery(
                    recordType: type,
                    zoneID: zoneID,
                    cacheResults: true
                )
            )
        }
        lastFetchDate = Date()
        return records
    }

    private func fetchWithQuery(
        recordType: CKRecord.RecordType,
        zoneID: CKRecordZone.ID,
        cacheResults: Bool
    ) async throws -> [PlaybackStateRecord] {
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
                    results = try await privateDatabase.records(
                        matching: query,
                        inZoneWith: zoneID,
                        desiredKeys: nil
                    )
                }

                for (_, result) in results.matchResults {
                    switch result {
                    case .success(let record):
                        if let playbackRecord = PlaybackStateRecord(from: record) {
                            allRecords.append(playbackRecord)
                            if cacheResults {
                                cachedRecords[playbackRecord.recordID] = playbackRecord
                            }
                        }
                    case .failure(let error):
                        AppLogger.sync.error("Failed to fetch individual record: \(error)")
                    }
                }

                cursor = results.queryCursor
            } while cursor != nil

            AppLogger.sync.info("Fetched \(allRecords.count) \(recordType) records via query")
            return allRecords

        } catch let error as CKError where error.code == .invalidArguments {
            AppLogger.sync.info("Schema not yet indexed - no records available")
            return []
        }
    }

    func invalidateCache() {
        cachedRecords.removeAll()
        lastFetchDate = nil
        changeToken = nil
        didCheckLegacyDefaultZone = false
        AppLogger.sync.info("Cache invalidated")
    }

    func invalidateAccountStatusCache() {
        cachedAccountAvailable = nil
        accountStatusCacheDate = nil
        pushSubscriptionRegistered = false
        isCustomZoneReady = false
        invalidateCache()
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
            try await ensureCustomZoneExists()
        } catch {
            return
        }

        do {
            let existing = try await privateDatabase.subscription(for: pushSubscriptionID)
            if let zoneSubscription = existing as? CKRecordZoneSubscription,
                zoneSubscription.zoneID == zoneID
            {
                pushSubscriptionRegistered = true
                AppLogger.sync.info("Push subscription already exists")
                return
            }
            do {
                try await privateDatabase.deleteSubscription(withID: pushSubscriptionID)
            } catch {
                AppLogger.sync.error("Failed to replace stale push subscription: \(error.localizedDescription)")
                return
            }
        } catch let error as CKError where error.code == .unknownItem {
            AppLogger.sync.debug("CloudKit push subscription not found; will create: \(error.localizedDescription)")
        } catch {
            AppLogger.sync.error("Failed to check push subscription: \(error.localizedDescription)")
            return
        }

        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: pushSubscriptionID)

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
        guard SyncCoordinator.shared.syncEnabled else { return }
        guard await isAvailable() else { return }

        AppLogger.sync.info("Processing push notification...")

        do {
            let updatedRecords = try await fetchChangedRecords()

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

private enum CloudKitProgressError: LocalizedError {
    case accountUnavailable
    case zoneSetupFailed

    var errorDescription: String? {
        switch self {
        case .accountUnavailable:
            "iCloud is not available for this account."
        case .zoneSetupFailed:
            "iCloud did not return the progress zone after creating it."
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
    let contentHash: String?
    let playbackPosition: TimeInterval
    let normalizedProgress: Double
    let locator: String?
    let domain: ProgressSyncDomain
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
        self.contentHash = record["contentHash"] as? String
        self.playbackPosition = playbackPosition
        self.normalizedProgress = record["normalizedProgress"] as? Double
            ?? (self.duration > 0 ? playbackPosition / Double(self.duration) : 0)
        self.locator = record["locator"] as? String
        self.domain = (record["progressDomain"] as? String)
            .flatMap(ProgressSyncDomain.init(rawValue:))
            ?? (record.recordType == "BookReadingState" ? .ebook : .audiobook)
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
        min(max(normalizedProgress, 0), 1)
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
        let positionFormatted = PlaybackTime.clock(playbackPosition)
        let durationFormatted = PlaybackTime.clock(Double(duration))
        return "PlaybackState(\(title) by \(author): \(positionFormatted)/\(durationFormatted), device: \(deviceName ?? deviceID))"
    }
}
