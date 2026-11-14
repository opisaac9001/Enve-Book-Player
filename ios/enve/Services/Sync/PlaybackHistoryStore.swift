import Foundation
import Logging

nonisolated enum PlaybackHistoryCategory: String, CaseIterable, Sendable {
    case playback
    case sync
}

nonisolated enum PlaybackHistoryKind: String, Codable, Sendable {
    case playbackStarted
    case playbackFailed
    case playbackRecovered
    case progressSynced
    case remoteProgressApplied
    case syncQueued
    case syncFailed
    case progressCheckFailed
    case conflictDetected
    case keptLocalPosition
    case usedServerPosition

    var category: PlaybackHistoryCategory {
        switch self {
        case .playbackStarted, .playbackFailed, .playbackRecovered: .playback
        default: .sync
        }
    }

    var isProblem: Bool {
        switch self {
        case .playbackFailed, .syncQueued, .syncFailed, .progressCheckFailed, .conflictDetected: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .playbackStarted: "Started listening"
        case .playbackFailed: "Playback stopped"
        case .playbackRecovered: "Playback recovered"
        case .progressSynced: "Progress synced"
        case .remoteProgressApplied: "Position updated from sync"
        case .syncQueued: "Sync will retry"
        case .syncFailed: "Progress didn't sync"
        case .progressCheckFailed: "Couldn't check progress"
        case .conflictDetected: "Positions differ"
        case .keptLocalPosition: "Kept this device's position"
        case .usedServerPosition: "Moved to the server's position"
        }
    }

    var systemImage: String {
        switch self {
        case .playbackStarted: "play.circle.fill"
        case .playbackFailed: "exclamationmark.circle.fill"
        case .playbackRecovered: "arrow.clockwise.circle.fill"
        case .progressSynced: "checkmark.icloud.fill"
        case .remoteProgressApplied: "arrow.down.circle.fill"
        case .syncQueued: "icloud.slash.fill"
        case .syncFailed, .progressCheckFailed: "exclamationmark.icloud.fill"
        case .conflictDetected: "arrow.triangle.branch"
        case .keptLocalPosition: "iphone"
        case .usedServerPosition: "server.rack"
        }
    }

    // Fixed copy only: provider errors can carry hosts, paths, or tokens.
    fileprivate var fixedSummary: String? {
        switch self {
        case .playbackFailed: "Enve couldn't play this book."
        case .remoteProgressApplied: "Applied a position saved by another device or service."
        case .syncQueued: "The connection failed. Your position is saved here and queued."
        case .syncFailed: "Enve couldn't save this position to the server."
        case .progressCheckFailed: "Kept the position on this device."
        default: nil
        }
    }
}

nonisolated enum PlaybackHistoryDetail: Codable, Equatable, Sendable {
    case position(TimeInterval)
    case positions(local: TimeInterval, server: TimeInterval)
    case progress(local: Double, remote: Double)
}

nonisolated struct PlaybackHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: PlaybackHistoryKind
    let bookStableId: String
    var bookTitle: String
    var detail: PlaybackHistoryDetail?
    var occurredAt: Date
    var repeatCount: Int

    var summary: String? {
        switch (kind, detail) {
        case (.playbackStarted, .position(let time)?):
            return "From \(Self.clock(time))"
        case (.playbackRecovered, .position(let time)?):
            return "Playing again from \(Self.clock(time))"
        case (.keptLocalPosition, .position(let time)?), (.usedServerPosition, .position(let time)?):
            return "At \(Self.clock(time))"
        case (.conflictDetected, .progress(let local, let remote)?):
            return "This device \(Self.percent(local)) · Elsewhere \(Self.percent(remote))"
        case (.conflictDetected, .positions(let local, let server)?):
            return "This device \(Self.clock(local)) · Server \(Self.clock(server))"
        default:
            return kind.fixedSummary
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let duration = Duration.seconds(max(0, seconds.rounded()))
        return seconds >= 3600
            ? duration.formatted(.time(pattern: .hourMinuteSecond))
            : duration.formatted(.time(pattern: .minuteSecond))
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }
}

@MainActor
@Observable
final class PlaybackHistoryStore {
    static var shared: PlaybackHistoryStore { ProfileSession.owner.playbackHistory }

    nonisolated static let maximumEntries = 200
    nonisolated static let retention: TimeInterval = 7 * 24 * 60 * 60
    nonisolated static let repeatWindow: TimeInterval = 30 * 60
    nonisolated static let maximumTitleLength = 200

