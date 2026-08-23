import AVFoundation
import Foundation
import Logging

enum AudiobookPlaybackPolicy {
    static func chaptersNeedRefresh(for book: Book) -> Bool {
        guard let chapters = book.chapters, !chapters.isEmpty else { return true }
        guard let duration = book.duration, duration > 0 else { return true }
        if Set(chapters.map(\.id)).count != chapters.count { return true }
        if chapters.contains(where: { $0.end <= $0.start }) { return true }
        return chapters.count == 1 && duration > 1_800
    }

    static func chaptersAreInadequateForExtraction(_ book: Book) -> Bool {
        guard let duration = book.duration, duration > 1_800 else { return false }
        return (book.chapters?.count ?? 0) <= 1
    }
}

@MainActor
protocol BookPlaybackStarting: AnyObject {
    func play(_ book: Book, presentPlayer: Bool)
}

@MainActor
final class AudiobookPlaybackCoordinator: BookPlaybackStarting {
    static let shared = AudiobookPlaybackCoordinator()

    private let appState: AppState
    private let playback: PlaybackManager

    init(
        appState: AppState = .shared,
        playback: PlaybackManager = .shared
    ) {
        self.appState = appState
        self.playback = playback
    }

    func play(_ book: Book, presentPlayer: Bool = true) {
        AppLogger.player.debug(
            "Starting playback source=\(book.source) bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
        )

        if book.hasEPUB3MediaOverlay {
            AlignedReadAloudSessionCoordinator.shared.play(book, presentPlayer: presentPlayer)
            return
        }

        if book.mediaType == .ebook {
            LastOpenedBookStore.shared.record(book)
            appState.presentation.selectedEbookForDetail = book
            return
        }

        if book.isPodcastEpisode,
            let partKey = book.partKey,
            let directURL = URL(string: partKey),
            directURL.scheme?.hasPrefix("http") == true,
            !LocalStorageManager.shared.isAudiobookDownloaded(book)
        {
            LastOpenedBookStore.shared.record(book)
            appState.currentBook = book
            appState.presentation.isPlayerPresented = presentPlayer
            playback.playDirectURL(book, url: directURL)
            return
        }

        let isDownloaded = LocalStorageManager.shared.isAudiobookDownloaded(book)
        let localPlaybackIssue =
            isDownloaded
            ? LocalStorageManager.shared.unsupportedLocalPlaybackReason(for: book)
            : nil

        if !isDownloaded, book.audioTracks?.first?.format?.lowercased() == "zip" {
            appState.presentation.zipFileAlertBook = book
            return
        }

        let isLocalPlayable =
            (isDownloaded && localPlaybackIssue == nil)
            || book.source == .smb
            || (book.source == .local && !(book.isPodcastEpisode && !isDownloaded))

        if isLocalPlayable {
            playLocal(book, presentPlayer: presentPlayer)
            return
        }

        guard let provider = appState.providerConnections[book.providerId],
            let playbackProvider = provider as? any PlaybackSessionProvider
        else {
            if let localPlaybackIssue {
                appState.presentation.userFacingError = UserFacingError(
                    title: "Downloaded File Unsupported",
                    message: "\"\(book.title)\" was downloaded in a format Enve cannot play locally yet. \(localPlaybackIssue)"
                )
            }
            AppLogger.player.warning(
                "No playback provider bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
            return
        }

        LastOpenedBookStore.shared.record(book)
        appState.currentBook = book
        appState.presentation.isPlayerPresented = presentPlayer
        playRemote(book, catalogProvider: provider, playbackProvider: playbackProvider)
    }

    private func playLocal(_ book: Book, presentPlayer: Bool) {
        LastOpenedBookStore.shared.record(book)
        appState.currentBook = book
        appState.presentation.isPlayerPresented = presentPlayer

        Task { @MainActor in
            let enrichedBook = await MetadataManager.shared.enrichBookWithStoredMetadata(book)
            appState.currentBook = enrichedBook
            _ = appState.libraryCache.replaceExisting(enrichedBook)
            playback.playLocalBook(enrichedBook)
        }
    }

    private func playRemote(
        _ book: Book,
        catalogProvider: any LibraryProvider,
        playbackProvider: any PlaybackSessionProvider
    ) {
        Task { @MainActor in
            let freshestCachedBook = appState.libraryCache.book(uniqueId: book.uniqueId) ?? book
            var bookToPlay = freshestCachedBook

            if NetworkPolicyService.shared.isConnected {
                do {
                    let fetchedBook =
                        if AudiobookPlaybackPolicy.chaptersNeedRefresh(for: freshestCachedBook) {
                            try await catalogProvider.fetchFullBookDetails(
                                bookId: freshestCachedBook.id,
                                libraryId: freshestCachedBook.libraryId
                            )
                        } else {
                            freshestCachedBook
                        }

                    var finalBook = fetchedBook
                    if AudiobookPlaybackPolicy.chaptersAreInadequateForExtraction(finalBook),
                        let localURL = LocalStorageManager.shared.localAudiobookFileURLIfExists(
                            bookId: finalBook.downloadKey
                        ),
                        let embedded = await extractEmbeddedChapters(
                            from: localURL,
                            bookDuration: finalBook.duration ?? 0
                        )
                    {
                        finalBook.chapters = embedded
                    }

                    let hasLinkedEbook = appState.allBooks.contains {
                        $0.mediaType == .ebook
                            && $0.linkedAudiobookStableId == freshestCachedBook.stableId
                    }
                    if !hasLinkedEbook {
                        await ChapterMetadataCache.cache(finalBook)
                    }

                    bookToPlay = await MetadataManager.shared.enrichBookWithStoredMetadata(finalBook)
                    if hasLinkedEbook,
                        let renamed = ReaderArtifactsStore.shared.loadCachedChapters(bookId: bookToPlay.stableId)
                            ?? ReaderArtifactsStore.shared.loadCachedChapters(bookId: bookToPlay.id),
                        !renamed.isEmpty
                    {
                        bookToPlay.chapters = renamed
                    }
                } catch {
                    AppLogger.player.error(
                        "Playback metadata refresh failed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error)"
                    )
                    bookToPlay = await MetadataManager.shared.enrichBookWithStoredMetadata(book)
                    restoreCachedChaptersIfNeeded(to: &bookToPlay)
                }
            } else {
                bookToPlay = await MetadataManager.shared.enrichBookWithStoredMetadata(freshestCachedBook)
                restoreCachedChaptersIfNeeded(to: &bookToPlay)
            }

            appState.currentBook = bookToPlay
            _ = appState.libraryCache.replaceExisting(bookToPlay)

            if !(bookToPlay.chapters?.isEmpty ?? true) {
                await appState.bookStore.upsertBooks([bookToPlay])
            }
            playback.playBook(bookToPlay, provider: playbackProvider)
        }
    }

    private func restoreCachedChaptersIfNeeded(to book: inout Book) {
        guard book.chapters?.isEmpty ?? true else { return }
        guard let cached = ReaderArtifactsStore.shared.loadCachedChapters(bookId: book.stableId)
            ?? ReaderArtifactsStore.shared.loadCachedChapters(bookId: book.id),
            !cached.isEmpty
        else { return }
        book.chapters = cached
    }

    private func extractEmbeddedChapters(
        from url: URL,
        bookDuration: TimeInterval
    ) async -> [Chapter]? {
        let asset = AVURLAsset(url: url)
        do {
            for locale in try await asset.load(.availableChapterLocales) {
                let groups = try await asset.loadChapterMetadataGroups(
                    withTitleLocale: locale,
                    containingItemsWithCommonKeys: [.commonKeyArtwork]
                )
                var extracted: [Chapter] = []
                for (index, group) in groups.enumerated() {
                    let start = CMTimeGetSeconds(group.timeRange.start)
                    let duration = CMTimeGetSeconds(group.timeRange.duration)
                    var title = "Chapter \(index + 1)"
                    if let titleItem = group.items.first(where: { $0.commonKey == .commonKeyTitle }),
                        let value = try? await titleItem.load(.value) as? String
                    {
                        title = value
                    }
                    extracted.append(
                        Chapter(
                            id: String(index),
                            start: start,
                            end: start + duration,
                            title: title,
                            index: index
                        )
                    )
                }
                if !extracted.isEmpty {
                    let sorted = extracted.sorted { $0.start < $1.start }
                    return sorted.enumerated().map { index, chapter in
                        let end =
                            chapter.end > chapter.start
                            ? chapter.end
                            : (index + 1 < sorted.count ? sorted[index + 1].start : bookDuration)
                        return Chapter(
                            id: chapter.id,
                            start: chapter.start,
                            end: end,
                            title: chapter.title,
                            index: index
                        )
                    }
                }
            }
        } catch {
            AppLogger.player.error("Embedded chapter extraction failed: \(error.localizedDescription)")
        }
        return nil
    }
}
