import Foundation
import Logging

final class BatchMetadataMatcher: @unchecked Sendable {
    static let shared = BatchMetadataMatcher()

    private init() {}

    @discardableResult
    func batchMatch(
        books: [Book],
        libraryName: String,
        provider: MetadataProvider,
        onProgress: @escaping @Sendable (Int, Int) -> Void,
        onComplete: @escaping @Sendable (BatchMatchResult) -> Void
    ) -> Task<Void, Never> {
        let threshold = SettingsManager.shared.autoMatchThreshold

        return Task {
            var autoMatched = 0
            var pending = 0
            var skipped = 0
            var errors = 0
            var errorsList: [String] = []

            for (index, book) in books.enumerated() {
                if Task.isCancelled {
                    AppLogger.network.info("Batch matching cancelled by user")
                    let result = BatchMatchResult(
                        total: books.count,
                        autoMatched: autoMatched,
                        pending: pending,
                        skipped: skipped,
                        errors: errors,
                        errorsList: errorsList
                    )
                    await MainActor.run {
                        onComplete(result)
                    }
                    return
                }

                await MainActor.run {
                    onProgress(index + 1, books.count)
                }

                if Task.isCancelled {
                    continue
                }

                if index > 0 && index % 10 == 0 {
                    try? await Task.sleep(for: .milliseconds(100))
                }

                if Task.isCancelled {
                    continue
                }

                if await hasMetadataBeenAltered(bookId: book.id) {
                    AppLogger.network.debug(
                        "Skipping metadata match bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) reason=existing-override"
                    )
                    skipped += 1
                    continue
                }

                if Task.isCancelled {
                    continue
                }

                if let metadata = try? await MetadataStorage.shared.loadMetadata(bookId: book.id),
                    let asin = metadata.file.asin, !asin.isEmpty
                {
                    AppLogger.network.debug(
                        "Found embedded identifier bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                    )
                    do {
                        let countryCode = SettingsManager.shared.audibleCountryCode
                        let audibleMetadata = try await AudibleService.shared.getProductDetails(asin: asin, countryCode: countryCode)

                        var updatedMetadata = metadata
                        updatedMetadata.audible = audibleMetadata
                        updatedMetadata.lastUpdated = Date()

                        try await MetadataStorage.shared.saveMetadata(updatedMetadata)

                        await AppCache.shared.removeCoverData(for: book)

                        await MainActor.run {
                            NotificationCenter.default.post(name: .metadataUpdated, object: book.id)
                        }

                        AppLogger.network.debug(
                            "Auto-matched embedded identifier bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                        )
                        autoMatched += 1
                        continue
                    } catch {
                        AppLogger.network.error("Failed to fetch metadata for embedded identifier: \(error.localizedDescription)")
                    }
                }

                if Task.isCancelled {
                    continue
                }

                do {
                    let matches = try await findMatches(for: book, provider: provider)

                    if Task.isCancelled {
                        continue
                    }

                    if matches.isEmpty {
                        skipped += 1
                        continue
                    }

                    let bestMatch = matches[0]

                    if shouldAutoMatch(
                        bestMatch: bestMatch,
                        allMatches: matches,
                        threshold: threshold,
                        book: book
                    ) {
                        if Task.isCancelled {
                            continue
                        }
                        let tempEntry = MatchQueueEntry(
                            bookId: book.id,
                            ratingKey: book.ratingKey,
                            partKey: book.partKey,
                            source: book.source,
                            backendId: book.backendId,
                            trackIndex: book.trackIndex,
                            fileMetadata: FileMetadataLayer(),
                            matchCandidates: [],
                            bookCoverUrl: book.thumb
                        )
                        try await approveMatch(bookId: book.id, match: bestMatch, entry: tempEntry)
                        autoMatched += 1
                    } else {
                        if Task.isCancelled {
                            continue
                        }
                        await addToPendingQueue(book: book, matches: matches)
                        pending += 1
                    }
                } catch {
                    errors += 1
                    errorsList.append("\(book.title): \(error.localizedDescription)")
                }
            }

            let result = BatchMatchResult(
                total: books.count,
                autoMatched: autoMatched,
                pending: pending,
                skipped: skipped,
                errors: errors,
                errorsList: errorsList
            )

            await MainActor.run {
                onComplete(result)
            }
        }
    }

    private func hasMetadataBeenAltered(bookId: String) async -> Bool {
        guard let metadata = try? await MetadataStorage.shared.loadMetadata(bookId: bookId) else {
            return false
        }

        if let overrides = metadata.userOverrides {
            if overrides.customTitle != nil || overrides.customAuthor != nil || overrides.customSeries != nil
                || overrides.customNarrator != nil
            {
                return true
            }
        }

        if metadata.audible != nil {
            return true
        }

        return false
    }

    private func getAllowedDurationDifference(for duration: TimeInterval) -> TimeInterval {
        let hours = duration / 3600.0
        if hours >= 15.0 {
            return 300
        } else if hours >= 5.0 {
            return 120
        } else {
            return 60
        }
    }

    private func shouldAutoMatch(
        bestMatch: AudibleMatchCandidate,
        allMatches: [AudibleMatchCandidate],
        threshold: Double,
        book: Book
    ) -> Bool {
        if let bookASIN = book.asin, !bookASIN.isEmpty,
            bookASIN.uppercased() == bestMatch.asin.uppercased()
        {
            AppLogger.network.info("Identifier exact match found - AUTO-MATCHING")
            return true
        }

        if bestMatch.confidence < threshold {
            AppLogger.network.info(
                "Confidence \(String(format: "%.0f", bestMatch.confidence * 100))% below threshold \(String(format: "%.0f", threshold * 100))% - sending to pending"
            )
            return false
        }

        AppLogger.network.info("Title/Author match: \(String(format: "%.0f", bestMatch.confidence * 100))% confidence")

        if bestMatch.confidence < 1.0 {
            let matchesAboveThreshold = allMatches.filter { $0.confidence >= threshold }
            if matchesAboveThreshold.count > 1 {
                let secondBest = matchesAboveThreshold[1]
                let confidenceDifference = abs(bestMatch.confidence - secondBest.confidence)

                if confidenceDifference <= 0.01 {
                    AppLogger.network.info(
                        "Ambiguous: best: \(String(format: "%.0f", bestMatch.confidence * 100))%, second: \(String(format: "%.0f", secondBest.confidence * 100))% (diff: \(String(format: "%.1f", confidenceDifference * 100))%) - sending to pending"
                    )
                    return false
                } else {
                    AppLogger.network.info(
                        "Clear winner: best: \(String(format: "%.0f", bestMatch.confidence * 100))%, second: \(String(format: "%.0f", secondBest.confidence * 100))% (diff: \(String(format: "%.1f", confidenceDifference * 100))%)"
                    )
                }
            }
        } else {
            AppLogger.network.info("Perfect 100% match - proceeding to duration check")
        }

        guard let bookDuration = book.duration, bestMatch.duration > 0 else {
            AppLogger.network.info("Duration unavailable - sending to pending for manual review")
            return false
        }

        let durationDiffSeconds = abs(bookDuration - bestMatch.duration)
        let allowedDiff = getAllowedDurationDifference(for: bestMatch.duration)
        let allowedMinutes = Int(allowedDiff / 60)

        if durationDiffSeconds <= allowedDiff {
            AppLogger.network.info("Duration matches (diff: \(Int(durationDiffSeconds))s ≤ \(allowedMinutes) min) - AUTO-MATCHING")
            return true
        } else {
            AppLogger.network.info(
                "Duration differs by \(Int(durationDiffSeconds))s (>\(allowedMinutes) min threshold) - sending to pending for manual review"
            )
            return false
        }
    }

    private func findMatches(for book: Book, provider: MetadataProvider) async throws -> [AudibleMatchCandidate] {
        let existingMetadata = try? await MetadataStorage.shared.loadMetadata(bookId: book.id)

        let folderNameQuery = book.filePath.flatMap { path -> String? in
            let url = URL(fileURLWithPath: path)
            return url.deletingLastPathComponent().lastPathComponent
        }
        let fileNameQuery = book.filePath.flatMap { path -> String? in
            let url = URL(fileURLWithPath: path)
            return url.deletingPathExtension().lastPathComponent
        }

        var searchQueries: [String] = []

        if let fileName = fileNameQuery, !fileName.isEmpty {
            let cleaned = cleanQueryForSearch(fileName)
            if !cleaned.isEmpty {
                searchQueries.append(cleaned)
            }
        }

        if let folderName = folderNameQuery, !folderName.isEmpty, folderName != fileNameQuery {
            let cleaned = cleanQueryForSearch(folderName)
            if !cleaned.isEmpty && !searchQueries.contains(cleaned) {
                searchQueries.append(cleaned)
            }
        }

        if searchQueries.isEmpty {
            let cleaned = cleanQueryForSearch(book.title)
            if !cleaned.isEmpty {
                searchQueries.append(cleaned)
            }
        }

        if let fileName = fileNameQuery, !fileName.isEmpty {
            let stripped = stripSeriesMarkers(fileName)
            let cleaned = cleanQueryForSearch(stripped)
            if !cleaned.isEmpty && !searchQueries.contains(cleaned) {
                searchQueries.append(cleaned)
            }
        }

        let searchQuery = searchQueries.first ?? book.title

        let parsedQuery = MatchingUtils.parseTitleAndAuthor(from: searchQuery)
        let enhancedSearchQuery = parsedQuery.author.map { "\(parsedQuery.title) \($0)" } ?? searchQuery

        if let fileName = fileNameQuery {
            let original = fileName
            let cleaned = cleanQueryForSearch(fileName)
            if original != cleaned {
                AppLogger.network.info("Query normalized: '\(original)' -> '\(cleaned)'")
            }
        }

        if parsedQuery.author != nil {
            AppLogger.network.debug(
                "Metadata query parsed titleDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: parsedQuery.title)) authorDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: parsedQuery.author!))"
            )
        }

        switch provider {
        case .iTunes:
            AppLogger.network.info("Catalog-B for: \(enhancedSearchQuery)")
            try await Task.sleep(nanoseconds: 3_000_000_000)

            let iTunesResults = try await iTunesService.shared.search(
                query: enhancedSearchQuery,
                limit: 50,
                country: SettingsManager.shared.audibleCountryCode
            )

            if !iTunesResults.isEmpty {
                AppLogger.network.info("Found \(iTunesResults.count) Catalog-B results")
                return try await convertITunesToCandidates(
                    iTunesResults: iTunesResults,
                    book: book,
                    existingMetadata: existingMetadata,
                    folderName: folderNameQuery,
                    fileName: fileNameQuery
                )
            } else {
                AppLogger.network.info("No Catalog-B results found")
                return []
            }

        case .audiobookshelf:
            AppLogger.network.info("server-side provider for: \(searchQuery)")

            let backends = AppState.shared.providerConnections.allBackends()
            let absBackends = backends.filter { $0.type == .audiobookshelf || $0.type == .jellyfin || $0.type == .emby }

            func isSample(_ b: BackendConfig) -> Bool {
                let u = b.url.lowercased()
                return u.contains("example.com") || u.contains("abs.example.com") || u.contains("plex.example.com")
            }

            let candidates = absBackends.filter { !isSample($0) }
            let authenticated = candidates.filter { !($0.token?.isEmpty ?? true) }
            let backend = authenticated.first ?? candidates.first ?? absBackends.first

            guard let backend else {
                AppLogger.network.info("No metadata search backend configured")
                AppLogger.network.info("Please add a compatible server in settings to use this provider")
                return []
            }

            AppLogger.network.info("Using \(backend.type.rawValue) server for search: \(backend.name)")

            do {
                var searchTitle = existingMetadata?.file.title ?? book.title
                var searchAuthor = existingMetadata?.file.author ?? book.author

                if searchAuthor?.isEmpty ?? true {
                    let parsedMetadataTitle = MatchingUtils.parseTitleAndAuthor(from: searchTitle)
                    if let newAuthor = parsedMetadataTitle.author {
                        searchTitle = parsedMetadataTitle.title
                        searchAuthor = newAuthor
                    } else if let newAuthor = parsedQuery.author {
                        searchTitle = parsedQuery.title
                        searchAuthor = newAuthor
                    }
                }

                AppLogger.network.info("server params - title: '\(searchTitle)', author: '\(searchAuthor ?? "none")'")

                let searchResults = try await AudiobookshelfService.shared.searchMetadata(
                    title: searchTitle,
                    author: searchAuthor,
                    backend: backend,
                    provider: "audible",
                    limit: 50
                )

                if searchResults.isEmpty {
                    AppLogger.network.info("No results from server provider")
                    return []
                }

                AppLogger.network.info("Found \(searchResults.count) results from server provider")

                let actualTitle =
                    existingMetadata?.file.title
                    ?? folderNameQuery
                    ?? fileNameQuery
                    ?? book.title
                let actualAuthor = existingMetadata?.file.author ?? book.author
                let actualNarrator = existingMetadata?.file.narrator ?? book.narrator
                let actualSeries = existingMetadata?.file.series ?? book.series
                let actualSeriesNumber = existingMetadata?.file.seriesNumber ?? book.seriesNumber
                let actualYear = existingMetadata?.file.year ?? book.publishedYear
                let actualPublisher = existingMetadata?.file.publisher ?? book.publisher
                let actualGenres = existingMetadata?.file.genres ?? book.genres
                let actualDescription = existingMetadata?.file.description ?? book.description
                let actualDuration = existingMetadata?.file.duration ?? book.duration
                let actualISBN = existingMetadata?.file.isbn ?? book.isbn
                let actualASIN = existingMetadata?.file.asin ?? book.asin

                let fileMetadata = FileMetadataLayer(
                    title: actualTitle,
                    author: actualAuthor,
                    narrator: actualNarrator,
                    series: actualSeries,
                    seriesNumber: actualSeriesNumber,
                    year: actualYear,
                    publisher: actualPublisher,
                    genres: actualGenres,
                    description: actualDescription,
                    duration: actualDuration,
                    isbn: actualISBN,
                    asin: actualASIN,
                    fileName: fileNameQuery,
                    folderName: folderNameQuery
                )

                let candidates = searchResults.map { result -> AudibleMatchCandidate in
                    let score = MatchingUtils.calculateScore(
                        file: fileMetadata,
                        audible: result
                    )

                    return AudibleMatchCandidate(
                        id: result.asin,
                        asin: result.asin,
                        title: result.title,
                        author: result.authors.joined(separator: ", "),
                        narrators: result.narrators,
                        series: nil,
                        seriesNumber: nil,
                        duration: TimeInterval(result.duration),
                        confidence: score.total,
                        matchReason: nil,
                        coverUrl: result.coverUrl,
                        matchSource: .audiobookshelf,
                        description: result.description,
                        durationScore: score.durationScore,
                        titleScore: score.titleScore,
                        authorScore: score.authorScore
                    )
                }

                if let fileDuration = fileMetadata.duration, fileDuration > 0 {
                    let sorted = candidates.sorted { a, b in
                        let diffA = abs(a.duration - fileDuration)
                        let diffB = abs(b.duration - fileDuration)
                        if abs(diffA - diffB) < 60 {
                            return a.confidence > b.confidence
                        }
                        return diffA < diffB
                    }
                    return Array(sorted.prefix(20))
                } else {
                    return Array(candidates.sorted { $0.confidence > $1.confidence }.prefix(20))
                }
            } catch {
                AppLogger.network.error("Server provider search failed: \(error.localizedDescription)")
                return []
            }

        case .enveSearch:
            AppLogger.network.info("direct catalog for: \(enhancedSearchQuery)")

            let countryCode = SettingsManager.shared.audibleCountryCode

            do {
                let fileMetadata = FileMetadataLayer(
                    title: parsedQuery.title,
                    author: book.author ?? parsedQuery.author,
                    narrator: book.narrator,
                    description: book.description,
                    duration: book.duration,
                    isbn: book.isbn,
                    asin: book.asin,
                    fileName: fileNameQuery,
                    folderName: folderNameQuery
                )

                let searchResults = try await AudibleService.shared.simpleSearch(
                    query: enhancedSearchQuery,
                    numResults: 50,
                    countryCode: countryCode
                )

                AppLogger.network.info("Found \(searchResults.count) results")

                let matchCandidates = searchResults.map { result -> AudibleMatchCandidate in
                    let score = MatchingUtils.calculateScore(file: fileMetadata, audible: result)

                    return AudibleMatchCandidate(
                        id: result.asin,
                        asin: result.asin,
                        title: result.title,
                        author: result.authors.joined(separator: ", "),
                        narrators: result.narrators,
                        series: nil,
                        seriesNumber: nil,
                        duration: TimeInterval(result.duration),
                        confidence: score.total,
                        matchReason: nil,
                        coverUrl: result.coverUrl,
                        matchSource: .enveSearch,
                        description: result.description,
                        durationScore: score.durationScore,
                        titleScore: score.titleScore,
                        authorScore: score.authorScore
                    )
                }

                if let fileDuration = fileMetadata.duration, fileDuration > 0 {
                    let sorted = matchCandidates.sorted { a, b in
                        let diffA = abs(a.duration - fileDuration)
                        let diffB = abs(b.duration - fileDuration)
                        if abs(diffA - diffB) < 60 {
                            return a.confidence > b.confidence
                        }
                        return diffA < diffB
                    }
                    return Array(sorted.prefix(20))
                } else {
                    return Array(matchCandidates.sorted { $0.confidence > $1.confidence }.prefix(20))
                }
            } catch {
                AppLogger.network.error("failed: \(error.localizedDescription)")
                return []
            }
        }
    }

    private func approveMatch(bookId: String, match: AudibleMatchCandidate, entry: MatchQueueEntry? = nil) async throws {
        AppLogger.network.debug(
            "Approving metadata match source=\(match.matchSource?.rawValue ?? "Unknown") matchDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: match.title))"
        )

        var resolvedDescription = match.description
        if resolvedDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            let asin = match.asin
            if !asin.isEmpty, !asin.hasPrefix("itunes_") {
                let cc = SettingsManager.shared.audibleCountryCode
                if let details = try? await AudibleService.shared.getProductDetails(asin: asin, countryCode: cc) {
                    resolvedDescription = details.descriptionPlain ?? details.description
                    if resolvedDescription != nil {
                        AppLogger.network.info("Enriched description for identifier: \(asin)")
                    }
                }
            }
        }

        let audibleMetadata = AudibleMetadataLayer(
            asin: match.asin,
            title: match.title,
            subtitle: nil,
            author: match.author,
            narrators: match.narrators.isEmpty ? nil : match.narrators,
            series: match.series,
            seriesNumber: match.seriesNumber,
            description: resolvedDescription,
            descriptionPlain: resolvedDescription,
            coverUrl: match.coverUrl,
            publisher: nil,
            publishedYear: nil,
            releaseDate: nil,
            genres: nil,
            tags: nil,
            rating: nil,
            ratingCount: nil,
            duration: match.duration,
            language: nil,
            format: nil
        )

        var metadata =
            try await MetadataStorage.shared.loadMetadata(bookId: bookId)
            ?? BookMetadata(bookId: bookId, file: FileMetadataLayer())

        metadata.audible = audibleMetadata
        metadata.lastUpdated = Date()

        try await MetadataStorage.shared.saveMetadata(metadata)

        AppLogger.network.info("Saved metadata for book \(bookId)")

        let source = entry?.source ?? .plex
        let backendId = entry?.backendId
        let tempBook = Book(
            id: bookId,
            ratingKey: entry?.ratingKey ?? bookId,
            title: metadata.file.title ?? "Unknown",
            author: metadata.file.author,
            narrator: metadata.file.narrator,
            thumb: nil,
            partKey: entry?.partKey,
            duration: metadata.file.duration,
            chapters: nil,
            currentChapterIndex: nil,
            source: source,
            backendId: backendId,
            trackIndex: entry?.trackIndex,
            filePath: nil,
            audioTracks: nil,
            description: nil,
            series: nil,
            seriesNumber: nil,
            publishedYear: nil,
            genres: nil,
            publisher: nil,
            isbn: nil,
            asin: nil,
            addedAt: nil,
            libraryName: nil,
            backendName: nil,
            progress: nil,
            lastPlayed: nil
        )
        await AppCache.shared.removeCoverData(for: tempBook)

        await MainActor.run {
            NotificationCenter.default.post(name: .metadataUpdated, object: bookId)
        }

        AppLogger.network.info("Saved metadata with cover: \(metadata.audible?.coverUrl != nil)")
        AppLogger.network.info("Cleared cover cache for book: \(bookId)")
    }

    private func addToPendingQueue(book: Book, matches: [AudibleMatchCandidate]) async {
        guard !matches.isEmpty else {
            AppLogger.network.debug(
                "Skipping metadata queue bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) reason=no-candidates"
            )
            return
        }

        let existingMetadata = try? await MetadataStorage.shared.loadMetadata(bookId: book.id)

        let folderName = book.filePath.flatMap { path -> String? in
            let url = URL(fileURLWithPath: path)
            return url.deletingLastPathComponent().lastPathComponent
        }
        let fileName = book.filePath.flatMap { path -> String? in
            let url = URL(fileURLWithPath: path)
            return url.deletingPathExtension().lastPathComponent
        }

        let actualTitle =
            existingMetadata?.file.title
            ?? folderName
            ?? fileName
            ?? book.title
        let actualAuthor = existingMetadata?.file.author ?? book.author
        let actualNarrator = existingMetadata?.file.narrator ?? book.narrator
        let actualSeries = existingMetadata?.file.series ?? book.series
        let actualSeriesNumber = existingMetadata?.file.seriesNumber ?? book.seriesNumber
        let actualYear = existingMetadata?.file.year ?? book.publishedYear
        let actualPublisher = existingMetadata?.file.publisher ?? book.publisher
        let actualGenres = existingMetadata?.file.genres ?? book.genres
        let actualDescription = existingMetadata?.file.description ?? book.description
        let actualDuration = existingMetadata?.file.duration ?? book.duration
        let actualISBN = existingMetadata?.file.isbn ?? book.isbn
        let actualASIN = existingMetadata?.file.asin ?? book.asin

        let fileMetadata = FileMetadataLayer(
            title: actualTitle,
            author: actualAuthor,
            narrator: actualNarrator,
            series: actualSeries,
            seriesNumber: actualSeriesNumber,
            year: actualYear,
            publisher: actualPublisher,
            genres: actualGenres,
            description: actualDescription,
            duration: actualDuration,
            isbn: actualISBN,
            asin: actualASIN,
            fileName: fileName,
            folderName: folderName
        )

        let entry = MatchQueueEntry(
            bookId: book.id,
            ratingKey: book.ratingKey,
            partKey: book.partKey,
            source: book.source,
            backendId: book.backendId,
            trackIndex: book.trackIndex,
            fileMetadata: fileMetadata,
            matchCandidates: matches,
            status: .pending,
            bookCoverUrl: book.thumb
        )

        AppLogger.network.debug(
            "Creating metadata match entry bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) source=\(book.source.rawValue) hasBackend=\(book.backendId != nil) hasPart=\(book.partKey != nil) hasCover=\(book.thumb != nil)"
        )

        MatchQueueStorage.shared.addMatchQueueEntry(entry)
    }

    func approvePendingMatch(entryId: String, candidate: AudibleMatchCandidate) async throws {
        let queue = MatchQueueStorage.shared.readMatchQueue()
        guard let entry = queue.entries.first(where: { $0.id == entryId }) else {
            throw BatchMatchError.entryNotFound
        }

        try await approveMatch(bookId: entry.bookId, match: candidate, entry: entry)

        MatchQueueStorage.shared.removeMatchQueueEntry(entryId: entryId)
    }

    func rejectPendingMatch(entryId: String) {
        let queue = MatchQueueStorage.shared.readMatchQueue()
        guard let entry = queue.entries.first(where: { $0.id == entryId }) else {
            return
        }

        let updatedEntry = MatchQueueEntry(
            id: entry.id,
            bookId: entry.bookId,
            bookPath: entry.bookPath,
            fileMetadata: entry.fileMetadata,
            matchCandidates: entry.matchCandidates,
            selectedMatch: nil,
            status: .rejected,
            createdAt: entry.createdAt,
            reviewedAt: ISO8601DateFormatter().string(from: Date()),
            bookCoverUrl: entry.bookCoverUrl
        )

        MatchQueueStorage.shared.updateMatchQueueEntry(updatedEntry)
    }

    private func cleanQueryForSearch(_ query: String) -> String {
        var cleaned = query

        cleaned = cleaned.replacingOccurrences(
            of: "^\\d+\\s*[-\\x{2013}\\x{2014}.:]\\s*",
            with: "",
            options: .regularExpression
        )

        cleaned = cleaned.replacingOccurrences(of: ":", with: " ")
        cleaned = cleaned.replacingOccurrences(of: " - ", with: " ")
        cleaned = cleaned.replacingOccurrences(of: " \u{2013} ", with: " ")
        cleaned = cleaned.replacingOccurrences(of: " \u{2014} ", with: " ")

        cleaned = cleaned.replacingOccurrences(
            of: "\\([^)]*\\)",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: "\\[[^\\]]*\\]",
            with: "",
            options: .regularExpression
        )

        let markers = [
            "\\bunabridged\\b",
            "\\babridged\\b",
            "\\bdeluxe edition\\b",
            "\\bexpanded edition\\b",
            "\\bcollector's edition\\b",
        ]
        for marker in markers {
            cleaned = cleaned.replacingOccurrences(
                of: marker,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        cleaned = cleaned.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        return cleaned
    }

    private func stripSeriesMarkers(_ text: String) -> String {
        var stripped = text

        let patterns = [
            "\\s+Book\\s+\\d+",
            "\\s+Vol\\.?\\s+\\d+",
            "\\s+Volume\\s+\\d+",
            "\\s+Part\\s+\\d+",
            "\\s+#\\d+",
            "\\s+-\\s+\\d+$",
        ]

        for pattern in patterns {
            stripped = stripped.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return stripped.trimmingCharacters(in: .whitespaces)
    }

    private func convertITunesToCandidates(
        iTunesResults: [iTunesAudiobook],
        book: Book,
        existingMetadata: BookMetadata?,
        folderName: String?,
        fileName: String?
    ) async throws -> [AudibleMatchCandidate] {
        let actualTitle =
            existingMetadata?.file.title
            ?? folderName
            ?? fileName
            ?? book.title
        let actualAuthor = existingMetadata?.file.author ?? book.author
        let actualNarrator = existingMetadata?.file.narrator ?? book.narrator
        let actualSeries = existingMetadata?.file.series ?? book.series
        let actualSeriesNumber = existingMetadata?.file.seriesNumber ?? book.seriesNumber
        let actualYear = existingMetadata?.file.year ?? book.publishedYear
        let actualPublisher = existingMetadata?.file.publisher ?? book.publisher
        let actualGenres = existingMetadata?.file.genres ?? book.genres
        let actualDescription = existingMetadata?.file.description ?? book.description
        let actualDuration = existingMetadata?.file.duration ?? book.duration
        let actualISBN = existingMetadata?.file.isbn ?? book.isbn
        let actualASIN = existingMetadata?.file.asin ?? book.asin

        let fileMetadata = FileMetadataLayer(
            title: actualTitle,
            author: actualAuthor,
            narrator: actualNarrator,
            series: actualSeries,
            seriesNumber: actualSeriesNumber,
            year: actualYear,
            publisher: actualPublisher,
            genres: actualGenres,
            description: actualDescription,
            duration: actualDuration,
            isbn: actualISBN,
            asin: actualASIN,
            fileName: fileName,
            folderName: folderName
        )

        let candidates = iTunesResults.compactMap { result -> AudibleMatchCandidate? in
            guard let trackId = result.trackId else { return nil }

            let title = result.trackCensoredName ?? result.trackName ?? result.collectionCensoredName ?? result.collectionName ?? ""
            let author = result.artistName ?? ""
            let durationSeconds = result.trackTimeMillis.map { TimeInterval($0) / 1000.0 }

            let score = MatchingUtils.calculateScore(
                file: fileMetadata,
                iTunes: result
            )

            return AudibleMatchCandidate(
                id: "itunes_\(trackId)",
                asin: "itunes_\(trackId)",
                title: title,
                author: author,
                narrators: [],
                series: nil,
                seriesNumber: nil,
                duration: durationSeconds ?? 0,
                confidence: score.total,
                matchReason: nil,
                coverUrl: result.artworkUrl100,
                matchSource: .iTunes,
                description: result.description ?? result.longDescription,
                durationScore: score.durationScore,
                titleScore: score.titleScore,
                authorScore: score.authorScore
            )
        }

        return candidates.sorted { $0.confidence > $1.confidence }
    }

}

enum BatchMatchError: Error, LocalizedError {
    case entryNotFound
    case failedToFetchMetadata
    case failedToWriteMetadata
    case failedToUpdateQueue

    var errorDescription: String? {
        switch self {
        case .entryNotFound:
            return "Match queue entry not found"
        case .failedToFetchMetadata:
            return "Failed to fetch metadata from external service"
        case .failedToWriteMetadata:
            return "Failed to save metadata"
        case .failedToUpdateQueue:
            return "Failed to update match queue"
        }
    }
}
