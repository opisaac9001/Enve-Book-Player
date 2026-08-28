import Foundation
import Logging

struct MatchesAudiobookshelfSearchPayload {
    let backend: BackendConfig
    let hits: [AudibleSearchResult]
}

struct MatchesPreviewStream {
    let url: URL
    let headers: [String: String]
}

struct PendingMatchPreparedMetadata {
    let fileMetadata: FileMetadataLayer
    let initialQuery: String
}

struct MatchesManualMetadataEditValues {
    let title: String
    let author: String
    let narrator: String
    let series: String
    let seriesNumber: String
    let details: String
    let publisher: String
    let genres: String
}

@MainActor
@Observable
final class MatchesEngine {
    private(set) var orphanedBooks: [Book] = []

    private let appState: AppState
    private let recovery: LibraryRecoveryCoordinator

    init(appState: AppState = .shared, recovery: LibraryRecoveryCoordinator = .shared) {
        self.appState = appState
        self.recovery = recovery
    }

    func refreshOrphanedBooks() {
        orphanedBooks = appState.presentation.orphanedBooks
    }

    func dismissAllOrphanedBooks() {
        for book in orphanedBooks {
            recovery.dismissOrphanedBook(book)
        }
        refreshOrphanedBooks()
    }

    func dismissOrphanedBook(_ book: Book) {
        recovery.dismissOrphanedBook(book)
        refreshOrphanedBooks()
    }

    func deleteOrphanedBook(_ book: Book) {
        recovery.deleteOrphanedBook(book)
        refreshOrphanedBooks()
    }

    func matchOrphanedBook(_ orphan: Book, to serverBook: Book) {
        recovery.matchRescuedBook(orphan, to: serverBook)
        refreshOrphanedBooks()
    }

