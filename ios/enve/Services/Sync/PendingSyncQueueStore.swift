import Foundation

struct DownloadedProgressBaseline: Codable, Equatable, Sendable {
    let id: UUID
    let position: TimeInterval
    let updatedAt: Date
    let isFinished: Bool

    init(position: TimeInterval, updatedAt: Date, isFinished: Bool) {
        id = UUID()
        self.position = position
        self.updatedAt = updatedAt
        self.isFinished = isFinished
    }

    func conflicts(with remote: ProviderAudiobookProgress, position remotePosition: TimeInterval) -> Bool {
        let differs = abs(remotePosition - position) >= 1 || remote.readState.isFinished != isFinished
        return differs && (remote.updatedAt.map { $0 > updatedAt } ?? true)
    }
}

/// Messages are fixed, user-facing copy; raw provider errors can carry URLs or tokens and are never stored.
struct PendingSyncFailure: Codable, Equatable {
    enum Category: String, Codable {
        case transient
        case authentication
        case conflict
    }

    let category: Category
    let message: String
    let occurredAt: TimeInterval
}

enum PendingSyncDeliveryStatus: Equatable {
    case waiting
    case retrying(lastFailure: PendingSyncFailure, nextAttempt: Date?)
    case authentication
    case conflict
    case validation(message: String)
}

struct PendingServerSync: Codable, Equatable {
    let stableId: String
    let sourceRaw: String
    let backendId: String?
    let serverItemId: String
    let position: TimeInterval
    let duration: TimeInterval
    let updatedAt: TimeInterval
    let domainRaw: String?
    let progress: Double?
    let locator: String?
    let isFinished: Bool?
    var downloadedBaseline: DownloadedProgressBaseline?
    var retryCount: Int = 0
    var nextRetryAfter: TimeInterval = 0
    var validationFailureMessage: String?
    var lastFailure: PendingSyncFailure?

    init(
        stableId: String,
        sourceRaw: String,
        backendId: String?,
        serverItemId: String,
        position: TimeInterval,
        duration: TimeInterval,
        updatedAt: TimeInterval,
        domainRaw: String? = nil,
        progress: Double? = nil,
        locator: String? = nil,
        isFinished: Bool? = nil,
        downloadedBaseline: DownloadedProgressBaseline? = nil,
        retryCount: Int = 0,
        nextRetryAfter: TimeInterval = 0,
        validationFailureMessage: String? = nil,
        lastFailure: PendingSyncFailure? = nil
    ) {
        self.stableId = stableId
        self.sourceRaw = sourceRaw
        self.backendId = backendId
        self.serverItemId = serverItemId
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
        self.domainRaw = domainRaw
        self.progress = progress
        self.locator = locator
        self.isFinished = isFinished
        self.downloadedBaseline = downloadedBaseline
        self.retryCount = retryCount
        self.nextRetryAfter = nextRetryAfter
        self.validationFailureMessage = validationFailureMessage
        self.lastFailure = lastFailure
    }

    var source: Book.BookSource? {
        Book.BookSource(rawValue: sourceRaw)
    }

    var domain: ProgressSyncDomain {
        domainRaw == "ebook" ? .ebook : .audiobook
    }

    var backoffDelay: TimeInterval {
        min(pow(2.0, Double(retryCount)) * 5, 900)
    }

    var isSuspended: Bool {
        nextRetryAfter == Date.distantFuture.timeIntervalSince1970
    }

    func deliveryStatus(at now: Date = Date()) -> PendingSyncDeliveryStatus {
        if let validationFailureMessage { return .validation(message: validationFailureMessage) }
        if lastFailure?.category == .conflict { return .conflict }
        if isSuspended { return .authentication }
        guard let lastFailure else { return .waiting }
        let nextAttempt = Date(timeIntervalSince1970: nextRetryAfter)
        return .retrying(lastFailure: lastFailure, nextAttempt: nextAttempt > now ? nextAttempt : nil)
    }

