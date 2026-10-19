import Foundation
import Logging

extension BookloreProvider {
    func enrichAudiobookIfNeeded(_ baseBook: Book) async -> Book {
        guard baseBook.mediaType == .audiobook else {
            return baseBook
        }

        var enriched = baseBook
        let streamHeaders = getStreamingHeaders()
        var sessionTracks: [AudioTrackInfo] = []

        if let session = try? await startPlaybackSession(for: baseBook) {
            sessionTracks = session.audioTracks
            let trackDuration = session.audioTracks.reduce(0.0) { partial, track in
                partial + max(track.duration, 0)
            }
            let resolvedDuration = max(enriched.duration ?? 0, trackDuration)
            if resolvedDuration > 0 {
                enriched.duration = resolvedDuration
                if enriched.currentTime > resolvedDuration {
                    enriched.currentTime = resolvedDuration
                }
            }

            let normalizedSessionChapters = BookloreBookMapper.normalizeChapters(
                session.chapters,
                bookDuration: enriched.duration ?? resolvedDuration
            )
            if !normalizedSessionChapters.isEmpty {
                enriched.chapters = normalizedSessionChapters
            }

            if BookloreBookMapper.chaptersAreInadequate(enriched.chapters ?? [], bookDuration: enriched.duration ?? resolvedDuration),
                session.audioTracks.count > 1
            {
                let synthesized: [Chapter] = session.audioTracks.enumerated().map { index, track in
                    let start = max(track.startOffset, 0)
                    let end = start + max(track.duration, 0)
                    let title = track.title ?? "Track \(index + 1)"
                    return Chapter(
                        id: "grimmory_track_\(track.index)",
                        start: start,
                        end: end,
                        title: title,
                        index: index
                    )
                }
                if !synthesized.isEmpty {
                    enriched.chapters = BookloreBookMapper.normalizeChapters(synthesized, bookDuration: enriched.duration ?? resolvedDuration)
                }
            }
        }

        if let streamURL = getAudioURL(for: enriched) {
            let chapterDuration = enriched.duration ?? 0
            if sessionTracks.count <= 1,
                BookloreBookMapper.chaptersAreInadequate(enriched.chapters ?? [], bookDuration: chapterDuration),
                let extractedChapters = await metadataLayering.extractEmbeddedChapters(
                    from: streamURL,
                    headers: streamHeaders
                ),
                !extractedChapters.isEmpty
            {
                let bookloreChapters = extractedChapters.enumerated().map { index, chapter in
                    Chapter(
                        id: "grimmory-embedded-\(index)",
                        start: chapter.start,
                        end: chapter.end,
                        title: chapter.title,
                        index: index
                    )
                }
                enriched.chapters = BookloreBookMapper.normalizeChapters(bookloreChapters, bookDuration: chapterDuration)
                AppLogger.network.info("Extracted \(extractedChapters.count) embedded chapters from Grimmory stream")
            }

            let needsMetadataBackfill =
                (enriched.author?.isEmpty ?? true)
                || enriched.author == "Unknown Author"
                || enriched.narrator == nil
                || (enriched.description?.isEmpty ?? true)
                || enriched.series == nil
                || enriched.publisher == nil
                || enriched.publishedYear == nil
                || (enriched.genres?.isEmpty ?? true)
                || (enriched.duration ?? 0) <= 0

            if needsMetadataBackfill,
                sessionTracks.count <= 1,
                let embedded = try? await FileMetadataExtractor.shared.extractMetadataFromRemoteStream(
                    streamURL: streamURL,
                    headers: streamHeaders,
                    timeout: 15.0
                )
            {
                if let embeddedTitle = embedded.title,
                    !embeddedTitle.isEmpty,
                    enriched.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || enriched.title == enriched.series
                {
                    enriched.title = embeddedTitle
                }
                if let embeddedAuthor = embedded.author,
                    !embeddedAuthor.isEmpty,
                    (enriched.author?.isEmpty ?? true) || enriched.author == "Unknown Author"
                {
                    enriched.author = embeddedAuthor
                }
                if let embeddedNarrator = embedded.narrator,
                    !embeddedNarrator.isEmpty,
                    enriched.narrator?.isEmpty ?? true
                {
                    enriched.narrator = embeddedNarrator
                }
                if let embeddedDescription = embedded.description,
                    !embeddedDescription.isEmpty,
                    enriched.description?.isEmpty ?? true
                {
                    enriched.description = embeddedDescription
                }
                if let embeddedSeries = embedded.series,
                    !embeddedSeries.isEmpty,
                    enriched.series?.isEmpty ?? true
                {
                    enriched.series = embeddedSeries
                }
                if let embeddedSeriesNumber = embedded.seriesNumber,
                    enriched.seriesNumber == nil
                {
                    enriched.seriesNumber = embeddedSeriesNumber
                }
                if let embeddedYear = embedded.year,
                    enriched.publishedYear == nil
                {
                    enriched.publishedYear = embeddedYear
                }
                if let embeddedGenres = embedded.genres,
                    !embeddedGenres.isEmpty,
                    enriched.genres?.isEmpty ?? true
                {
                    enriched.genres = embeddedGenres
                }
                if let embeddedPublisher = embedded.publisher,
                    !embeddedPublisher.isEmpty,
                    enriched.publisher?.isEmpty ?? true
                {
                    enriched.publisher = embeddedPublisher
                }
                if let embeddedISBN = embedded.isbn,
                    !embeddedISBN.isEmpty,
                    enriched.isbn?.isEmpty ?? true
                {
                    enriched.isbn = embeddedISBN
                }
                if let embeddedASIN = embedded.asin,
                    !embeddedASIN.isEmpty,
                    enriched.asin?.isEmpty ?? true
                {
                    enriched.asin = embeddedASIN
                }
                if let embeddedDuration = embedded.duration,
                    embeddedDuration > 0,
                    (enriched.duration ?? 0) <= 0
                {
                    enriched.duration = embeddedDuration
                }

                await metadataManager.recordStreamExtractedMetadata(for: enriched)
            }
        }

        return enriched
    }

