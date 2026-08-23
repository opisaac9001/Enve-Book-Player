import Foundation

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
    var retryCount: Int = 0
    var nextRetryAfter: TimeInterval = 0

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
        retryCount: Int = 0,
        nextRetryAfter: TimeInterval = 0
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
        self.retryCount = retryCount
        self.nextRetryAfter = nextRetryAfter
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
}

@MainActor
@Observable
final class PendingSyncQueueStore {
    static let shared = PendingSyncQueueStore()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

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
        entries[entry.stableId] = entry
        persist()
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

    func markRetry(stableId: String, maxRetries: Int = 10, at now: Date = Date()) {
        guard var entry = entries[stableId] else { return }
        if entry.retryCount >= maxRetries {
            entries.removeValue(forKey: stableId)
        } else {
            entry.retryCount += 1
            entry.nextRetryAfter = now.timeIntervalSince1970 + entry.backoffDelay
            entries[stableId] = entry
        }
        persist()
    }

    func suspend(stableId: String) {
        guard var entry = entries[stableId] else { return }
        entry.nextRetryAfter = Date.distantFuture.timeIntervalSince1970
        entries[stableId] = entry
        persist()
    }

    func resumeSuspended() {
        let suspendedRetryDate = Date.distantFuture.timeIntervalSince1970
        var changed = false
        for (stableId, var entry) in entries where entry.nextRetryAfter == suspendedRetryDate {
            entry.nextRetryAfter = 0
            entries[stableId] = entry
            changed = true
        }
        if changed {
            persist()
        }
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
