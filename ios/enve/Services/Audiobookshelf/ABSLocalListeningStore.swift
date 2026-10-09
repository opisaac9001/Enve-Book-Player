import Foundation

// Per-item, per-day running totals for listening without a live ABS session; ABS upserts local sessions by id.
@MainActor
final class ABSLocalListeningStore {
    static let shared = ABSLocalListeningStore()

    struct Session: Codable, Equatable {
        let id: String
        let connectionId: UUID
        let libraryItemId: String
        let episodeId: String?
        let displayTitle: String
        let displayAuthor: String?
        let day: String
        let dayOfWeek: String
        var duration: TimeInterval
        var timeListening: TimeInterval
        var currentTime: TimeInterval
        let startedAt: Int64
        var updatedAt: Int64
        var needsUpload: Bool
        var accountId: String? = nil
    }

    private let defaultsKey = "absLocalListeningSessions.v1"
    private let retentionDays = 30
    private let defaults: UserDefaults
    private var sessions: [Session]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sessions = defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([Session].self, from: $0) } ?? []
    }

    func record(
        connectionId: UUID,
        libraryItemId: String,
        episodeId: String?,
        displayTitle: String,
        displayAuthor: String?,
        duration: TimeInterval,
        currentTime: TimeInterval,
        listened: TimeInterval,
        now: Date = .now
    ) {
        guard listened > 0 else { return }
        let day = Self.dayKey(now)
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        if let index = sessions.firstIndex(where: {
            $0.connectionId == connectionId && $0.accountId == nil
                && $0.libraryItemId == libraryItemId && $0.episodeId == episodeId && $0.day == day
        }) {
            sessions[index].timeListening += listened
            sessions[index].currentTime = currentTime
            sessions[index].duration = duration
            sessions[index].updatedAt = nowMillis
            sessions[index].needsUpload = true
        } else {
            sessions.append(
                Session(
                    id: UUID().uuidString.lowercased(),
                    connectionId: connectionId,
                    libraryItemId: libraryItemId,
                    episodeId: episodeId,
                    displayTitle: displayTitle,
                    displayAuthor: displayAuthor,
                    day: day,
                    dayOfWeek: Self.weekdayName(now),
                    duration: duration,
                    timeListening: listened,
                    currentTime: currentTime,
                    startedAt: nowMillis - Int64(listened * 1000),
                    updatedAt: nowMillis,
                    needsUpload: true
                )
            )
        }
        prune(now: now)
        persist()
    }

    func enqueueHistory(_ session: Session) {
        guard !sessions.contains(where: { $0.id == session.id }) else { return }
        sessions.append(session)
        persist()
    }

    func pendingUploads(connectionId: UUID, verifiedAccountId: String? = nil) -> [Session] {
        sessions.filter {
            $0.connectionId == connectionId && $0.needsUpload
                && ($0.accountId == nil || $0.accountId == verifiedAccountId)
        }
    }

    /// Clears the upload flag only for sessions unchanged since they were sent.
    func markUploaded(_ uploaded: [Session]) {
        for sent in uploaded {
            guard let index = sessions.firstIndex(where: { $0.id == sent.id }), sessions[index].updatedAt == sent.updatedAt else { continue }
            sessions[index].needsUpload = false
        }
        persist()
    }

    func discard(ids: Set<String>) {
        sessions.removeAll { ids.contains($0.id) }
        persist()
    }

    private func prune(now: Date) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        let cutoffKey = Self.dayKey(cutoff)
        sessions.removeAll { !$0.needsUpload && $0.day < cutoffKey }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(sessions), forKey: defaultsKey)
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func weekdayName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
}
