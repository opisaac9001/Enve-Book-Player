import Foundation
import Testing

@testable import enve

@MainActor
private final class ProfileStatsProviderResolver: LibraryProviderResolving {
    func provider(for providerId: UUID) -> LibraryProvider? { nil }
    func provider(for book: Book) -> LibraryProvider? { nil }
}

@MainActor
struct ProfileStatsTrackerTests {
    @Test func persistedStatisticsAndRemoteHistoryStayWithTheirCapturedProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = try fixture(root: root)
        let second = try fixture(root: root)
        defer {
            first.cleanDefaults()
            second.cleanDefaults()
            try? FileManager.default.removeItem(at: root)
        }
        await first.listening.addManualListeningTime(seconds: 120)
        await second.listening.addManualListeningTime(seconds: 30)
        await first.listening.recordReadingSession(
            bookId: "same-book",
            record: ReadingSpeedRecord(bookId: "same-book", totalReadingSeconds: 80)
        )
        await first.reading.markBookAsFinished(bookId: "same-book")
        await first.history.appendListeningSession(session(seconds: 20, mediaType: "audiobook"))
        await second.history.appendListeningSession(session(seconds: 10, mediaType: "audiobook"))
        await first.history.appendReadingSession(session(seconds: 40, mediaType: "ebook"))
        await first.listening.flush()
        await first.reading.flush()

        #expect(await first.listening.currentSnapshot().totalSeconds == 140)
        #expect(await second.listening.currentSnapshot().totalSeconds == 40)
        #expect(await first.reading.currentSnapshot().totalSecondsRead == 40)
        #expect(await second.reading.currentSnapshot().totalSecondsRead == 0)
        #expect(await second.reading.currentSnapshot().totalBooksFinished == 0)

        let restoredListening = try ListeningStatsTracker(
            storage: first.storage, historyStore: first.history, historySync: first.historySync
        )
        let restoredReading = try ReadingStatsTracker(
            storage: first.storage, historyStore: first.history, historySync: first.historySync
        )
        #expect(await restoredListening.currentSnapshot().totalSeconds == 140)
        #expect(await restoredListening.currentSnapshot().readingStats["same-book"]?.totalReadingSeconds == 80)
        #expect(await restoredReading.currentSnapshot().totalBooksFinished == 1)
        #expect(await restoredReading.currentSnapshot().totalSecondsRead == 40)
    }

    @Test func corruptChildStatisticsRejectOpeningAndPreserveBytesOnLateFlush() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = try fixture(root: root)
        defer {
            profile.cleanDefaults()
            try? FileManager.default.removeItem(at: root)
        }
        let files = [
            profile.storage.applicationSupportDirectory.appendingPathComponent("Enve/PlaybackState/listening_stats.json"),
            profile.storage.applicationSupportDirectory.appendingPathComponent("Enve/ReadingState/reading_stats.json"),
        ]
        let corrupt = Data("corrupt profile statistics".utf8)
        for file in files { try corrupt.write(to: file) }
        #expect(throws: (any Error).self) {
            try ListeningStatsTracker(storage: profile.storage, historyStore: profile.history, historySync: profile.historySync)
        }
        #expect(throws: (any Error).self) {
            try ReadingStatsTracker(storage: profile.storage, historyStore: profile.history, historySync: profile.historySync)
        }
        await profile.listening.addManualListeningTime(seconds: 15)
        await profile.reading.markBookAsFinished(bookId: "same-book")
        await profile.listening.flush()
        await profile.reading.flush()
        for file in files { #expect(try Data(contentsOf: file) == corrupt) }
    }

    private struct Fixture {
        let storage: ProfileStorageLocations
        let defaults: UserDefaults
        let bookStore: BookStoreManager
        let history: HistorySessionStore
        let historySync: ProviderHistorySessionSync
        let listening: ListeningStatsTracker
        let reading: ReadingStatsTracker

        func cleanDefaults() {
            defaults.removePersistentDomain(forName: storage.preferencesDomain!)
        }
    }

    private func fixture(root: URL) throws -> Fixture {
        let storage = ProfileStorageLocations(
            profileID: UUID().uuidString,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"),
            legacyPlaybackStoreURL: root.appendingPathComponent("default.store")
        )
        let defaults = try storage.openPreferences()
        let books = try BookStoreManager(storage: storage, defaults: defaults)
        let history = try HistorySessionStore(directory: storage.historyDirectory)
        let providers = ProfileStatsProviderResolver()
        let crossProviderSync = CrossProviderHistorySessionSync(
            defaults: defaults, bookQuerying: books.repository, providerResolver: providers,
            historyStore: history, listeningStore: ABSLocalListeningStore(defaults: defaults)
        )
        let historySync = ProviderHistorySessionSync(
            defaults: defaults, bookQuerying: books.repository, providerResolver: providers,
            historyStore: history, crossProviderSync: crossProviderSync
        )
        return Fixture(
            storage: storage, defaults: defaults, bookStore: books, history: history, historySync: historySync,
            listening: try ListeningStatsTracker(storage: storage, historyStore: history, historySync: historySync),
            reading: try ReadingStatsTracker(storage: storage, historyStore: history, historySync: historySync)
        )
    }

    private func session(seconds: Int, mediaType: String) -> HistorySession {
        HistorySession(
            id: "same-remote-session", bookId: "same-book", mediaType: mediaType,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_000 + Double(seconds)),
            durationSeconds: seconds, startProgress: 0, endProgress: 0.5, progressDelta: 0.5,
            startLocation: nil, endLocation: nil, pagesRead: nil, source: .bookOrbit
        )
    }
}
