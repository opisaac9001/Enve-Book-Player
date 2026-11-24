import Foundation

enum PendingBookEditKind: String, Codable, Sendable {
    case rating
    case readStatus
}

/// Account-scoped so an edit queued under one sign-in is never sent or shown under another.
struct PendingBookEditKey: Codable, Hashable, Sendable {
    let connectionId: UUID
    let accountKey: String
    let bookId: String
    let kind: PendingBookEditKind

    var uniqueId: String { "\(connectionId)_\(bookId)" }

    fileprivate var storageKey: String {
        "\(connectionId.uuidString)|\(accountKey)|\(bookId)|\(kind.rawValue)"
    }
}

/// Messages are fixed, user-facing copy; raw provider errors can carry URLs or tokens and are never stored.
struct PendingBookEditFailure: Codable, Equatable, Sendable {
    enum Category: String, Codable, Sendable {
        case transient
        case authentication
        case rejected
    }

    let category: Category
    let message: String
    let occurredAt: TimeInterval
}

struct PendingBookEdit: Codable, Equatable, Sendable {
    enum Value: Codable, Equatable, Sendable {
        case rating(Int)
        /// The provider's own raw status value.
        case readStatus(String)

        var kind: PendingBookEditKind {
            switch self {
            case .rating: .rating
            case .readStatus: .readStatus
            }
        }
    }

    let key: PendingBookEditKey
    let revision: UUID
    let value: Value
    let editedAt: TimeInterval
    var retryCount = 0
    var nextRetryAfter: TimeInterval = 0
    var lastFailure: PendingBookEditFailure?

    var backoffDelay: TimeInterval {
        min(pow(2.0, Double(retryCount)) * 5, 900)
    }

    /// Authentication and rejected edits wait for a sign-in or an explicit retry instead of a timer.
    var isSuspended: Bool {
        nextRetryAfter == Date.distantFuture.timeIntervalSince1970
    }
}

@MainActor
@Observable
final class PendingBookEditStore {
    static var shared: PendingBookEditStore { ProfileSession.owner.pendingBookEdits }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    private(set) var entries: [String: PendingBookEdit] = [:]

    var isEmpty: Bool { entries.isEmpty }

    init(defaults: UserDefaults = .standard, storageKey: String = "pendingBookEdits.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        guard let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([String: PendingBookEdit].self, from: data)
        else { return }
        entries = decoded
    }

    func entry(for key: PendingBookEditKey) -> PendingBookEdit? {
        entries[key.storageKey]
    }

    func bookIds(connectionId: UUID, accountKey: String, kind: PendingBookEditKind) -> Set<String> {
        Set(
            entries.values.lazy
                .map(\.key)
                .filter { $0.connectionId == connectionId && $0.accountKey == accountKey && $0.kind == kind }
                .map(\.bookId)
        )
    }

    /// The latest edit for a book and kind replaces any earlier one, including its delivery bookkeeping.
    @discardableResult
    func enqueue(_ value: PendingBookEdit.Value, key: PendingBookEditKey, at now: Date = Date()) -> PendingBookEdit {
        precondition(value.kind == key.kind)
        let edit = PendingBookEdit(key: key, revision: UUID(), value: value, editedAt: now.timeIntervalSince1970)
        entries[key.storageKey] = edit
        persist()
        return edit
    }

    func isCurrent(_ edit: PendingBookEdit) -> Bool {
        entries[edit.key.storageKey]?.revision == edit.revision
    }

    /// Returns false when a newer edit replaced `sent` while it was in flight; that edit stays queued.
    @discardableResult
    func acknowledge(_ sent: PendingBookEdit) -> Bool {
        guard isCurrent(sent) else { return false }
        entries[sent.key.storageKey] = nil
        persist()
        return true
    }

    func entriesReady(at now: Date = Date()) -> [PendingBookEdit] {
        let timestamp = now.timeIntervalSince1970
        return entries.values
            .filter { $0.nextRetryAfter <= timestamp }
            .sorted { ($0.editedAt, $0.revision.uuidString) < ($1.editedAt, $1.revision.uuidString) }
    }

    func suspendedEntries(_ category: PendingBookEditFailure.Category) -> [PendingBookEdit] {
        entries.values.filter { $0.isSuspended && $0.lastFailure?.category == category }
    }

    func resumeTransientRetries() {
        for entry in entries.values where entry.lastFailure?.category == .transient {
            update(entry) { $0.nextRetryAfter = 0 }
        }
    }

    func markRetry(_ sent: PendingBookEdit, failure: PendingBookEditFailure, at now: Date = Date()) {
        update(sent) {
            $0.retryCount = min($0.retryCount + 1, 10)
            $0.nextRetryAfter = now.timeIntervalSince1970 + $0.backoffDelay
            $0.lastFailure = failure
        }
    }

    func suspend(_ sent: PendingBookEdit, failure: PendingBookEditFailure) {
        update(sent) {
            $0.nextRetryAfter = Date.distantFuture.timeIntervalSince1970
            $0.lastFailure = failure
        }
    }

    /// Returns false when `selected` was replaced by a newer edit or already delivered.
    @discardableResult
    func retryNow(_ selected: PendingBookEdit) -> Bool {
        update(selected) {
            $0.retryCount = 0
            $0.nextRetryAfter = 0
        }
    }

    @discardableResult
    func discard(_ selected: PendingBookEdit) -> Bool {
        acknowledge(selected)
    }

    @discardableResult
    private func update(_ sent: PendingBookEdit, _ transform: (inout PendingBookEdit) -> Void) -> Bool {
        guard var entry = entries[sent.key.storageKey], entry.revision == sent.revision else { return false }
        transform(&entry)
        entries[sent.key.storageKey] = entry
        persist()
        return true
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
