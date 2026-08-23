import Foundation
import Logging

public actor ReadingStatsTracker {
    public static let shared = ReadingStatsTracker()

    private struct ActiveSession {
        var bookId: String
        var lastPositionProgression: Double
        var lastTimestamp: Date
        var sessionStartedAt: Date
        var startProgression: Double
        var startLocation: String?
    }

    private var snapshot: ReadingStatsSnapshot
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
        let dir = appSupport.appendingPathComponent("Enve/ReadingState", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        statsURL = dir.appendingPathComponent("reading_stats.json")
        snapshot = ReadingStatsSnapshot.empty
    }

    func startSession(bookId: String, positionProgression: Double, location: String? = nil) async {
        await ensureLoaded()
        if let active = activeSession, active.bookId != bookId {
            endSessionSync(bookId: active.bookId, finalProgression: active.lastPositionProgression)
        }
        guard activeSession?.bookId != bookId else { return }

        let now = Date()
        activeSession = ActiveSession(
            bookId: bookId,
            lastPositionProgression: positionProgression,
            lastTimestamp: now,
            sessionStartedAt: now,
            startProgression: positionProgression,
            startLocation: location
        )

        snapshot.totalSessions += 1
        var bookStat =
            snapshot.perBook[bookId]
            ?? BookReadingStat(
                bookId: bookId,
                totalSecondsRead: 0,
                sessionCount: 0,
                lastRead: nil,
                lastPositionProgression: nil,
                totalPages: nil,
                isCompleted: false
            )
        bookStat.sessionCount += 1
        snapshot.perBook[bookId] = bookStat
        snapshot.lastUpdated = Date()
    }

    func recordTick(bookId: String, positionProgression: Double, isReading: Bool, location: String? = nil) async {
        guard isReading else { return }
        await ensureLoaded()

        if activeSession?.bookId != bookId {
            AppLogger.network.debug(
                "[ReadingStatsTracker] Starting session bookId=\(DiagnosticLogSanitizer.identifier(for: bookId))"
            )
            await startSession(bookId: bookId, positionProgression: positionProgression, location: location)
            return
        }

        guard var active = activeSession else { return }
        let now = Date()

        let timeRead = min(max(0, now.timeIntervalSince(active.lastTimestamp)), maxSampleInterval)

        if timeRead > 0 && Int(snapshot.totalSecondsRead) % 10 == 0 {
            AppLogger.network.debug(
                "[ReadingStatsTracker] Recording \(String(format: "%.1f", timeRead))s bookId=\(DiagnosticLogSanitizer.identifier(for: bookId))"
            )
        }

        guard timeRead > 0 else {
            active.lastTimestamp = now
            active.lastPositionProgression = positionProgression
            activeSession = active
            return
        }

        await apply(secondsRead: timeRead, for: active.bookId, at: now, positionProgression: positionProgression)

        active.lastTimestamp = now
        active.lastPositionProgression = positionProgression
        activeSession = active
    }

    func endSession(bookId: String? = nil, finalProgression: Double? = nil, location: String? = nil) async {
        await ensureLoaded()
        endSessionSync(bookId: bookId, finalProgression: finalProgression, location: location)
    }

    public func currentSnapshot() async -> ReadingStatsSnapshot {
        await ensureLoaded()
        var merged = snapshot
        let remoteSessions = await HistorySessionStore.shared.loadReadingSessions().filter { $0.source == .bookOrbit }
        let remotelyCompleted = Set(
            remoteSessions.compactMap { session in
                session.endProgress.map { $0 >= 0.99 ? session.bookId : nil } ?? nil
            }
        )

        for session in remoteSessions {
            let seconds = TimeInterval(session.durationSeconds)
            merged.totalSecondsRead += seconds
            merged.totalSessions += 1
            merged.dailySecondsRead[Self.dayKey(for: session.startTime), default: 0] += seconds

            var bookStat = merged.perBook[session.bookId] ?? BookReadingStat(bookId: session.bookId)
            bookStat.totalSecondsRead += seconds
            bookStat.sessionCount += 1
            if bookStat.lastRead.map({ session.endTime > $0 }) ?? true {
                bookStat.lastRead = session.endTime
                bookStat.lastPositionProgression = session.endProgress
            }
            if remotelyCompleted.contains(session.bookId) {
                bookStat.isCompleted = true
            }
            merged.perBook[session.bookId] = bookStat
        }

        merged.totalBooksFinished += remotelyCompleted.filter { snapshot.perBook[$0]?.isCompleted != true }.count
        merged.streak = Self.readingStreak(from: merged.dailySecondsRead)
        return merged
    }

    public func resetForTesting() async {
        snapshot = .empty
        activeSession = nil
        await schedulePersist(force: true)
    }

    public func markBookAsFinished(bookId: String) async {
        await ensureLoaded()
        if let stat = snapshot.perBook[bookId], stat.isCompleted {
            return
        }
        snapshot.totalBooksFinished += 1

        if var bookStat = snapshot.perBook[bookId] {
            bookStat.isCompleted = true
            snapshot.perBook[bookId] = bookStat
        }

        snapshot.lastUpdated = Date()
        await schedulePersist(force: true)
    }

    public func updateBookTotalPages(bookId: String, totalPages: Int) async {
        await ensureLoaded()
        if var bookStat = snapshot.perBook[bookId] {
            bookStat.totalPages = totalPages
            snapshot.perBook[bookId] = bookStat
            await schedulePersist(force: true)
        }
    }

    private func ensureLoaded() async {
        guard !hasLoadedFromDisk else { return }
        await loadFromDisk()
    }

    private func endSessionSync(bookId: String? = nil, finalProgression: Double? = nil, location: String? = nil) {
        guard let active = activeSession else { return }
        if let bookId, bookId != active.bookId { return }

        let now = Date()
        let progression = finalProgression ?? active.lastPositionProgression
        let timeRead = min(max(0, now.timeIntervalSince(active.lastTimestamp)), maxSampleInterval)

        if timeRead > 0 {
            Task {
                await apply(secondsRead: timeRead, for: active.bookId, at: now, positionProgression: progression, forcePersist: true)
            }
        }

        let totalDuration = Int(now.timeIntervalSince(active.sessionStartedAt))
        if totalDuration >= 2 {
            let progressDelta = progression - active.startProgression

            let pagesRead: Int? = {
                guard let totalPages = snapshot.perBook[active.bookId]?.totalPages else { return nil }
                let absDelta = abs(progressDelta)
                guard absDelta > 0.0001 else { return nil }
                return max(1, Int(round(absDelta * Double(totalPages))))
            }()

            let session = HistorySession(
                id: UUID().uuidString,
                bookId: active.bookId,
                mediaType: "ebook",
                startTime: active.sessionStartedAt,
                endTime: now,
                durationSeconds: totalDuration,
                startProgress: active.startProgression,
                endProgress: progression,
                progressDelta: progressDelta > 0 ? progressDelta : (progressDelta < -0.001 ? progressDelta : nil),
                startLocation: active.startLocation,
                endLocation: location,
                pagesRead: pagesRead,
                source: .local
            )
            Task {
                await HistorySessionStore.shared.appendReadingSession(session)
                _ = await ProviderHistorySessionSync.shared.submit(session)
            }
        }

        activeSession = nil
    }

    private func apply(
        secondsRead: TimeInterval,
        for bookId: String,
        at date: Date,
        positionProgression: Double,
        forcePersist: Bool = false
    ) async {
        guard secondsRead > 0 else { return }
        snapshot.totalSecondsRead += secondsRead
        snapshot.lastUpdated = date

        var bookStat =
            snapshot.perBook[bookId]
            ?? BookReadingStat(
                bookId: bookId,
                totalSecondsRead: 0,
                sessionCount: 0,
                lastRead: nil,
                lastPositionProgression: nil,
                totalPages: nil,
                isCompleted: false
            )
        bookStat.totalSecondsRead += secondsRead
        bookStat.lastRead = date
        bookStat.lastPositionProgression = positionProgression
        snapshot.perBook[bookId] = bookStat

        let dayKey = Self.dayKey(for: date)
        snapshot.dailySecondsRead[dayKey, default: 0] += secondsRead
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
                if Int(snap.totalSecondsRead) % 10 == 0 {
                    AppLogger.network.info("Persisted stats: \(String(format: "%.1f", snap.totalSecondsRead))s total")
                }
                if shouldNotify {
                    NotificationCenter.default.post(name: .readingStatsDidChange, object: nil)
                }
            } catch {
                AppLogger.network.error("Failed to persist reading stats: \(error)")
            }
        }
    }

    private func loadFromDisk() async {
        hasLoadedFromDisk = true
        guard let data = try? Data(contentsOf: statsURL) else { return }
        let decoded: ReadingStatsSnapshot? = await MainActor.run {
            do {
                return try Self.decoder.decode(ReadingStatsSnapshot.self, from: data)
            } catch {
                AppLogger.network.error("Failed to decode reading stats: \(error)")
                return nil
            }
        }
        if let decoded {
            snapshot = decoded
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

    private nonisolated static func readingStreak(from daily: [String: TimeInterval]) -> ReadingStreak {
        let activeDays = daily
            .filter { $0.value > 0 }
            .compactMap { dayFormatter.date(from: $0.key) }
            .sorted()
        guard let last = activeDays.last else { return ReadingStreak() }

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
        return ReadingStreak(current: daysAgo <= 1 ? run : 0, longest: longest, lastActiveDay: lastDay)
    }
}

extension Notification.Name {
    static let readingStatsDidChange = Notification.Name("readingStatsDidChange")
}