    func matchableServerBooks(for orphan: Book, query: String, limit: Int = 100) async -> [Book] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = if trimmedQuery.isEmpty {
            await appState.bookStore.pagedBooks(offset: 0, limit: limit, mediaType: nil)
        } else {
            await appState.bookStore.searchBooks(query: trimmedQuery, limit: limit)
        }
        return all.filter {
            $0.libraryId != "rescued-downloads"
                && $0.source != .local
                && $0.uniqueId != orphan.uniqueId
        }
    }

    func localPreviewFiles(for orphan: Book) -> [URL] {
        let keys = [orphan.partKey, orphan.downloadKey, orphan.id].compactMap { $0 }
        let storage = LocalStorageManager.shared
        for key in keys {
            if let files = storage.localAudiobookFilesIfExists(bookId: key), !files.isEmpty {
                return files
            }
        }
        return []
    }

    func searchAudiobookshelfMetadata(title: String, author: String?, limit: Int) async throws -> MatchesAudiobookshelfSearchPayload? {
        guard let backend = audiobookshelfBackend() else { return nil }
        let hits = try await AudiobookshelfService.shared.searchMetadata(
            title: title,
            author: author,
            backend: backend,
            provider: "audible",
            limit: limit
        )
        return MatchesAudiobookshelfSearchPayload(backend: backend, hits: hits)
    }

    func applyMetadataLayer(_ layer: Any, to book: Book) async {
        let previous = book
        await persistMetadataLayer(layer, bookIds: Array(Set([book.id, book.stableId])))
        let enriched = await MetadataManager.shared.enrichBookWithStoredMetadata(book)

        if previous.coverURL?.absoluteString != enriched.coverURL?.absoluteString {
            await AppCache.shared.removeCoverData(for: previous)
            DiskImageCache.shared.removeImage(for: previous.coverURL)
            DiskImageCache.shared.removeImage(for: enriched.coverURL)
            try? FileManager.default.removeItem(at: LocalStorageManager.shared.coverOverridePath(for: previous.downloadKey))
        }

        appState.updateBookWithMetadata(enriched)
        if appState.currentBook?.uniqueId == book.uniqueId {
            appState.currentBook = enriched
        }
    }

    func metadata(for book: Book) async -> BookMetadata? {
        if let byId = try? await MetadataStorage.shared.loadMetadata(bookId: book.id) {
            return byId
        }
        return try? await MetadataStorage.shared.loadMetadata(bookId: book.stableId)
    }

    func saveManualMetadataEdits(for book: Book, values: MatchesManualMetadataEditValues) async throws {
        let trimmedTitle = values.title.trimmingCharacters(in: .whitespaces)
        let trimmedSequence = values.seriesNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let genresArray = values.genres
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var overrides = UserOverridesLayer()
        if trimmedTitle != book.title { overrides.customTitle = trimmedTitle }
        if values.author.nilIfEmptyMatchesEngine != book.author { overrides.customAuthor = values.author.nilIfEmptyMatchesEngine }
        if values.narrator.nilIfEmptyMatchesEngine != book.narrator { overrides.customNarrator = values.narrator.nilIfEmptyMatchesEngine }
        if values.series.nilIfEmptyMatchesEngine != book.series { overrides.customSeries = values.series.nilIfEmptyMatchesEngine }
        if trimmedSequence != (book.seriesSequence ?? book.seriesNumber.map(String.init) ?? "") {
            overrides.customSeriesSequence = trimmedSequence.isEmpty ? nil : trimmedSequence
            overrides.customSeriesNumber = Int(trimmedSequence)
        }
        if values.details.nilIfEmptyMatchesEngine != book.description {
            overrides.customDescription = values.details.nilIfEmptyMatchesEngine
        }
        if values.publisher.nilIfEmptyMatchesEngine != book.publisher {
            overrides.customPublisher = values.publisher.nilIfEmptyMatchesEngine
        }
        if (genresArray.isEmpty ? nil : genresArray) != book.genres {
            overrides.customGenres = genresArray.isEmpty ? nil : genresArray
        }

        let existing = await metadata(for: book)
        let merged = matchesMergeOverrides(existing: existing?.userOverrides, new: overrides)
        for metadataID in Array(Set([book.id, book.stableId])) {
            try await MetadataStorage.shared.updateUserOverrides(bookId: metadataID, overrides: merged)
        }

        var updated = book
        updated.title = trimmedTitle
        updated.author = values.author.nilIfEmptyMatchesEngine
        updated.narrator = values.narrator.nilIfEmptyMatchesEngine
        updated.series = values.series.nilIfEmptyMatchesEngine
        updated.seriesSequence = trimmedSequence.isEmpty ? nil : trimmedSequence
        updated.seriesNumber = Int(trimmedSequence)
        updated.description = values.details.nilIfEmptyMatchesEngine
        updated.publisher = values.publisher.nilIfEmptyMatchesEngine
        updated.genres = genresArray.isEmpty ? nil : genresArray

        let enriched = await MetadataManager.shared.enrichBookWithStoredMetadata(updated)
        appState.updateBookWithMetadata(enriched)
        if appState.currentBook?.uniqueId == book.uniqueId {
            appState.currentBook = enriched
        }
    }

    func pendingMatches() -> [MatchQueueEntry] {
        migratePendingMatchScoreFormat()
        return MatchQueueStorage.shared.getPendingMatches()
    }

    func clearPendingMatches() {
        MatchQueueStorage.shared.clearPendingMatches()
    }

    func preparedMetadata(for entry: MatchQueueEntry) -> PendingMatchPreparedMetadata {
        var meta = entry.fileMetadata
        if meta.fileName == nil || meta.folderName == nil, let path = entry.bookPath {
            let url = URL(fileURLWithPath: path)
            if meta.folderName == nil { meta.folderName = url.deletingLastPathComponent().lastPathComponent }
            if meta.fileName == nil { meta.fileName = url.deletingPathExtension().lastPathComponent }
        }
        if meta.title == nil { meta.title = meta.fileName ?? meta.folderName ?? entry.bookId }
        let initialQuery = meta.fileName ?? meta.folderName ?? meta.title ?? entry.bookId
        return PendingMatchPreparedMetadata(fileMetadata: meta, initialQuery: initialQuery)
    }

    func preparedBook(for entry: MatchQueueEntry) -> Book {
        var effectiveBackendId = entry.backendId
        if effectiveBackendId == nil {
            let parts = entry.bookId.split(separator: ":")
            if parts.count == 3 {
                effectiveBackendId = String(parts[1])
            }
        }

        var source: Book.BookSource = entry.source ?? .plex
        if let backendId = effectiveBackendId,
            let backend = appState.providerConnections.backend(id: backendId)
        {
            switch backend.type {
            case .audiobookshelf: source = .audiobookshelf
            case .jellyfin: source = .jellyfin
            case .emby: source = .emby
            case .plex: source = .plex
            case .storyteller: source = .storyteller
            }
        }

        let meta = preparedMetadata(for: entry).fileMetadata
        return Book(
            id: entry.bookId,
            ratingKey: entry.ratingKey ?? entry.bookId,
            title: meta.title ?? entry.bookId,
            author: meta.author,
            narrator: meta.narrator,
            thumb: entry.bookCoverUrl,
            partKey: entry.partKey,
            duration: meta.duration,
            source: source,
            backendId: effectiveBackendId,
            trackIndex: entry.trackIndex,
            filePath: entry.bookPath,
            series: meta.series,
            seriesNumber: meta.seriesNumber,
            publishedYear: meta.year,
            genres: meta.genres,
            publisher: meta.publisher,
            isbn: meta.isbn,
            asin: meta.asin
        )
    }

    func applyPendingMatchLayer(_ layer: Any, entry: MatchQueueEntry) async -> Bool {
        let result: Result<BookMetadata, Error>? = await withCheckedContinuation { continuation in
            if let itunes = layer as? iTunesMetadataLayer {
                MetadataManager.shared.updateiTunesMetadata(bookId: entry.bookId, iTunes: itunes) { continuation.resume(returning: $0) }
            } else if let audible = layer as? AudibleMetadataLayer {
                MetadataManager.shared.updateAudibleMetadata(bookId: entry.bookId, audible: audible) { continuation.resume(returning: $0) }
            } else if let google = layer as? GoogleBooksMetadataLayer {
                MetadataManager.shared.updateGoogleBooksMetadata(bookId: entry.bookId, google: google) {
                    continuation.resume(returning: $0)
                }
            } else if let openLibrary = layer as? OpenLibraryMetadataLayer {
                MetadataManager.shared.updateOpenLibraryMetadata(bookId: entry.bookId, openLibrary: openLibrary) {
                    continuation.resume(returning: $0)
                }
            } else if let enve = layer as? EnveMetadataLayer {
                MetadataManager.shared.updateEnveMetadata(bookId: entry.bookId, enve: enve) { continuation.resume(returning: $0) }
            } else {
                continuation.resume(returning: nil)
            }
        }

        guard case .success = result else { return false }
        MatchQueueStorage.shared.removeMatchQueueEntry(entryId: entry.id)
        await appState.refreshBookAfterMetadataUpdate(bookId: entry.bookId)
        return true
    }

    func previewStream(for book: Book, audiobookshelfBackend: BackendConfig?) async throws -> MatchesPreviewStream? {
        let backendOverride = book.source == .audiobookshelf ? audiobookshelfBackend : nil
        let url: URL
        do {
            if let resolved = try await PlayerViewModel.shared.resolveStreamURL(for: book, backendOverride: backendOverride) {
                url = resolved
            } else if let fallback = try await previewFallbackURL(for: book) {
                url = fallback
            } else {
                return nil
            }
        } catch {
            if let fallback = try await previewFallbackURL(for: book) {
                url = fallback
            } else {
                throw error
            }
        }

        if book.source == .audiobookshelf {
            let backend = audiobookshelfBackend
                ?? appState.providerConnections.backend(
                    id: book.backendId ?? book.providerId.uuidString
                )
            if let token = backend?.token, !token.isEmpty {
                return MatchesPreviewStream(url: url, headers: ["Authorization": "Bearer \(token)"])
            }
            return MatchesPreviewStream(url: url, headers: [:])
        }

        let headers = appState.providerConnections.capability(PlaybackSessionProvider.self, for: book)?
            .getStreamingHeaders() ?? [:]
        return MatchesPreviewStream(url: url, headers: headers)
    }

    private func previewFallbackURL(for book: Book) async throws -> URL? {
        guard let provider = appState.providerConnections.capability(PlaybackSessionProvider.self, for: book) else {
            return nil
        }
        let session = try await provider.startPlaybackSession(for: book)
        if let firstTrack = session.audioTracks.first, let trackURL = URL(string: firstTrack.contentUrl) {
            return trackURL
        }
        return provider.getAudioURL(for: book)
    }

    private func persistMetadataLayer(_ layer: Any, bookIds: [String]) async {
        for bookId in bookIds {
            do {
                if let itunes = layer as? iTunesMetadataLayer {
                    try await MetadataStorage.shared.updateLayer(bookId: bookId, layer: .iTunes) { $0.iTunes = itunes }
                } else if let audible = layer as? AudibleMetadataLayer {
                    try await MetadataStorage.shared.updateLayer(bookId: bookId, layer: .audible) { $0.audible = audible }
                } else if let enve = layer as? EnveMetadataLayer {
                    try await MetadataStorage.shared.updateLayer(bookId: bookId, layer: .enve) { $0.enve = enve }
                } else if let google = layer as? GoogleBooksMetadataLayer {
                    try await MetadataStorage.shared.updateLayer(bookId: bookId, layer: .googleBooks) { $0.googleBooks = google }
                } else if let openLibrary = layer as? OpenLibraryMetadataLayer {
                    let existing = try await MetadataStorage.shared.loadMetadata(bookId: bookId)?.userOverrides
                    let merged = matchesMergeOverrides(
                        existing: existing,
                        new: UserOverridesLayer(
                            customTitle: openLibrary.title,
                            customAuthor: openLibrary.authors?.first,
                            customSeries: openLibrary.seriesName,
                            customSeriesNumber: openLibrary.seriesNumber,
                            customSeriesSequence: openLibrary.seriesSequence,
                            customCoverPath: openLibrary.coverUrl,
                            customDescription: openLibrary.description.map(matchesStripHTML),
                            customPublisher: openLibrary.publisher,
                            customGenres: openLibrary.subjects
                        )
                    )
                    try await MetadataStorage.shared.updateUserOverrides(bookId: bookId, overrides: merged)
                } else if let comicVine = layer as? ComicVineMetadataLayer {
                    let existing = try await MetadataStorage.shared.loadMetadata(bookId: bookId)?.userOverrides
                    let merged = matchesMergeOverrides(
                        existing: existing,
                        new: UserOverridesLayer(
                            customTitle: comicVine.title,
                            customAuthor: comicVine.authors.first,
                            customCoverPath: comicVine.coverUrl,
                            customDescription: comicVine.description.map(matchesStripHTML),
                            customPublisher: comicVine.publisher
                        )
                    )
                    try await MetadataStorage.shared.updateUserOverrides(bookId: bookId, overrides: merged)
                }
                NotificationCenter.default.post(name: .metadataUpdated, object: bookId)
            } catch {
                AppLogger.general.error("Failed to persist metadata layer: \(error)")
            }
        }
    }

    private func migratePendingMatchScoreFormat() {
        let queue = MatchQueueStorage.shared.readMatchQueue()
        var needsUpdate = false
        let updated = queue.entries.map { entry -> MatchQueueEntry in
            guard entry.matchCandidates.contains(where: { $0.confidence > 1.0 }) else { return entry }
            needsUpdate = true
            let candidates = entry.matchCandidates.map { candidate -> AudibleMatchCandidate in
                guard candidate.confidence > 1.0 else { return candidate }
                return AudibleMatchCandidate(
                    id: candidate.asin,
                    asin: candidate.asin,
                    title: candidate.title,
                    author: candidate.author,
                    narrators: candidate.narrators,
                    series: candidate.series,
                    seriesNumber: candidate.seriesNumber,
                    duration: candidate.duration,
                    confidence: candidate.confidence / 100.0,
                    matchReason: candidate.matchReason,
                    coverUrl: candidate.coverUrl,
                    matchSource: candidate.matchSource,
                    description: candidate.description,
                    durationScore: candidate.durationScore,
                    titleScore: candidate.titleScore,
                    authorScore: candidate.authorScore
                )
            }
            return MatchQueueEntry(
                id: entry.id,
                bookId: entry.bookId,
                bookPath: entry.bookPath,
                ratingKey: entry.ratingKey,
                partKey: entry.partKey,
                source: entry.source,
                backendId: entry.backendId,
                trackIndex: entry.trackIndex,
                fileMetadata: entry.fileMetadata,
                matchCandidates: candidates,
                selectedMatch: entry.selectedMatch,
                status: entry.status,
                createdAt: entry.createdAt,
                reviewedAt: entry.reviewedAt,
                bookCoverUrl: entry.bookCoverUrl
            )
        }
        if needsUpdate {
            MatchQueueStorage.shared.writeMatchQueue(
                MatchQueue(
                    entries: updated,
                    version: queue.version,
                    lastUpdated: ISO8601DateFormatter().string(from: Date())
                )
            )
        }
    }

    private func audiobookshelfBackend() -> BackendConfig? {
        let connections = appState.providerConnections.connections.filter { $0.type == .audiobookshelf }
        func isSample(_ connection: ServerConnection) -> Bool {
            connection.url.lowercased().contains("example.com")
        }
        let candidates = connections.filter { !isSample($0) }
        let authenticated = candidates.filter { !($0.token?.isEmpty ?? true) }
        guard let connection = authenticated.first ?? candidates.first ?? connections.first else { return nil }
        return BackendConfig(
            id: connection.id.uuidString,
            name: connection.name,
            type: .audiobookshelf,
            url: connection.url,
            token: connection.token,
            enabled: true,
            username: connection.username,
            password: nil,
            userId: nil,
            selectedLibraryIds: connection.selectedLibraryIds
        )
    }
}

private extension String {
    var nilIfEmptyMatchesEngine: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
