import Foundation
import Logging

public actor ListeningStatsTracker {
    public static let shared = ListeningStatsTracker()

    private struct ActiveSession {
        var bookId: String
        var lastPosition: TimeInterval
        var lastTimestamp: Date
        var playbackRate: Double
        var sessionStartedAt: Date
        var startPosition: TimeInterval
        var duration: TimeInterval?
        var startProgress: Double?
    }

    private var snapshot: ListeningStatsSnapshot
    private var activeSession: ActiveSession?
    private let statsURL: URL
    private let calendar = Calendar.current
    private let maxSampleInterval: TimeInterval = 600
    private var hasLoadedFromDisk = false
    private var lastStatsNotificationDate: Date = .distantPast
    private let statsNotificationMinimumInterval: TimeInterval = 5
    private var lastPersistDate: Date = .distantPast
    private let minimumPersistInterval: TimeInterval = 10
    private var pendingPersistTask: Task<Void, Never>?

    public func startTracking() async {
        guard !hasLoadedFromDisk else { return }
        await loadFromDisk()
    }

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Enve/PlaybackState", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        statsURL = dir.appendingPathComponent("listening_stats.json")
        snapshot = ListeningStatsSnapshot.empty
    }

    func startSession(bookId: String, position: TimeInterval, playbackRate: Double, duration: TimeInterval? = nil) async {
        await ensureLoaded()
        if let active = activeSession, active.bookId != bookId {
            endSessionSync(bookId: active.bookId, finalPosition: active.lastPosition)
        }
        guard activeSession?.bookId != bookId else { return }

        let now = Date()
        let startProgress = duration.flatMap { $0 > 0 ? (position / $0) : nil }
        activeSession = ActiveSession(
            bookId: bookId,
            lastPosition: position,
            lastTimestamp: now,
            playbackRate: playbackRate,
            sessionStartedAt: now,
            startPosition: position,
            duration: duration,
            startProgress: startProgress
        )

        snapshot.totalSessions += 1
        var bookStat =
            snapshot.perBook[bookId]
            ?? BookListeningStat(
                bookId: bookId,
                totalSeconds: 0,
                sessionCount: 0,
                lastPlayed: nil,
                lastPosition: nil,
                duration: nil,
                isCompleted: false
            )
        bookStat.sessionCount += 1
        snapshot.perBook[bookId] = bookStat
        snapshot.lastUpdated = Date()
    }

    func recordTick(bookId: String, position: TimeInterval, playbackRate: Double, isPlaying: Bool) async {
        guard isPlaying else { return }
        await ensureLoaded()

        if activeSession?.bookId != bookId {
            AppLogger.network.debug(
                "Starting listening session bookId=\(DiagnosticLogSanitizer.identifier(for: bookId))"
            )
            await startSession(bookId: bookId, position: position, playbackRate: playbackRate)
            return
        }

        guard var active = activeSession else { return }
        let now = Date()
        let deltaWall = min(max(0, now.timeIntervalSince(active.lastTimestamp)), maxSampleInterval)
        let deltaPosition = max(0, position - active.lastPosition)

        let expectedFromProgress = deltaPosition / max(active.playbackRate, 0.1)
        let listened = max(0, min(deltaWall, expectedFromProgress > 0 ? expectedFromProgress : deltaWall))

        if listened > 0 && Int(snapshot.totalSeconds) % 10 == 0 {
            AppLogger.network.info(
                "Recording \(String(format: "%.1f", listened))s for \(bookId) (total: \(String(format: "%.1f", snapshot.totalSeconds + listened))s)"
            )
        }

        guard listened > 0 else {
            active.lastTimestamp = now
            active.lastPosition = position
            active.playbackRate = playbackRate
            activeSession = active
            return
        }

        await apply(listenedSeconds: listened, for: active.bookId, at: now, position: position)

        active.lastTimestamp = now
        active.lastPosition = position
        active.playbackRate = playbackRate
        activeSession = active
    }

    func endSession(bookId: String? = nil, finalPosition: TimeInterval? = nil, duration: TimeInterval? = nil) async {
        await ensureLoaded()
        endSessionSync(bookId: bookId, finalPosition: finalPosition, duration: duration)
    }

    public func currentSnapshot() async -> ListeningStatsSnapshot {
        await ensureLoaded()
        var merged = snapshot
        let remoteSessions = await HistorySessionStore.shared.loadListeningSessions().filter { $0.source == .bookOrbit }
        let remotelyCompleted = Set(
            remoteSessions.compactMap { session in
                session.endProgress.map { $0 >= 0.99 ? session.bookId : nil } ?? nil
            }
        )

        for session in remoteSessions {
            let seconds = TimeInterval(session.durationSeconds)
            merged.totalSeconds += seconds
            merged.totalSessions += 1
            merged.dailySeconds[Self.dayKey(for: session.startTime), default: 0] += seconds

            var bookStat = merged.perBook[session.bookId] ?? BookListeningStat(bookId: session.bookId)
            bookStat.totalSeconds += seconds
            bookStat.sessionCount += 1
            if bookStat.lastPlayed.map({ session.endTime > $0 }) ?? true {
                bookStat.lastPlayed = session.endTime
                if let duration = bookStat.duration, let progress = session.endProgress {
                    bookStat.lastPosition = duration * progress
                }
            }
            if remotelyCompleted.contains(session.bookId) {
                bookStat.isCompleted = true
            }
            merged.perBook[session.bookId] = bookStat
        }

        merged.totalBooksFinished += remotelyCompleted.filter { snapshot.perBook[$0]?.isCompleted != true }.count
        merged.streak = Self.listeningStreak(from: merged.dailySeconds)
        return merged
    }

    public func resetForTesting() async {
        snapshot = .empty
        activeSession = nil
        await schedulePersist(force: true)
    }

    public func addManualListeningTime(seconds: TimeInterval, booksFinished: Int = 0, date: Date = Date()) async {
        guard seconds > 0 || booksFinished > 0 else { return }
        await ensureLoaded()
        snapshot.totalSeconds += seconds
        snapshot.totalBooksFinished += booksFinished
        snapshot.lastUpdated = date
        await schedulePersist(force: true)
    }

    public func markBookAsFinished(bookId: String) async {
        await ensureLoaded()
        snapshot.totalBooksFinished += 1

        if var bookStat = snapshot.perBook[bookId] {
            bookStat.isCompleted = true
            snapshot.perBook[bookId] = bookStat
        }

        snapshot.lastUpdated = Date()
        await schedulePersist(force: true)
    }

    public nonisolated func recordReadingSession(bookId: String, record: ReadingSpeedRecord) {
        Task {
            await _recordReadingSession(bookId: bookId, record: record)
        }
    }

    private func _recordReadingSession(bookId: String, record: ReadingSpeedRecord) async {
        await ensureLoaded()
        if var existing = snapshot.readingStats[bookId] {

            let totalSec = existing.totalReadingSeconds + record.totalReadingSeconds
            if totalSec > 0 {
                existing.averageProgressPerMinute =
                    (existing.averageProgressPerMinute * existing.totalReadingSeconds + record.averageProgressPerMinute
                        * record.totalReadingSeconds) / totalSec
            }
            existing.totalReadingSeconds = totalSec
            existing.lastUpdated = record.lastUpdated
            snapshot.readingStats[bookId] = existing
        } else {
            snapshot.readingStats[bookId] = record
        }
        snapshot.lastUpdated = Date()
        await schedulePersist(force: true)
    }

    private func ensureLoaded() async {
        guard !hasLoadedFromDisk else { return }
        await loadFromDisk()
    }

    private func endSessionSync(bookId: String? = nil, finalPosition: TimeInterval? = nil, duration: TimeInterval? = nil) {
        guard let active = activeSession else { return }
        if let bookId, bookId != active.bookId { return }

        let now = Date()
        let position = finalPosition ?? active.lastPosition
        let deltaWall = min(max(0, now.timeIntervalSince(active.lastTimestamp)), maxSampleInterval)
        let deltaPosition = max(0, position - active.lastPosition)
        let expectedFromProgress = deltaPosition / max(active.playbackRate, 0.1)
        let listened = max(0, min(deltaWall, expectedFromProgress > 0 ? expectedFromProgress : deltaWall))
        if listened > 0 {
            Task {
                await apply(listenedSeconds: listened, for: active.bookId, at: now, position: position, forcePersist: true)
            }
        }

        let totalDuration = Int(now.timeIntervalSince(active.sessionStartedAt))
        if totalDuration > 5 {
            let effectiveDuration = duration ?? active.duration
            let startProgress = active.startProgress
            let endProgress = effectiveDuration.flatMap { $0 > 0 ? (position / $0) : nil }
            let delta: Double?
            if let startProgress, let endProgress {
                delta = endProgress - startProgress
            } else {
                delta = nil
            }

            let session = HistorySession(
                id: UUID().uuidString,
                bookId: active.bookId,
                mediaType: "audiobook",
                startTime: active.sessionStartedAt,
                endTime: now,
                durationSeconds: totalDuration,
                startProgress: startProgress,
                endProgress: endProgress,
                progressDelta: delta,
                startLocation: nil,
                endLocation: nil,
                pagesRead: nil,
                source: .local
            )
            Task {
                await HistorySessionStore.shared.appendListeningSession(session)
                _ = await ProviderHistorySessionSync.shared.submit(session)
            }
        }

        activeSession = nil
    }

    private func apply(
        listenedSeconds: TimeInterval,
        for bookId: String,
        at date: Date,
        position: TimeInterval,
        forcePersist: Bool = false
    ) async {
        guard listenedSeconds > 0 else { return }
        snapshot.totalSeconds += listenedSeconds
        snapshot.lastUpdated = date

        var bookStat =
            snapshot.perBook[bookId]
            ?? BookListeningStat(
                bookId: bookId,
                totalSeconds: 0,
                sessionCount: 0,
                lastPlayed: nil,
                lastPosition: nil,
                duration: nil,
                isCompleted: false
            )
        bookStat.totalSeconds += listenedSeconds
        bookStat.lastPlayed = date
        bookStat.lastPosition = position
        snapshot.perBook[bookId] = bookStat

        let dayKey = Self.dayKey(for: date)
        snapshot.dailySeconds[dayKey, default: 0] += listenedSeconds
        updateStreakIfNeeded(dayKey: dayKey)

        await schedulePersist(force: forcePersist)
    }

    private func schedulePersist(force: Bool = false) async {
        if force {
            pendingPersistTask?.cancel()
            pendingPersistTask = nil
            await persistNow()
            return
        }

        let elapsed = Date().timeIntervalSince(lastPersistDate)
        if elapsed >= minimumPersistInterval {
            await persistNow()
            return
        }

        guard pendingPersistTask == nil else { return }

        let delay = minimumPersistInterval - elapsed
        pendingPersistTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            await self.persistNow()
        }
    }

    private func updateStreakIfNeeded(dayKey: String) {
        guard let dayDate = Self.dayFormatter.date(from: dayKey) else { return }
        let startOfDay = calendar.startOfDay(for: dayDate)
        let streakStart = calendar.startOfDay(for: snapshot.streak.lastActiveDay ?? startOfDay)

        if calendar.isDate(startOfDay, inSameDayAs: streakStart) {
            return
        }

        if let next = calendar.date(byAdding: .day, value: 1, to: streakStart), calendar.isDate(startOfDay, inSameDayAs: next) {
            snapshot.streak.current += 1
        } else {
            snapshot.streak.current = 1
        }

        snapshot.streak.lastActiveDay = startOfDay
        snapshot.streak.longest = max(snapshot.streak.longest, snapshot.streak.current)
    }

    private func persistNow() async {
        pendingPersistTask = nil
        let snap = snapshot
        lastPersistDate = Date()
        let shouldNotify = Date().timeIntervalSince(lastStatsNotificationDate) >= statsNotificationMinimumInterval
        if shouldNotify {
            lastStatsNotificationDate = Date()
        }
        await MainActor.run {
            do {
                let data = try Self.encoder.encode(snap)
                try data.write(to: statsURL, options: [.atomic])
                if Int(snap.totalSeconds) % 10 == 0 {
                    AppLogger.network.info("Persisted stats: \(String(format: "%.1f", snap.totalSeconds))s total, posting notification")
                }
                if shouldNotify {
                    NotificationCenter.default.post(name: .listeningStatsDidChange, object: nil)
                }
            } catch {
                AppLogger.network.error("Failed to persist listening stats: \(error)")
            }
        }
    }

    private func loadFromDisk() async {
        hasLoadedFromDisk = true
        guard let data = try? Data(contentsOf: statsURL) else { return }
        let decoded: ListeningStatsSnapshot? = await MainActor.run {
            do {
                return try Self.decoder.decode(ListeningStatsSnapshot.self, from: data)
            } catch {
                AppLogger.network.error("Failed to decode listening stats (migrating from older version?): \(error)")
                return nil
            }
        }
        if let decoded {
            snapshot = decoded

            var repaired = false
            for (key, stat) in snapshot.perBook {
                let maxRealisticSessions = max(1, Int(stat.totalSeconds / 60.0))
                if stat.sessionCount > maxRealisticSessions {
                    let fixedCount = max(1, Int(stat.totalSeconds / 1800.0))
                    let difference = stat.sessionCount - fixedCount
                    snapshot.totalSessions -= difference
                    snapshot.perBook[key]?.sessionCount = fixedCount
                    repaired = true
                }
            }
            if repaired {
                snapshot.totalSessions = max(0, snapshot.totalSessions)
                Task { await schedulePersist(force: true) }
            }

            lastPersistDate = Date()
        }
    }

    private nonisolated static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private nonisolated static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    private nonisolated static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: Calendar.current.startOfDay(for: date))
    }

    private nonisolated static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        return fmt
    }()

    private nonisolated static func listeningStreak(from daily: [String: TimeInterval]) -> ListeningStreak {
        let activeDays = daily
            .filter { $0.value > 0 }
            .compactMap { dayFormatter.date(from: $0.key) }
            .sorted()
        guard let last = activeDays.last else { return ListeningStreak() }

        let calendar = Calendar.current
        var longest = 1
        var run = 1
        for index in activeDays.indices.dropFirst() {
            let previous = calendar.startOfDay(for: activeDays[activeDays.index(before: index)])
            let current = calendar.startOfDay(for: activeDays[index])
            if calendar.dateComponents([.day], from: previous, to: current).day == 1 {
                run += 1
                longest = max(longest, run)
            } else if !calendar.isDate(previous, inSameDayAs: current) {
                run = 1
            }
        }

        let today = calendar.startOfDay(for: Date())
        let lastDay = calendar.startOfDay(for: last)
        let daysAgo = calendar.dateComponents([.day], from: lastDay, to: today).day ?? 0
        return ListeningStreak(current: daysAgo <= 1 ? run : 0, longest: longest, lastActiveDay: lastDay)
    }
}

extension Notification.Name {
    static let listeningStatsDidChange = Notification.Name("listeningStatsDidChange")
}