    func enrichListedAudiobook(_ book: Book) async -> Book {
        var enriched = book
        var detailProgressFraction: Double?

        if let detailReq = try? makeRequest(path: "/api/v1/app/books/\(grimmoryNumericId(book))"),
            let (detailData, detailResp) = try? await performAuthorizedRequest(detailReq),
            detailResp.statusCode == 200,
            let detail = try? JSONDecoder().decode(BookloreBookDetail.self, from: detailData)
        {
            enriched = mergeListedAudiobook(enriched, with: detail)
            detailProgressFraction = BookloreBookMapper.fraction(fromPercent: detail.audiobookProgress?.percentage)

            if let fraction = detailProgressFraction,
                let duration = enriched.duration,
                duration > 0
            {
                enriched.currentTime = duration * fraction
                enriched.isFinished = enriched.isFinished || fraction >= Book.finishedProgressThreshold
                AppLogger.network.info(
                    "[Booklore] Enriching '\(book.title)': detail progress \(fraction * 100)%% -> currentTime \(enriched.currentTime)s (duration \(duration)s)"
                )
            } else {
                AppLogger.network.info(
                    "[Booklore] Enriching '\(book.title)': audiobookProgress=\(String(describing: detail.audiobookProgress?.percentage)), duration=\(String(describing: enriched.duration)) - currentTime not set yet"
                )
            }
        } else {
            AppLogger.network.warning("[Booklore] Enriching '\(book.title)': detail fetch failed or returned nil audiobookProgress")
        }

        if let info = try? await playbackClient.fetchInfo(
            bookId: grimmoryNumericId(book)
        ) {
            enriched = mergeListedAudiobook(enriched, with: info)
        } else {
            AppLogger.network.warning("[Booklore] Enriching '\(book.title)': info fetch failed - duration may be unset")
        }

        if let fraction = detailProgressFraction, fraction > 0,
            let duration = enriched.duration,
            duration > 0
        {
            let actualFraction = enriched.currentTime / duration

            if enriched.currentTime <= 0 || abs(actualFraction - fraction) > 0.02 {
                AppLogger.network.info(
                    "[Booklore] Correcting progress drift for '\(book.title)': was \(actualFraction * 100)%% (\(enriched.currentTime)s), expected \(fraction * 100)%%"
                )
                enriched.currentTime = duration * fraction
            }
        } else if detailProgressFraction != nil {
            AppLogger.network.warning(
                "[Booklore] Enriching '\(book.title)': could not set currentTime after info fetch - duration=\(String(describing: enriched.duration))"
            )
        }

        AppLogger.network.info(
            "[Booklore] Enriched '\(book.title)': finalCurrentTime=\(enriched.currentTime)s, duration=\(String(describing: enriched.duration))s"
        )
        return enriched
    }