    /// Delivery bookkeeping changes while a checkpoint waits; only the progress payload identifies it.
    func isSameCheckpoint(as other: PendingServerSync) -> Bool {
        stableId == other.stableId && sourceRaw == other.sourceRaw && backendId == other.backendId
            && serverItemId == other.serverItemId && position == other.position && duration == other.duration
            && updatedAt == other.updatedAt && domainRaw == other.domainRaw && progress == other.progress
            && locator == other.locator && isFinished == other.isFinished
    }
}

@MainActor
@Observable
final class PendingSyncQueueStore {
    static var shared: PendingSyncQueueStore { ProfileSession.owner.pendingSync }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    @ObservationIgnored private var resolutionRevisions: [String: UUID] = [:]
    private(set) var entries: [String: PendingServerSync] = [:]

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "pendingServerSyncQueue"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    func enqueue(_ entry: PendingServerSync) {
        var entry = entry
        if entry.domain == .audiobook, let existing = entries[entry.stableId]?.downloadedBaseline {
            entry.downloadedBaseline = existing
        }
        entries[entry.stableId] = entry
        persist()
    }

    func acknowledgeDownloadedProgress(_ sent: PendingServerSync) {
        guard var latest = entries[sent.stableId], latest.downloadedBaseline == sent.downloadedBaseline else { return }
        if latest == sent {
            remove(stableId: sent.stableId)
        } else {
            latest.downloadedBaseline = nil
            entries[sent.stableId] = latest
            persist()
        }
    }

    func downloadedProgressResolution(for stableId: String) -> UUID? {
        resolutionRevisions[stableId]
    }

    func resolveDownloadedProgress(stableId: String) {
        resolutionRevisions[stableId] = UUID()
        remove(stableId: stableId)
    }

    func remove(stableId: String) {
        guard entries.removeValue(forKey: stableId) != nil else { return }
        persist()
    }

    func removeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        persist()
    }

    func entriesReady(at now: Date = Date()) -> [String: PendingServerSync] {
        let nowTs = now.timeIntervalSince1970
        return entries.filter { $0.value.nextRetryAfter <= nowTs }
    }

    /// Transient failures never expire the checkpoint; only the delay is capped by `backoffDelay`.
    func markRetry(stableId: String, failure: PendingSyncFailure? = nil, at now: Date = Date()) {
        guard var entry = entries[stableId] else { return }
        entry.retryCount = min(entry.retryCount + 1, 10)
        entry.nextRetryAfter = now.timeIntervalSince1970 + entry.backoffDelay
        if let failure { entry.lastFailure = failure }
        entries[stableId] = entry
        persist()
    }

    func suspend(stableId: String, validationFailureMessage: String? = nil, failure: PendingSyncFailure? = nil) {
        guard var entry = entries[stableId] else { return }
        entry.nextRetryAfter = Date.distantFuture.timeIntervalSince1970
        entry.validationFailureMessage = validationFailureMessage
        if let failure { entry.lastFailure = failure }
        entries[stableId] = entry
        persist()
    }

    func resumeSuspended() {
        var changed = false
        for (stableId, var entry) in entries where entry.isSuspended && entry.validationFailureMessage == nil {
            entry.nextRetryAfter = 0
            entry.lastFailure = nil
            entries[stableId] = entry
            changed = true
        }
        if changed {
            persist()
        }
    }

    /// Returns false when `selected` was replaced by a newer checkpoint or already delivered.
    @discardableResult
    func retryNow(_ selected: PendingServerSync) -> Bool {
        guard var entry = entries[selected.stableId], entry.isSameCheckpoint(as: selected),
            entry.validationFailureMessage == nil
        else { return false }
        entry.retryCount = 0
        entry.nextRetryAfter = 0
        entries[selected.stableId] = entry
        persist()
        return true
    }

    /// Conflicted checkpoints stay queued so the downloaded baseline survives until the user picks a side.
    @discardableResult
    func discard(_ selected: PendingServerSync) -> Bool {
        guard let entry = entries[selected.stableId], entry.isSameCheckpoint(as: selected),
            entry.lastFailure?.category != .conflict
        else { return false }
        remove(stableId: selected.stableId)
        return true
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
            let queue = try? JSONDecoder().decode([String: PendingServerSync].self, from: data)
        else { return }
        entries = queue
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
