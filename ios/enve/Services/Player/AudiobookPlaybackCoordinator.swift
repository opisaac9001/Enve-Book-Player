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
    static var shared: AudiobookPlaybackCoordinator { ProfileSession.owner.playback.starter }

    private let appState: AppState
    private let playback: PlaybackManager
    private var playTask: Task<Void, Never>?
    private var isRetired = false

    private unowned let profileSession: ProfileSession

    init(
        appState: AppState = .shared,
        playback: PlaybackManager = .shared,
        profileSession: ProfileSession = .owner
    ) {
        self.profileSession = profileSession
        self.appState = appState
        self.playback = playback
    }

    func play(_ book: Book, presentPlayer: Bool = true) {
        guard !isRetired else { return }
        playTask?.cancel()
        AppLogger.player.debug(
            "Starting playback source=\(book.source) bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
        )

        if book.hasEPUB3MediaOverlay {
            profileSession.playback.readAloud.play(book, presentPlayer: presentPlayer)
            return
        }

        if book.mediaType == .ebook {
            profileSession.lastOpened.record(book)
            appState.presentation.selectedEbookForDetail = book
            return
        }

        if book.isPodcastEpisode,
            let partKey = book.partKey,
            let directURL = URL(string: partKey),
            directURL.scheme?.hasPrefix("http") == true,
            !profileSession.localStorage.isAudiobookDownloaded(book)
        {
            profileSession.lastOpened.record(book)
            appState.currentBook = book
            appState.presentation.isPlayerPresented = presentPlayer
            playback.playDirectURL(book, url: directURL)
            return
        }

        let isDownloaded = profileSession.localStorage.isAudiobookDownloaded(book)
        let localPlaybackIssue =
            isDownloaded
            ? profileSession.localStorage.unsupportedLocalPlaybackReason(for: book)
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

        profileSession.lastOpened.record(book)
        appState.currentBook = book
        appState.presentation.isPlayerPresented = presentPlayer
        playRemote(book, catalogProvider: provider, playbackProvider: playbackProvider)
    }

    func retire() async {
        isRetired = true
        playTask?.cancel()
        await playTask?.value
    }

    private func playLocal(_ book: Book, presentPlayer: Bool) {
        profileSession.lastOpened.record(book)
        appState.currentBook = book
        appState.presentation.isPlayerPresented = presentPlayer

        playTask = Task { @MainActor in
            guard !Task.isCancelled, !isRetired else { return }
            var enrichedBook = await profileSession.metadataManager.enrichBookWithStoredMetadata(book)
            restoreCachedChaptersIfNeeded(to: &enrichedBook)
            appState.currentBook = enrichedBook
            _ = appState.libraryCache.replaceExisting(enrichedBook)
            guard !Task.isCancelled, !isRetired else { return }
            playback.playLocalBook(enrichedBook)

            guard AudiobookPlaybackPolicy.chaptersNeedRefresh(for: enrichedBook) else { return }
            let chapterService = profileSession.playback.chapterService
            if await chapterService.refreshChaptersFromServer(for: enrichedBook) { return }
            if let localURL = profileSession.localStorage.localAudiobookFileURLIfExists(bookId: enrichedBook.downloadKey),
                let embedded = await extractEmbeddedChapters(from: localURL, bookDuration: enrichedBook.duration ?? 0)
            {
                chapterService.applyChapters(embedded, for: enrichedBook)
            }
        }
    }

    private func playRemote(
        _ book: Book,
        catalogProvider: any LibraryProvider,
        playbackProvider: any PlaybackSessionProvider
    ) {
        playTask = Task { @MainActor in
            guard !Task.isCancelled, !isRetired else { return }
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
                        let localURL = profileSession.localStorage.localAudiobookFileURLIfExists(
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
                        await ChapterMetadataCache.cache(finalBook, readerArtifacts: profileSession.readerArtifacts,
                            metadataStorage: profileSession.metadataStorage)
                    }

                    bookToPlay = await profileSession.metadataManager.enrichBookWithStoredMetadata(finalBook)
                    if hasLinkedEbook,
                        let renamed = profileSession.readerArtifacts.loadCachedAudioChapters(for: bookToPlay),
                        !renamed.isEmpty
                    {
                        bookToPlay.chapters = renamed
                    }
                } catch {
                    AppLogger.player.error(
                        "Playback metadata refresh failed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error)"
                    )
                    bookToPlay = await profileSession.metadataManager.enrichBookWithStoredMetadata(book)
                    restoreCachedChaptersIfNeeded(to: &bookToPlay)
                }
            } else {
                bookToPlay = await profileSession.metadataManager.enrichBookWithStoredMetadata(freshestCachedBook)
                restoreCachedChaptersIfNeeded(to: &bookToPlay)
            }

            appState.currentBook = bookToPlay
            _ = appState.libraryCache.replaceExisting(bookToPlay)

            if let chapters = bookToPlay.chapters, !chapters.isEmpty {
                await appState.bookStore.upsertBooks([bookToPlay])
                profileSession.playback.composition.bookMetadataUpdater.updateChapters(chapters, for: bookToPlay)
            }
            playback.playBook(bookToPlay, provider: playbackProvider)

            if AudiobookPlaybackPolicy.chaptersNeedRefresh(for: bookToPlay) {
                await profileSession.playback.chapterService.refreshChaptersFromServer(for: bookToPlay)
            }
        }
    }

    private func restoreCachedChaptersIfNeeded(to book: inout Book) {
        guard book.chapters?.isEmpty ?? true else { return }
        guard let cached = profileSession.readerArtifacts.loadCachedAudioChapters(for: book),
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
