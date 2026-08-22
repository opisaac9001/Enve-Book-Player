import AVFoundation
import Foundation

@MainActor
@Observable
final class MatchesSearchModel {
    enum Mode {
        case audiobook
        case ebook
    }

    enum Source: String, CaseIterable, Identifiable {
        case iTunes
        case audiobookshelf
        case enveSearch
        case googleBooks
        case openLibrary
        case comicVine

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .iTunes: "iTunes"
            case .audiobookshelf: "AudioBookshelf"
            case .enveSearch: "Enve Search"
            case .googleBooks: "Google Books"
            case .openLibrary: "Open Library"
            case .comicVine: "ComicVine"
            }
        }

        static func available(for mode: Mode) -> [Source] {
            switch mode {
            case .audiobook: [.enveSearch, .iTunes, .audiobookshelf]
            case .ebook: [.enveSearch, .googleBooks, .openLibrary, .comicVine]
            }
        }

        static func preferred(for mode: Mode) -> Source {
            mode == .ebook ? .googleBooks : .enveSearch
        }
    }

    struct Result: Identifiable {
        let id: String
        let title: String
        let author: String?
        let publisher: String?
        let publishedYear: Int?
        let pageCount: Int?
        let seriesName: String?
        let seriesPosition: String?
        let coverUrl: String?
        let duration: TimeInterval?
        let source: Source
        let confidence: Double?
        let description: String?
    }

    let mode: Mode
    let fileMetadata: FileMetadataLayer
    var query: String
    var results: [Result] = []
    var isSearching = false
    var errorMessage: String?
    var selectedProvider: Source
    let availableSources: [Source]

    var isPreviewPlaying = false
    var isStartingPreview = false
    var previewError: String?

    @ObservationIgnored private var cachedITunesResults: [String: iTunesAudiobook] = [:]
    @ObservationIgnored private var previewPlayer: AVPlayer?
    @ObservationIgnored private var previewStopWorkItem: DispatchWorkItem?
    @ObservationIgnored private var previewRequestID = UUID()
    @ObservationIgnored private var audiobookshelfBackend: BackendConfig?
    private let matches: MatchesEngine

    init(fileMetadata: FileMetadataLayer, initialQuery: String, mediaType: AppMediaType, matches: MatchesEngine = EnveEngine.shared.matches)
    {
        mode = mediaType == .ebook ? .ebook : .audiobook
        self.fileMetadata = fileMetadata
        availableSources = Source.available(for: mode)
        selectedProvider = Source.preferred(for: mode)
        query = Self.matchesNormalizeQuery(initialQuery)
        self.matches = matches
    }

    var fileDuration: TimeInterval? { fileMetadata.duration }
    var supportsPreview: Bool { mode == .audiobook }

    func search(source: Source) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            switch source {
            case .iTunes:
                let audiobooks = try await iTunesService.shared.search(
                    query: q,
                    limit: 50,
                    country: SettingsManager.shared.audibleCountryCode
                )
                var seen = Set<Int>()
                let unique = audiobooks.filter { ab in
                    guard let id = ab.id else { return false }
                    return seen.insert(id).inserted
                }
                cachedITunesResults = Dictionary(
                    uniqueKeysWithValues: unique.compactMap { ab in
                        ab.id.map { (String($0), ab) }
                    }
                )
                results = sorted(unique.map(makeITunesResult))

            case .audiobookshelf:
                guard
                    let payload = try await matches.searchAudiobookshelfMetadata(
                        title: q,
                        author: fileMetadata.author,
                        limit: 50
                    )
                else {
                    errorMessage = "No AudioBookshelf server is connected."
                    return
                }
                audiobookshelfBackend = payload.backend
                results = sorted(payload.hits.map { makeAudibleResult(from: $0, source: .audiobookshelf) })

            case .enveSearch:
                let parsed = MatchingUtils.parseTitleAndAuthor(from: q)
                let countryCode = SettingsManager.shared.audibleCountryCode
                let trimmed = parsed.title.uppercased()
                let looksLikeASIN =
                    trimmed.count == 10
                    && trimmed.allSatisfy { $0.isNumber || ($0 >= "A" && $0 <= "Z") }
                    && (trimmed.hasPrefix("B0") || trimmed.allSatisfy(\.isNumber))

                var needsTitleSearch = true
                if looksLikeASIN,
                    let hit = try? await AudibleService.shared.getSearchResultByASIN(asin: trimmed, countryCode: countryCode)
                {
                    results = [makeAudibleResult(from: hit, source: .enveSearch)]
                    needsTitleSearch = false
                }
                if needsTitleSearch {
                    let searchString = parsed.author.map { "\(parsed.title) \($0)" } ?? q
                    let hits = try await AudibleService.shared.simpleSearch(
                        query: searchString,
                        numResults: 50,
                        countryCode: countryCode
                    )
                    results = sorted(hits.map { makeAudibleResult(from: $0, source: .enveSearch) })
                }

            case .googleBooks:
                let parts = googleBooksQuery(for: q)
                do {
                    let hits = try await GoogleBooksService.shared.search(
                        query: parts.query,
                        author: parts.author,
                        isbn: parts.isbn,
                        limit: 10
                    )
                    results = sorted(hits.map { makeGoogleBooksResult(from: $0, searchQuery: q) })
                } catch GoogleBooksService.SearchError.rateLimited {
                    results = []
                    errorMessage = "Google Books is rate-limited. Try again in a minute or search Open Library manually."
                } catch let GoogleBooksService.SearchError.httpStatus(code) where [500, 502, 503, 504].contains(code) {
                    results = []
                    errorMessage = "Google Books is unavailable (\(code)). Try again or search Open Library manually."
                }

            case .openLibrary:
                let docs = try await OpenLibraryService.shared.search(query: ebookSearchText(for: q), limit: 40)
                results = sorted(docs.map { makeOpenLibraryResult(from: $0, searchQuery: q) })

            case .comicVine:
                let hits = try await ComicVineService.shared.search(query: ebookSearchText(for: q), limit: 40)
                results = sorted(hits.map { makeComicVineResult(from: $0, searchQuery: q) })
            }

            if results.isEmpty, errorMessage == nil {
                errorMessage = "Nothing found."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyiTunes(id: String) async throws -> iTunesMetadataLayer {
        if let cached = cachedITunesResults[id] {
            return iTunesService.shared.toMetadataLayer(cached)
        }
        guard let trackId = Int(id) else {
            throw MatchesError("Invalid iTunes track id: \(id)")
        }
        guard let audiobook = try await iTunesService.shared.lookup(id: trackId, country: SettingsManager.shared.audibleCountryCode) else {
            throw MatchesError("iTunes audiobook not found for id \(trackId)")
        }
        return iTunesService.shared.toMetadataLayer(audiobook)
    }

    func applyAudioBookshelf(id: String) async throws -> AudibleMetadataLayer {
        let result = try resultFor(id)
        return AudibleMetadataLayer(
            asin: id,
            title: result.title,
            subtitle: nil,
            author: result.author,
            narrators: nil,
            series: nil,
            seriesNumber: nil,
            description: result.description,
            descriptionPlain: nil,
            coverUrl: result.coverUrl,
            publisher: nil,
            publishedYear: nil,
            releaseDate: nil,
            genres: nil,
            tags: nil,
            rating: nil,
            ratingCount: nil,
            duration: result.duration,
            language: nil,
            format: nil
        )
    }

    func applyEnveSearch(id: String) async throws -> EnveMetadataLayer {
        let result = try resultFor(id)
        let countryCode = SettingsManager.shared.audibleCountryCode
        if let details = try? await AudibleService.shared.getProductDetails(asin: id, countryCode: countryCode) {
            return EnveMetadataLayer(
                enveId: details.asin ?? id,
                title: details.title ?? result.title,
                author: details.author ?? result.author,
                narrator: details.narrators?.joined(separator: ", "),
                publisher: details.publisher,
                releaseYear: details.publishedYear,
                isbn: nil,
                asin: details.asin ?? id,
                coverUrl: details.coverUrl ?? result.coverUrl,
                duration: details.duration ?? result.duration,
                tags: details.tags,
                description: details.descriptionPlain ?? details.description ?? result.description,
                seriesName: details.series,
                seriesPosition: details.seriesNumber
            )
        }
        return EnveMetadataLayer(
            enveId: id,
            title: result.title,
            author: result.author,
            narrator: nil,
            publisher: nil,
            releaseYear: nil,
            isbn: nil,
            asin: id,
            coverUrl: result.coverUrl,
            duration: result.duration,
            tags: nil,
            description: result.description,
            seriesName: result.seriesName,
            seriesPosition: result.seriesPosition
        )
    }

    func applyGoogleBooks(id: String) async throws -> GoogleBooksMetadataLayer {
        let result = try resultFor(id)
        do {
            let hits = try await GoogleBooksService.shared.search(
                query: result.title,
                author: result.author,
                isbn: result.id,
                limit: 10
            )
            if let exact = hits.first(where: { ($0.isbn ?? "") == result.id }) { return exact }
            if let first = hits.first { return first }
        } catch GoogleBooksService.SearchError.rateLimited {
        } catch let GoogleBooksService.SearchError.httpStatus(code) where [500, 502, 503, 504].contains(code) {}
        return GoogleBooksMetadataLayer(
            isbn: nil,
            title: result.title,
            subtitle: nil,
            authors: result.author.map { [$0] },
            publisher: result.publisher,
            publishedDate: result.publishedYear.map(String.init),
            description: result.description,
            pageCount: result.pageCount,
            categories: nil,
            averageRating: nil,
            ratingsCount: nil,
            imageLinks: nil,
            language: nil
        )
    }

    func applyOpenLibrary(id: String) async throws -> OpenLibraryMetadataLayer {
        let result = try resultFor(id)
        let docs = try await OpenLibraryService.shared.search(
            query: [result.title, result.author].compactMap { $0 }.joined(separator: " "),
            limit: 10
        )
        if let doc = docs.first(where: { $0.key == id }) {
            var layer = OpenLibraryService.shared.toMetadataLayer(doc)
            if let workKey = layer.workKey {
                layer.description = try? await OpenLibraryService.shared.getWorkDescription(workKey: workKey)
            }
            return layer
        }
        return OpenLibraryMetadataLayer(
            workKey: id,
            title: result.title,
            authors: result.author.map { [$0] },
            publisher: result.publisher,
            publishedYear: result.publishedYear,
            isbn: nil,
            coverUrl: result.coverUrl,
            subjects: nil,
            language: nil,
            pageCount: result.pageCount,
            description: result.description,
            seriesName: result.seriesName,
            seriesNumber: result.seriesPosition.flatMap(Int.init),
            seriesSequence: result.seriesPosition
        )
    }

    func applyComicVine(id: String) async throws -> ComicVineMetadataLayer {
        let result = try resultFor(id)
        let hits = try await ComicVineService.shared.search(
            query: [result.title, result.author].compactMap { $0 }.joined(separator: " "),
            limit: 10
        )
        if let exact = hits.first(where: { String($0.comicVineId) == id }) { return exact }
        if let first = hits.first { return first }
        return ComicVineMetadataLayer(
            comicVineId: Int(id) ?? 0,
            title: result.title,
            authors: result.author.map { [$0] } ?? [],
            description: result.description,
            coverUrl: result.coverUrl,
            publisher: result.publisher,
            startYear: result.publishedYear.map(String.init),
            issueCount: nil
        )
    }

    private func resultFor(_ id: String) throws -> Result {
        guard let result = results.first(where: { $0.id == id }) else {
            throw MatchesError("Match result not found")
        }
        return result
    }

    func startPreview(book: Book) async {
        guard !isStartingPreview else { return }
        let requestID = UUID()
        previewRequestID = requestID
        previewError = nil
        isStartingPreview = true
        defer { isStartingPreview = false }

        stopPreview(clearStartingState: false)
        previewRequestID = requestID

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)

        do {
            guard let stream = try await matches.previewStream(for: book, audiobookshelfBackend: audiobookshelfBackend) else {
                previewError = "Couldn't reach a stream for the preview."
                return
            }

            let item: AVPlayerItem
            if stream.headers.isEmpty {
                item = AVPlayerItem(url: stream.url)
            } else {
                let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
                item = AVPlayerItem(asset: asset)
            }

            let player = AVPlayer(playerItem: item)
            player.volume = 1.0

            for _ in 0..<50 {
                if item.status == .readyToPlay { break }
                if item.status == .failed {
                    previewError = item.error?.localizedDescription ?? "The player failed."
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            _ = await player.seek(to: .zero)
            player.play()

            guard previewRequestID == requestID else {
                player.pause()
                return
            }

            previewPlayer = player
            isPreviewPlaying = true

            let work = DispatchWorkItem { [weak self, weak player] in
                player?.pause()
                Task { @MainActor in
                    self?.isPreviewPlaying = false
                    self?.previewPlayer = nil
                }
            }
            previewStopWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
        } catch {
            previewError = "Preview failed: \(error.localizedDescription)"
            stopPreview()
        }
    }

    func stopPreview() {
        stopPreview(clearStartingState: true)
    }

    private func stopPreview(clearStartingState: Bool) {
        previewRequestID = UUID()
        previewStopWorkItem?.cancel()
        previewStopWorkItem = nil
        previewPlayer?.pause()
        previewPlayer = nil
        isPreviewPlaying = false
        if clearStartingState {
            isStartingPreview = false
        }
    }

    private func sorted(_ items: [Result]) -> [Result] {
        items.sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }
    }

    private func ebookScoringMetadata(for searchQuery: String) -> FileMetadataLayer {
        FileMetadataLayer(
            title: searchQuery,
            author: nil,
            narrator: nil,
            series: nil,
            seriesNumber: fileMetadata.seriesNumber,
            year: nil,
            publisher: nil,
            genres: nil,
            description: nil,
            duration: nil,
            isbn: fileMetadata.isbn,
            asin: nil,
            fileName: nil,
            folderName: nil,
            coverPath: nil,
            copyright: nil,
            language: nil,
            encodingTool: nil
        )
    }

    private func makeITunesResult(from audiobook: iTunesAudiobook) -> Result {
        let score = MatchingUtils.calculateScore(file: fileMetadata, iTunes: audiobook)
        return Result(
            id: String(audiobook.id ?? 0),
            title: audiobook.trackCensoredName ?? audiobook.trackName ?? audiobook.collectionCensoredName ?? audiobook.collectionName ?? "",
            author: audiobook.artistName,
            publisher: audiobook.artistName,
            publishedYear: nil,
            pageCount: nil,
            seriesName: nil,
            seriesPosition: nil,
            coverUrl: audiobook.artworkUrl100,
            duration: audiobook.trackTimeMillis.map { TimeInterval($0) / 1000 },
            source: .iTunes,
            confidence: score.total,
            description: audiobook.description ?? audiobook.longDescription
        )
    }

    private func makeAudibleResult(from hit: AudibleSearchResult, source: Source) -> Result {
        let score = MatchingUtils.calculateScore(file: fileMetadata, audible: hit)
        return Result(
            id: hit.asin,
            title: hit.title,
            author: hit.authors.first,
            publisher: nil,
            publishedYear: nil,
            pageCount: nil,
            seriesName: hit.seriesName,
            seriesPosition: hit.seriesPosition,
            coverUrl: hit.coverUrl,
            duration: TimeInterval(hit.duration),
            source: source,
            confidence: score.total,
            description: hit.description
        )
    }

    private func makeGoogleBooksResult(from hit: GoogleBooksMetadataLayer, searchQuery: String) -> Result {
        let score = MatchingUtils.calculateBookScore(
            file: ebookScoringMetadata(for: searchQuery),
            title: hit.title ?? "",
            authors: hit.authors ?? [],
            isbn: hit.isbn
        )
        return Result(
            id: hit.isbn ?? (hit.title ?? UUID().uuidString),
            title: hit.title ?? "",
            author: hit.authors?.first,
            publisher: hit.publisher,
            publishedYear: hit.publishedDate.flatMap { Int($0.prefix(4)) },
            pageCount: hit.pageCount,
            seriesName: nil,
            seriesPosition: nil,
            coverUrl: hit.imageLinks?.large ?? hit.imageLinks?.medium ?? hit.imageLinks?.thumbnail,
            duration: nil,
            source: .googleBooks,
            confidence: score.total,
            description: hit.description
        )
    }

    private func makeOpenLibraryResult(from doc: OpenLibraryDoc, searchQuery: String) -> Result {
        let series = OpenLibraryService.shared.seriesInfo(title: doc.title, subjects: doc.subject)
        let score = MatchingUtils.calculateBookScore(
            file: ebookScoringMetadata(for: searchQuery),
            title: doc.title ?? "",
            authors: doc.authorName ?? [],
            isbn: doc.isbn?.first
        )
        return Result(
            id: doc.key ?? UUID().uuidString,
            title: doc.title ?? "",
            author: doc.authorName?.first,
            publisher: doc.publisher?.first,
            publishedYear: doc.firstPublishYear,
            pageCount: doc.numberOfPagesMedian,
            seriesName: series.name,
            seriesPosition: series.sequence,
            coverUrl: doc.coverI.map { OpenLibraryService.shared.coverURL(coverId: $0, size: "L") },
            duration: nil,
            source: .openLibrary,
            confidence: score.total,
            description: nil
        )
    }

    private func makeComicVineResult(from hit: ComicVineMetadataLayer, searchQuery: String) -> Result {
        let score = MatchingUtils.calculateBookScore(
            file: ebookScoringMetadata(for: searchQuery),
            title: hit.title,
            authors: hit.authors,
            isbn: nil
        )
        return Result(
            id: String(hit.comicVineId),
            title: hit.title,
            author: hit.authors.first,
            publisher: hit.publisher,
            publishedYear: hit.startYear.flatMap { Int($0.prefix(4)) },
            pageCount: nil,
            seriesName: nil,
            seriesPosition: nil,
            coverUrl: hit.coverUrl,
            duration: nil,
            source: .comicVine,
            confidence: score.total,
            description: hit.description
        )
    }

    private static func matchesNormalizeQuery(_ input: String) -> String {
        var result = input
        for pattern in ["\\[[^\\]]*\\]", "\\([^)]*\\)", "\\{[^}]*\\}", "\\s+"] {
            result = result.replacingOccurrences(
                of: pattern,
                with: pattern == "\\s+" ? " " : "",
                options: .regularExpression
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func googleBooksQuery(for query: String) -> (query: String, author: String?, isbn: String?) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = MatchingUtils.parseTitleAndAuthor(from: trimmedQuery)
        let author = parsed.author ?? fileMetadata.author?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let isbn = fileMetadata.isbn?.trimmingCharacters(in: .whitespacesAndNewlines), !isbn.isEmpty,
            trimmedQuery.isEmpty
                || parsed.title.caseInsensitiveCompare(fileMetadata.title ?? "") == .orderedSame
                || trimmedQuery.caseInsensitiveCompare(fileMetadata.title ?? "") == .orderedSame
        {
            return (parsed.title, author, isbn)
        }
        return (parsed.title, author?.isEmpty == false ? author : nil, nil)
    }

    private func ebookSearchText(for query: String) -> String {
        let parsed = MatchingUtils.parseTitleAndAuthor(from: query)
        if let author = parsed.author {
            return "\(parsed.title) \(author)"
        }
        if let author = fileMetadata.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            return "\(parsed.title) \(author)"
        }
        return parsed.title
    }
}

struct MatchesError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