    private(set) var entries: [PlaybackHistoryEntry]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let writeDelay: Duration
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var lastWrite: Task<Void, Never>?

    init(fileURL: URL, writeDelay: Duration = .seconds(1), now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.writeDelay = writeDelay
        self.now = now
        entries = Self.retained(Self.load(from: fileURL), now: now())
    }

    convenience init(storage: ProfileStorageLocations) {
        self.init(fileURL: storage.applicationSupportDirectory.appendingPathComponent("Enve/playback-history.json"))
    }

    func record(_ kind: PlaybackHistoryKind, book: Book, detail: PlaybackHistoryDetail? = nil) {
        record(kind, bookStableId: book.stableId, title: book.title, detail: detail)
    }

    func record(_ event: SyncEvent, book: Book) {
        guard let content = Self.content(for: event) else { return }
        record(content.kind, book: book, detail: content.detail)
    }

    func record(_ kind: PlaybackHistoryKind, bookStableId: String, title: String, detail: PlaybackHistoryDetail? = nil) {
        let date = now()
        let safeTitle = Self.safeTitle(title)
        var updated = entries
        // Recurring identical events (periodic pushes, repeated retries) fold into one row.
        if let index = updated.firstIndex(where: {
            $0.kind == kind && $0.bookStableId == bookStableId
                && date.timeIntervalSince($0.occurredAt) < Self.repeatWindow
        }) {
            var entry = updated.remove(at: index)
            entry.bookTitle = safeTitle
            entry.detail = detail
            entry.occurredAt = date
            entry.repeatCount += 1
            updated.insert(entry, at: 0)
        } else {
            updated.insert(
                PlaybackHistoryEntry(
                    id: UUID(),
                    kind: kind,
                    bookStableId: bookStableId,
                    bookTitle: safeTitle,
                    detail: detail,
                    occurredAt: date,
                    repeatCount: 1
                ),
                at: 0
            )
        }
        entries = Self.retained(updated, now: date)
        scheduleWrite()
    }

    func clear(bookStableId: String? = nil) {
        let remaining = bookStableId.map { id in entries.filter { $0.bookStableId != id } } ?? []
        guard remaining.count != entries.count else { return }
        entries = remaining
        scheduleWrite()
        Task { await flush() }
    }

    func flush() async {
        if let writeTask {
            writeTask.cancel()
            await writeTask.value
        }
        await lastWrite?.value
    }

    static func content(for event: SyncEvent) -> (kind: PlaybackHistoryKind, detail: PlaybackHistoryDetail?)? {
        let kind: PlaybackHistoryKind
        var detail: PlaybackHistoryDetail?
        switch event {
        case .pullStarted, .pushStarted:
            return nil
        // `applied: false` covers no remote data, a newer local position, echoes, and conflicts alike.
        case .pullCompleted(_, let applied):
            guard applied else { return nil }
            kind = .remoteProgressApplied
        case .pullFailed:
            kind = .progressCheckFailed
        case .pushCompleted:
            kind = .progressSynced
        case .pushFailed(_, _, let retryable):
            kind = retryable ? .syncQueued : .syncFailed
        case .conflictDetected(_, let local, let remote, _):
            kind = .conflictDetected
            detail = .progress(local: local, remote: remote)
        }
        return (kind, detail)
    }

    static func retained(_ entries: [PlaybackHistoryEntry], now: Date) -> [PlaybackHistoryEntry] {
        let cutoff = now.addingTimeInterval(-retention)
        return Array(
            entries
                .filter { $0.occurredAt >= cutoff }
                .sorted { $0.occurredAt > $1.occurredAt }
                .prefix(maximumEntries)
        )
    }

    private nonisolated static func safeTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(maximumTitleLength))
    }

    private func scheduleWrite() {
        guard writeTask == nil else { return }
        let delay = writeDelay
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.write()
        }
    }

    private func write() async {
        writeTask = nil
        let snapshot = entries
        let url = fileURL
        let previous = lastWrite
        let task = Task.detached(priority: .utility) {
            await previous?.value
            PlaybackHistoryStore.persist(snapshot, to: url)
        }
        lastWrite = task
        await task.value
    }

    private nonisolated static func persist(_ entries: [PlaybackHistoryEntry], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        } catch {
            AppLogger.sync.error("Couldn't persist playback history: \(error.localizedDescription)")
        }
    }

    private nonisolated static func load(from url: URL) -> [PlaybackHistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PlaybackHistoryEntry].self, from: data)) ?? []
    }
}
