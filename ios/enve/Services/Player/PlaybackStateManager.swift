import Foundation
import Logging
import SwiftData

@MainActor
final class PlaybackStateManager {
    static let shared = PlaybackStateManager()

    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?

    private init() {
        initializeModelContainer()
    }

    private func initializeModelContainer() {
        do {
            let schema = Schema([
                PlaybackState.self,
                AudiobookBookmark.self,
                MetadataOverride.self,
                SyncedPlaybackState.self,
            ])
            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            modelContainer = container
            modelContext = ModelContext(container)
            AppLogger.player.info("PlaybackState model container initialized")
        } catch {
            AppLogger.player.error("Failed to initialize model container: \(error)")
        }
    }

    func loadPlaybackState(for bookId: String) throws -> PlaybackState {
        guard let context = modelContext else {
            throw NSError(
                domain: "PlaybackStateManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Model context not initialized"
                ]
            )
        }

        let descriptor = FetchDescriptor<PlaybackState>(
            predicate: #Predicate { $0.bookId == bookId }
        )

        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let newState = PlaybackState(bookId: bookId)
        context.insert(newState)
        try context.save()
        AppLogger.player.info("Created new playback state for: \(bookId)")
        return newState
    }

    func savePlaybackState(
        bookId: String,
        position: TimeInterval,
        speed: Double,
        chapterIndex: Int
    ) throws {
        guard let context = modelContext else {
            throw NSError(
                domain: "PlaybackStateManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Model context not initialized"
                ]
            )
        }

        let state = try loadPlaybackState(for: bookId)
        state.currentPosition = position
        state.playbackSpeed = speed
        state.currentChapterIndex = chapterIndex
        state.lastPlayedDate = Date()

        try context.save()
    }

    func mostRecentlyPlayed() async throws -> (bookId: String, title: String, author: String?) {
        guard let context = modelContext else {
            throw NSError(
                domain: "PlaybackStateManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Model context not initialized"
                ]
            )
        }

        let descriptor = FetchDescriptor<PlaybackState>(
            sortBy: [SortDescriptor(\.lastPlayedDate, order: .reverse)]
        )
        if let recent = try context.fetch(descriptor).first {
            return (bookId: recent.bookId, title: "Continue Listening", author: nil)
        }

        throw NSError(
            domain: "PlaybackStateManager",
            code: -2,
            userInfo: [
                NSLocalizedDescriptionKey: "No playback history found"
            ]
        )
    }

    func getBookmarks(for bookId: String) throws -> [AudiobookBookmark] {
        guard modelContext != nil else {
            throw NSError(
                domain: "PlaybackStateManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Model context not initialized"
                ]
            )
        }

        let state = try loadPlaybackState(for: bookId)
        return state.bookmarks.sorted { $0.timestamp < $1.timestamp }
    }

    func addBookmark(
        bookId: String,
        timestamp: TimeInterval,
        title: String,
        notes: String = ""
    ) throws -> AudiobookBookmark {
        guard let context = modelContext else {
            throw NSError(
                domain: "PlaybackStateManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Model context not initialized"
                ]
            )
        }

        let state = try loadPlaybackState(for: bookId)
        let bookmark = AudiobookBookmark(timestamp: timestamp, title: title, notes: notes)
        state.bookmarks.append(bookmark)
        try context.save()
        AppLogger.player.debug(
            "Bookmark added bookmarkDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: title)) position=\(Int(timestamp))s"
        )
        return bookmark
    }

    func deleteBookmark(_ bookmark: AudiobookBookmark) throws {
        guard let context = modelContext else {
            throw NSError(
                domain: "PlaybackStateManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Model context not initialized"
                ]
            )
        }

        context.delete(bookmark)
        try context.save()
        AppLogger.player.info("Bookmark deleted")
    }

    func updateBookmark(
        _ bookmark: AudiobookBookmark,
        title: String,
        notes: String
    ) throws {
        guard let context = modelContext else {
            throw NSError(
                domain: "PlaybackStateManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Model context not initialized"
                ]
            )
        }

        bookmark.title = title
        bookmark.notes = notes
        try context.save()
    }

    func loadMetadataOverride(for bookId: String) throws -> MetadataOverride {
        guard let context = modelContext else {
            throw NSError(
                domain: "PlaybackStateManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Model context not initialized"
                ]
            )
        }

        let descriptor = FetchDescriptor<MetadataOverride>(
            predicate: #Predicate { $0.bookId == bookId }
        )

        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let newOverride = MetadataOverride(bookId: bookId)
        context.insert(newOverride)
        try context.save()
        return newOverride
    }

    func saveMetadataOverride(
        bookId: String,
        title: String?,
        author: String?,
        narrator: String?,
        description: String?,
        series: String?,
        seriesNumber: Int?,
        genres: [String],
        notes: String
    ) throws {
        guard let context = modelContext else {
            throw NSError(
                domain: "PlaybackStateManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Model context not initialized"
                ]
            )
        }

        let override = try loadMetadataOverride(for: bookId)
        override.customTitle = title
        override.customAuthor = author
        override.customNarrator = narrator
        override.customDescription = description
        override.customSeries = series
        override.customSeriesNumber = seriesNumber
        override.customGenres = genres
        override.customNotes = notes
        override.lastModified = Date()

        try context.save()
        AppLogger.player.info("Metadata override saved for: \(bookId)")
    }

    func deleteMetadataOverride(for bookId: String) throws {
        guard let context = modelContext else {
            throw NSError(
                domain: "PlaybackStateManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Model context not initialized"
                ]
            )
        }

        let descriptor = FetchDescriptor<MetadataOverride>(
            predicate: #Predicate { $0.bookId == bookId }
        )

        if let override = try context.fetch(descriptor).first {
            context.delete(override)
            try context.save()
        }
    }

    func saveSyncedPlaybackState(
        bookId: String,
        deviceId: String,
        position: TimeInterval,
        speed: Double,
        chapterIndex: Int,
        lastPlayedDate: Date?
    ) throws {
        guard let context = modelContext else {
            throw NSError(
                domain: "PlaybackStateManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Model context not initialized"
                ]
            )
        }

        let descriptor = FetchDescriptor<SyncedPlaybackState>(
            predicate: #Predicate { $0.bookId == bookId && $0.deviceId == deviceId }
        )

        if let existing = try context.fetch(descriptor).first {
            existing.currentPosition = position
            existing.playbackSpeed = speed
            existing.currentChapterIndex = chapterIndex
            existing.lastPlayedDate = lastPlayedDate
            existing.lastSyncDate = Date()
        } else {
            let synced = SyncedPlaybackState(
                bookId: bookId,
                deviceId: deviceId,
                currentPosition: position,
                playbackSpeed: speed,
                currentChapterIndex: chapterIndex,
                lastPlayedDate: lastPlayedDate
            )
            context.insert(synced)
        }

        try context.save()
    }

    func getSyncedStates(for bookId: String) throws -> [SyncedPlaybackState] {
        guard let context = modelContext else {
            throw NSError(
                domain: "PlaybackStateManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Model context not initialized"
                ]
            )
        }

        let descriptor = FetchDescriptor<SyncedPlaybackState>(
            predicate: #Predicate { $0.bookId == bookId }
        )
        return try context.fetch(descriptor)
    }

    func deleteAllState(for bookId: String) throws {
        guard let context = modelContext else {
            throw NSError(
                domain: "PlaybackStateManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Model context not initialized"
                ]
            )
        }

        let playbackDescriptor = FetchDescriptor<PlaybackState>(
            predicate: #Predicate { $0.bookId == bookId }
        )
        if let state = try context.fetch(playbackDescriptor).first {
            context.delete(state)
        }

        let metadataDescriptor = FetchDescriptor<MetadataOverride>(
            predicate: #Predicate { $0.bookId == bookId }
        )
        if let override = try context.fetch(metadataDescriptor).first {
            context.delete(override)
        }

        let syncedDescriptor = FetchDescriptor<SyncedPlaybackState>(
            predicate: #Predicate { $0.bookId == bookId }
        )
        for synced in try context.fetch(syncedDescriptor) {
            context.delete(synced)
        }

        try context.save()
        AppLogger.player.info("All state deleted for: \(bookId)")
    }

    func clearAllData() throws {
        guard let context = modelContext else {
            throw NSError(
                domain: "PlaybackStateManager",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Model context not initialized"
                ]
            )
        }

        try context.delete(model: PlaybackState.self)
        try context.delete(model: AudiobookBookmark.self)
        try context.delete(model: MetadataOverride.self)
        try context.delete(model: SyncedPlaybackState.self)
        try context.save()
        AppLogger.player.info("All playback state data cleared")
    }
}
