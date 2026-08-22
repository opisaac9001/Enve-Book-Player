import Foundation
import Logging

private struct AudibleMetadata: Decodable {
    let ChapterInfo: AudibleChapterInfo?
}

private struct AudibleChapterInfo: Decodable {
    let chapters: [AudibleChapter]?
}

private struct AudibleChapter: Decodable {
    let length_ms: Int
    let start_offset_ms: Int
    let title: String
}

private struct GenericSidecarMetadata: Decodable {
    let chapters: [GenericChapter]?
}

private struct GenericChapter: Decodable {
    let title: String
    let startTime: Double
    let endTime: Double?
    let duration: Double?
}

@Observable
final class DetailChapterFetcher {
    private(set) var isFetching = false

    func fetch(book: Book, library: LibraryEngine) async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        AppLogger.network.info(
            "[Chapters] Manual fetch started for \(book.title) source=\(book.source.rawValue) existing=\(book.chapters?.count ?? 0)"
        )

        if let cached = ReaderArtifactsStore.shared.loadCachedChapters(bookId: book.stableId)
            ?? ReaderArtifactsStore.shared.loadCachedChapters(bookId: book.id),
            hasAdequateChapters(cached, for: book)
        {
            AppLogger.network.info("[Chapters] Using adequate cached chapters: \(cached.count)")
            apply(cached, to: book, library: library)
            return
        }

        if book.mediaType == .ebook {
            if let result = await deriveEbookChapters(book: book, library: library) {
                apply(result.chapters, to: result.book, library: library)
            }
            return
        }

        if book.source == .local {
            if let newChapters = await deriveLocalChapters(book: book), !newChapters.isEmpty {
                apply(newChapters, to: book, library: library)
            }
            return
        }

        if book.source == .storyteller,
            let provider = library.provider(for: book) as? StorytellerProvider
        {
            if let chapters = try? await provider.fetchManifestChapters(for: book), !chapters.isEmpty {
                apply(chapters, to: book, library: library)
                return
            }

            if let session = try? await provider.startPlaybackSession(for: book) {
                if !session.chapters.isEmpty {
                    apply(session.chapters, to: book, library: library)
                    return
                }

                if let trackURL = session.audioTracks.first.flatMap({ URL(string: $0.contentUrl) }),
                    let embedded = await MetadataLayeringManager.shared.extractEmbeddedChapters(
                        from: trackURL,
                        headers: provider.getStreamingHeaders()
                    ),
                    !embedded.isEmpty
                {
                    apply(embedded, to: book, library: library)
                    return
                }

                let synthesized = trackBasedChapters(from: session.audioTracks)
                if !synthesized.isEmpty {
                    apply(synthesized, to: book, library: library)
                    return
                }
            }
        }

        if book.source == .audiobookshelf,
            let provider = library.provider(for: book)
        {
            let refreshed = (try? await provider.fetchFullBookDetails(bookId: book.id, libraryId: book.libraryId)) ?? book

            if let chapters = refreshed.chapters, hasAdequateChapters(chapters, for: refreshed) {
                AppLogger.network.info("[Chapters] Using adequate Audiobookshelf chapters: \(chapters.count)")
                apply(chapters, to: book, library: library)
                return
            }

            if let extracted = await MetadataLayeringManager.shared.extractChapters(for: refreshed), !extracted.isEmpty {
                apply(extracted, to: book, library: library)
                return
            }
        }

        let refreshed = await library.refreshDetails(for: book)

        if let serverChapters = refreshed.chapters, hasAdequateChapters(serverChapters, for: refreshed) {
            AppLogger.network.info("[Chapters] Using adequate server chapters: \(serverChapters.count)")
            apply(serverChapters, to: refreshed, library: library)
            return
        }
        AppLogger.network.info("[Chapters] Server/cache chapters inadequate; attempting embedded extraction")
        if let extracted = await MetadataLayeringManager.shared.extractChapters(for: refreshed), !extracted.isEmpty {
            apply(extracted, to: refreshed, library: library)
            AppLogger.network.info("[Chapters] Applied embedded chapters: \(extracted.count)")
        } else {
            AppLogger.network.debug(
                "[Chapters] No embedded chapters found bookId=\(DiagnosticLogSanitizer.identifier(for: refreshed.stableId))"
            )
        }
    }

    private func deriveEbookChapters(book: Book, library: LibraryEngine) async -> (book: Book, chapters: [Chapter])? {
        let refreshed: Book
        if book.source != .local {
            refreshed = await library.refreshDetails(for: book)
        } else {
            refreshed = book
        }

        if let serverChapters = refreshed.chapters, !serverChapters.isEmpty {
            return (refreshed, serverChapters)
        }

        if let extracted = await EbookChapterSyncService.shared.extractEbookChapters(for: refreshed), !extracted.isEmpty {
            return (refreshed, extracted)
        }

        return nil
    }

    private func deriveLocalChapters(book: Book) async -> [Chapter]? {
        if let audioPath = book.filePath {
            let fileURL = URL(fileURLWithPath: audioPath)
            let sidecarURL = fileURL.deletingPathExtension().appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: sidecarURL.path),
                let data = try? Data(contentsOf: sidecarURL)
            {
                let decoder = JSONDecoder()

                if let audible = try? decoder.decode(AudibleMetadata.self, from: data),
                    let audibleChapters = audible.ChapterInfo?.chapters,
                    !audibleChapters.isEmpty
                {
                    return audibleChapters.enumerated().map { idx, chapter -> Chapter in
                        let start = Double(chapter.start_offset_ms) / 1000
                        let length = Double(chapter.length_ms) / 1000
                        return Chapter(id: "ch-\(idx)", start: start, end: start + length, title: chapter.title, index: idx)
                    }
                }

                if let generic = try? decoder.decode(GenericSidecarMetadata.self, from: data),
                    let sidecarChapters = generic.chapters,
                    !sidecarChapters.isEmpty
                {
                    return sidecarChapters.enumerated().map { idx, chapter in
                        Chapter(
                            id: "ch-\(idx)",
                            start: chapter.startTime,
                            end: chapter.endTime ?? (chapter.startTime + (chapter.duration ?? 0)),
                            title: chapter.title,
                            index: idx
                        )
                    }
                }
            }
        }

        return await MetadataLayeringManager.shared.extractChapters(for: book)
    }

    private func trackBasedChapters(from tracks: [AudioTrackInfo]) -> [Chapter] {
        guard tracks.count > 1 else { return [] }
        var offset: TimeInterval = 0
        return tracks.enumerated().compactMap { index, track in
            let start = track.startOffset > 0 ? track.startOffset : offset
            let end = start + max(track.duration, 0)
            offset = end
            guard end > start else { return nil }
            return Chapter(
                id: "storyteller_track_\(track.index)",
                start: start,
                end: end,
                title: track.title ?? "Track \(index + 1)",
                index: index
            )
        }
    }

    private func apply(_ chapters: [Chapter], to book: Book, library: LibraryEngine) {
        ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.stableId, chapters: chapters)
        if book.id != book.stableId {
            ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.id, chapters: chapters)
        }
        library.applyCurrentBookChapters(chapters, for: book)
    }

    private func hasAdequateChapters(_ chapters: [Chapter], for book: Book) -> Bool {
        guard !chapters.isEmpty else { return false }
        if chapters.count > 1 { return true }
        let duration = book.duration ?? chapters.first?.end ?? 0
        return duration > 0 && duration <= 1_800
    }
}