    private func mergeListedAudiobook(_ book: Book, with detail: BookloreBookDetail) -> Book {
        var enriched = book
        let primaryFile = detail.files?.first { BookloreBookMapper.mediaType(from: resolvedFileType(file: $0)) == .audiobook }
            ?? detail.files?.first(where: { $0.isPrimary == true }) ?? detail.files?.first
        let detailDuration = detail.durationSeconds.map(Double.init) ?? detail.duration

        if enriched.mediaType == .audiobook,
            let titleFromFile = BookloreBookMapper.title(fromPrimaryFileName: primaryFile?.fileName)
        {
            enriched.title = titleFromFile
        }

        if let detailAuthors = detail.authors, !detailAuthors.isEmpty,
            (enriched.author?.isEmpty ?? true) || enriched.author == "Unknown Author"
        {
            enriched.author = BookloreBookMapper.displayAuthor(from: detailAuthors)
            enriched.authors = detailAuthors
        }

        if let detailDuration, detailDuration > 0 {
            enriched.duration = max(enriched.duration ?? 0, detailDuration)
        }

        if let description = detail.description,
            !description.isEmpty,
            enriched.description?.isEmpty ?? true
        {
            enriched.description = description
        }

        if let publisher = detail.publisher,
            !publisher.isEmpty,
            enriched.publisher?.isEmpty ?? true
        {
            enriched.publisher = publisher
        }

        if let language = detail.language,
            !language.isEmpty,
            enriched.language?.isEmpty ?? true
        {
            enriched.language = language
        }

        if let libraryName = detail.libraryName,
            !libraryName.isEmpty,
            enriched.libraryName?.isEmpty ?? true
        {
            enriched.libraryName = libraryName
        }

        if let publishedYear = BookloreBookMapper.publishedYear(from: detail.publishedDate),
            enriched.publishedYear == nil
        {
            enriched.publishedYear = publishedYear
        }

        if let goodreadsRating = detail.goodreadsRating,
            enriched.goodreadsRating == nil
        {
            enriched.goodreadsRating = goodreadsRating
        }

        if let isbn13 = detail.isbn13,
            !isbn13.isEmpty,
            enriched.isbn?.isEmpty ?? true
        {
            enriched.isbn = isbn13
        }

        if let categories = detail.categories,
            !categories.isEmpty,
            enriched.genres?.isEmpty ?? true
        {
            enriched.genres = Array(categories).sorted { lhs, rhs in
                lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
        }

        let mappedDetailChapters = BookloreBookMapper.chapters(from: detail.chapters, bookDuration: enriched.duration ?? detailDuration ?? 0)
        if !mappedDetailChapters.isEmpty {
            enriched.chapters = mappedDetailChapters
        }

        let detailReadStatus = detail.readStatus?.uppercased()
        if detailReadStatus == "READ" {
            enriched.isFinished = true
        }
        enriched.hideFromContinue = BookloreBookMapper.statusSuppressesContinue(detailReadStatus)
        if let rs = detailReadStatus {
            enriched.serverReadStatus = rs
        }

        if let updatedAt = parseDate(detail.dateFinished) ?? parseDate(detail.lastReadTime) ?? parseDate(detail.addedOn) {
            enriched.lastUpdate = updatedAt
        }

        return enriched
    }

    private func mergeListedAudiobook(_ book: Book, with info: BookloreAudiobookInfo) -> Book {
        var enriched = book
        let previousDuration = enriched.duration ?? 0
        let progressFraction = previousDuration > 0 ? min(max(enriched.currentTime / previousDuration, 0), 1) : nil

        if let infoTitle = info.title,
            !infoTitle.isEmpty,
            enriched.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            enriched.title = infoTitle
        }

        if let infoAuthor = info.author,
            !infoAuthor.isEmpty,
            (enriched.author?.isEmpty ?? true) || enriched.author == "Unknown Author"
        {
            enriched.author = infoAuthor
        }

        if let narrator = info.narrator,
            !narrator.isEmpty
        {
            enriched.narrator = narrator
        }

        if let infoDuration = info.duration,
            infoDuration > 0
        {
            enriched.duration = infoDuration
            if let progressFraction {
                enriched.currentTime = infoDuration * progressFraction
            }
        }

        let mappedInfoChapters = BookloreBookMapper.chapters(from: info.chapters, bookDuration: enriched.duration ?? info.duration ?? 0)
        if !mappedInfoChapters.isEmpty {
            enriched.chapters = mappedInfoChapters
        }

        return enriched
    }
}
