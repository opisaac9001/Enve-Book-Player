import Foundation
import Logging

extension Notification.Name {
    static let metadataUpdated = Notification.Name("metadataUpdated")
}

class MetadataManager {
    static let shared = MetadataManager()

    private init() {}

    nonisolated func mergeMetadata(_ metadata: BookMetadata) -> MergedMetadata {
        let backend = metadata.backend
        let file = metadata.file
        let googleBooks = metadata.googleBooks
        let iTunes = metadata.iTunes
        let enve = metadata.enve
        let audible = metadata.audible
        _ = metadata.appCache
        let userOverrides = metadata.userOverrides

        func getValue<T>(
            userValue: T?,
            enveValue: T?,
            audibleValue: T?,
            iTunesValue: T?,
            googleBooksValue: T?,
            openLibraryValue: T? = nil,
            embeddedFileValue: T?,
            backendValue: T?
        ) -> (value: T?, source: MetadataSource) {
            if let user = userValue {
                return (user, .userOverrides)
            }
            if let enveVal = enveValue {
                return (enveVal, .enve)
            }
            if let aud = audibleValue {
                return (aud, .audible)
            }
            if let itunes = iTunesValue {
                return (itunes, .iTunes)
            }
            if let google = googleBooksValue {
                return (google, .googleBooks)
            }
            if let openLib = openLibraryValue {
                return (openLib, .openLibrary)
            }
            if let embedded = embeddedFileValue {
                return (embedded, .file)
            }
            if let back = backendValue {
                return (back, .backend)
            }
            return (nil, .backend)
        }

        let titleResult = getValue(
            userValue: userOverrides?.customTitle,
            enveValue: enve?.title,
            audibleValue: audible?.title,
            iTunesValue: iTunes?.title,
            googleBooksValue: googleBooks?.title,
            openLibraryValue: nil,
            embeddedFileValue: file.title,
            backendValue: backend?.title
        )
        let title = titleResult.value ?? backend?.title ?? "Unknown Title"

        let authorResult = getValue(
            userValue: userOverrides?.customAuthor,
            enveValue: enve?.author,
            audibleValue: audible?.author,
            iTunesValue: iTunes?.authors?.first,
            googleBooksValue: googleBooks?.authors?.first,
            openLibraryValue: nil,
            embeddedFileValue: file.author,
            backendValue: backend?.author
        )
        let author = authorResult.value ?? backend?.author ?? "Unknown Author"

        let narratorResult: (value: String?, source: MetadataSource)
        if let customNarrator = userOverrides?.customNarrator {
            narratorResult = (customNarrator, .userOverrides)
        } else if let enveNarrator = enve?.narrator {
            narratorResult = (enveNarrator, .enve)
        } else if let audibleNarrators = audible?.narrators, !audibleNarrators.isEmpty {
            narratorResult = (audibleNarrators[0], .audible)
        } else if let iTunesNarrator = iTunes?.narrator {
            narratorResult = (iTunesNarrator, .iTunes)
        } else if let embeddedNarrator = file.narrator {
            narratorResult = (embeddedNarrator, .file)
        } else if let backendNarrator = backend?.narrator {
            narratorResult = (backendNarrator, .backend)
        } else {
            narratorResult = (nil, .backend)
        }

        let seriesResult = getValue(
            userValue: userOverrides?.customSeries,
            enveValue: enve?.seriesName,
            audibleValue: audible?.series,
            iTunesValue: nil,
            googleBooksValue: nil,
            embeddedFileValue: file.series,
            backendValue: backend?.series
        )

        let seriesNumberResult: (value: Int?, source: MetadataSource)
        if let customNumber = userOverrides?.customSeriesNumber {
            seriesNumberResult = (customNumber, .userOverrides)
        } else if let envePosition = enve?.seriesPosition {
            let extracted: Int? = {
                let trimmed = envePosition.trimmingCharacters(in: .whitespacesAndNewlines)
                if let direct = Int(trimmed) { return direct }
                if let range = trimmed.range(of: #"\d+"#, options: .regularExpression) {
                    return Int(trimmed[range])
                }
                return nil
            }()
            seriesNumberResult = (extracted, extracted != nil ? .enve : .backend)
        } else if let audibleNumber = audible?.seriesNumber, let intValue = Int(audibleNumber) {
            seriesNumberResult = (intValue, .audible)
        } else if let embeddedNumber = file.seriesNumber {
            seriesNumberResult = (embeddedNumber, .file)
        } else if let backendNumber = backend?.seriesNumber {
            seriesNumberResult = (backendNumber, .backend)
        } else {
            seriesNumberResult = (nil, .backend)
        }

        let descriptionResult: (value: String?, source: MetadataSource)
        if let userDesc = userOverrides?.customDescription, !userDesc.isEmpty {
            descriptionResult = (userDesc, .userOverrides)
        } else if let enveDesc = enve?.description {
            descriptionResult = (enveDesc, .enve)
        } else if let audibleDesc = audible?.descriptionPlain ?? audible?.description {
            descriptionResult = (audibleDesc, .audible)
        } else if let iTunesDesc = iTunes?.description, !iTunesDesc.isEmpty {
            descriptionResult = (iTunesDesc, .iTunes)
        } else if let googleDesc = googleBooks?.description {
            descriptionResult = (googleDesc, .googleBooks)
        } else if let embeddedDesc = file.description {
            descriptionResult = (embeddedDesc, .file)
        } else if let backendDesc = backend?.description {
            descriptionResult = (backendDesc, .backend)
        } else {
            descriptionResult = (nil, .backend)
        }

        let durationResult: (value: TimeInterval?, source: MetadataSource)
        if let embeddedDuration = file.duration, embeddedDuration > 0 {
            durationResult = (embeddedDuration, .file)
        } else if let backendDuration = backend?.duration, backendDuration > 0 {
            durationResult = (backendDuration, .backend)
        } else if let enveDuration = enve?.duration, enveDuration > 0 {
            durationResult = (enveDuration, .enve)
        } else if let audibleDuration = audible?.duration, audibleDuration > 0 {
            durationResult = (audibleDuration, .audible)
        } else if let iTunesDuration = iTunes?.duration, iTunesDuration > 0 {
            durationResult = (iTunesDuration, .iTunes)
        } else {
            durationResult = (nil, .backend)
        }

        let coverResult: (value: String?, source: MetadataSource)
        if let customCover = userOverrides?.customCoverPath {
            coverResult = (customCover, .userOverrides)
        } else if let enveCover = enve?.coverUrl {
            coverResult = (enveCover, .enve)
        } else if let audibleCover = audible?.coverUrl {
            coverResult = (audibleCover, .audible)
        } else if let iTunesCover = iTunes?.artworkURL {
            coverResult = (iTunesCover, .iTunes)
        } else if let googleCover = googleBooks?.imageLinks?.large ?? googleBooks?.imageLinks?.medium ?? googleBooks?.imageLinks?.thumbnail
        {
            coverResult = (googleCover, .googleBooks)
        } else if let fileCover = file.coverPath, !fileCover.isEmpty,
            !fileCover.hasPrefix("/") || FileManager.default.fileExists(atPath: fileCover)
        {
            coverResult = (fileCover, .file)
        } else if let backendThumb = backend?.thumb, !backendThumb.isEmpty {
            coverResult = (backendThumb, .backend)
        } else {
            coverResult = (nil, .backend)
        }

        let publisherResult = getValue(
            userValue: userOverrides?.customPublisher,
            enveValue: enve?.publisher,
            audibleValue: audible?.publisher,
            iTunesValue: iTunes?.publisher,
            googleBooksValue: googleBooks?.publisher,
            embeddedFileValue: file.publisher,
            backendValue: backend?.publisher
        )

        let yearResult: (value: Int?, source: MetadataSource)
        if let enveYear = enve?.releaseYear {
            yearResult = (enveYear, .enve)
        } else if let audibleYear = audible?.publishedYear {
            yearResult = (audibleYear, .audible)
        } else if let iTunesYear = iTunes?.publishedDate.flatMap({ Self.extractYear(from: $0) }) {
            yearResult = (iTunesYear, .iTunes)
        } else if let googleYear = googleBooks?.publishedDate.flatMap({ Self.extractYear(from: $0) }) {
            yearResult = (googleYear, .googleBooks)
        } else if let embeddedYear = file.year {
            yearResult = (embeddedYear, .file)
        } else if let backendYear = backend?.year {
            yearResult = (backendYear, .backend)
        } else {
            yearResult = (nil, .backend)
        }

        let genresResult: (value: [String]?, source: MetadataSource)
        if let userGenres = userOverrides?.customGenres, !userGenres.isEmpty {
            genresResult = (userGenres, .userOverrides)
        } else if let enveTags = enve?.tags, !enveTags.isEmpty {
            genresResult = (enveTags, .enve)
        } else if let audibleGenres = audible?.genres, !audibleGenres.isEmpty {
            genresResult = (audibleGenres, .audible)
        } else if let iTunesGenre = iTunes?.genre {
            genresResult = ([iTunesGenre], .iTunes)
        } else if let googleGenres = googleBooks?.categories, !googleGenres.isEmpty {
            genresResult = (googleGenres, .googleBooks)
        } else if let embeddedGenres = file.genres, !embeddedGenres.isEmpty {
            genresResult = (embeddedGenres, .file)
        } else if let backendGenres = backend?.genres, !backendGenres.isEmpty {
            genresResult = (backendGenres, .backend)
        } else {
            genresResult = (nil, .backend)
        }

        let isbn = googleBooks?.isbn ?? enve?.isbn ?? file.isbn ?? backend?.isbn

        let asin = audible?.asin ?? enve?.asin ?? file.asin ?? backend?.asin

        let rating = audible?.rating ?? googleBooks?.averageRating

        var tags: [String]? = nil
        if let userTags = userOverrides?.userTags, !userTags.isEmpty {
            tags = userTags
            if let audibleTags = audible?.tags, !audibleTags.isEmpty {
                tags?.append(contentsOf: audibleTags)
            }
        } else if let audibleTags = audible?.tags {
            tags = audibleTags
        }

        let notes = userOverrides?.notes

        let sources = MetadataSources(
            title: titleResult.source,
            author: authorResult.source,
            narrator: narratorResult.source,
            series: seriesResult.source,
            cover: coverResult.source,
            description: descriptionResult.source,
            duration: durationResult.source
        )

        let titleMode = UserPreferences.TitleDisplayMode.stripPrefix
        let normalizedTitle = TitleNormalizer.normalize(title, mode: titleMode)

        return MergedMetadata(
            title: normalizedTitle,
            author: author,
            narrator: narratorResult.value,
            series: seriesResult.value,
            seriesNumber: seriesNumberResult.value,
            description: descriptionResult.value,
            duration: durationResult.value,
            coverUrl: coverResult.value,
            publisher: publisherResult.value,
            publishedYear: yearResult.value,
            genres: genresResult.value,
            isbn: isbn,
            asin: asin,
            rating: rating,
            tags: tags,
            notes: notes,
            sources: sources
        )
    }

    nonisolated private static func extractYear(from dateString: String) -> Int? {
        let formatters: [DateFormatter] = [
            {
                let f = DateFormatter(); f.dateFormat = "yyyy"; return f
            }(),
            {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
            }(),
            {
                let f = DateFormatter(); f.dateFormat = "MM/dd/yyyy"; return f
            }(),
            {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f
            }(),
        ]

        for formatter in formatters {
            if let date = formatter.date(from: dateString) {
                let calendar = Calendar.current
                return calendar.component(.year, from: date)
            }
        }

        let yearPattern = #"\b(19|20)\d{2}\b"#
        if let range = dateString.range(of: yearPattern, options: .regularExpression) {
            if let year = Int(String(dateString[range])) {
                return year
            }
        }

        return nil
    }

    func updateUserOverrides(
        bookId: String,
        overrides: UserOverridesLayer,
        completion: @escaping (Result<BookMetadata, Error>) -> Void
    ) {
        Task {
            do {
                var metadata =
                    try await MetadataStorage.shared.loadMetadata(bookId: bookId)
                    ?? BookMetadata(bookId: bookId, file: FileMetadataLayer())

                metadata.userOverrides = overrides
                metadata.lastUpdated = Date()

                try await MetadataStorage.shared.saveMetadata(metadata)

                NotificationCenter.default.post(name: .metadataUpdated, object: bookId)

                await MainActor.run {
                    completion(.success(metadata))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    func updateAppCache(
        bookId: String,
        cache: AppCacheMetadataLayer,
        completion: @escaping (Result<BookMetadata, Error>) -> Void
    ) {
        Task {
            do {
                var metadata =
                    try await MetadataStorage.shared.loadMetadata(bookId: bookId)
                    ?? BookMetadata(bookId: bookId, file: FileMetadataLayer())

                metadata.appCache = cache
                metadata.lastUpdated = Date()

                try await MetadataStorage.shared.saveMetadata(metadata)

                NotificationCenter.default.post(name: .metadataUpdated, object: bookId)

                await MainActor.run {
                    completion(.success(metadata))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    func updateAudibleMetadata(
        bookId: String,
        audible: AudibleMetadataLayer,
        completion: @escaping (Result<BookMetadata, Error>) -> Void
    ) {
        Task {
            do {
                var metadata =
                    try await MetadataStorage.shared.loadMetadata(bookId: bookId)
                    ?? BookMetadata(bookId: bookId, file: FileMetadataLayer())

                metadata.audible = audible
                metadata.lastUpdated = Date()

                try await MetadataStorage.shared.saveMetadata(metadata)

                NotificationCenter.default.post(name: .metadataUpdated, object: bookId)

                await MainActor.run {
                    completion(.success(metadata))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    func updateiTunesMetadata(
        bookId: String,
        iTunes: iTunesMetadataLayer,
        completion: @escaping (Result<BookMetadata, Error>) -> Void
    ) {
        Task {
            do {
                var metadata =
                    try await MetadataStorage.shared.loadMetadata(bookId: bookId)
                    ?? BookMetadata(bookId: bookId, file: FileMetadataLayer())

                metadata.iTunes = iTunes
                metadata.lastUpdated = Date()

                try await MetadataStorage.shared.saveMetadata(metadata)

                NotificationCenter.default.post(name: .metadataUpdated, object: bookId)

                await MainActor.run {
                    completion(.success(metadata))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    func updateGoogleBooksMetadata(
        bookId: String,
        google: GoogleBooksMetadataLayer,
        completion: @escaping (Result<BookMetadata, Error>) -> Void
    ) {
        Task {
            do {
                var metadata =
                    try await MetadataStorage.shared.loadMetadata(bookId: bookId)
                    ?? BookMetadata(bookId: bookId, file: FileMetadataLayer())

                metadata.googleBooks = google
                metadata.lastUpdated = Date()

                try await MetadataStorage.shared.saveMetadata(metadata)

                NotificationCenter.default.post(name: .metadataUpdated, object: bookId)

                await MainActor.run {
                    completion(.success(metadata))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    func updateOpenLibraryMetadata(
        bookId: String,
        openLibrary: OpenLibraryMetadataLayer,
        completion: @escaping (Result<BookMetadata, Error>) -> Void
    ) {
        Task {
            do {
                var metadata =
                    try await MetadataStorage.shared.loadMetadata(bookId: bookId)
                    ?? BookMetadata(bookId: bookId, file: FileMetadataLayer())

                let merged = matchesMergeOverrides(
                    existing: metadata.userOverrides,
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
                metadata.userOverrides = merged
                metadata.lastUpdated = Date()

                try await MetadataStorage.shared.saveMetadata(metadata)

                NotificationCenter.default.post(name: .metadataUpdated, object: bookId)

                await MainActor.run {
                    completion(.success(metadata))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    func updateEnveMetadata(
        bookId: String,
        enve: EnveMetadataLayer,
        completion: @escaping (Result<BookMetadata, Error>) -> Void
    ) {
        Task {
            do {
                var metadata =
                    try await MetadataStorage.shared.loadMetadata(bookId: bookId)
                    ?? BookMetadata(bookId: bookId, file: FileMetadataLayer())

                metadata.enve = enve
                metadata.lastUpdated = Date()

                try await MetadataStorage.shared.saveMetadata(metadata)

                NotificationCenter.default.post(name: .metadataUpdated, object: bookId)

                await MainActor.run {
                    completion(.success(metadata))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Fills only missing backend fields so server metadata keeps priority.
    nonisolated func recordStreamExtractedMetadata(for book: Book) async {
        var metadata = await loadMetadata(for: book, readOnly: true)
        metadata.backend = Self.backendLayer(fillingGapsIn: metadata.backend, from: book)
        try? await MetadataStorage.shared.saveMetadata(metadata)
    }

    nonisolated static func backendLayer(
        fillingGapsIn existing: BackendMetadataLayer?,
        from book: Book
    ) -> BackendMetadataLayer {
        var backend =
            existing
            ?? BackendMetadataLayer(
                title: book.title,
                author: book.author,
                narrator: book.narrator,
                series: book.series,
                seriesNumber: book.seriesNumber,
                year: book.publishedYear,
                publisher: book.publisher,
                genres: book.genres,
                duration: book.duration,
                isbn: book.isbn,
                asin: book.asin
            )

        if backend.description == nil, let value = book.description, !value.isEmpty { backend.description = value }
        if backend.narrator == nil, let value = book.narrator, !value.isEmpty { backend.narrator = value }
        if backend.series == nil, let value = book.series, !value.isEmpty { backend.series = value }
        if backend.genres?.isEmpty ?? true, let value = book.genres, !value.isEmpty { backend.genres = value }
        if backend.publisher == nil, let value = book.publisher, !value.isEmpty { backend.publisher = value }
        if backend.isbn == nil, let value = book.isbn, !value.isEmpty { backend.isbn = value }
        if backend.asin == nil, let value = book.asin, !value.isEmpty { backend.asin = value }

        return backend
    }

    nonisolated static func refreshedBackendLayer(
        from book: Book,
        preserving existing: BackendMetadataLayer?
    ) -> BackendMetadataLayer {
        BackendMetadataLayer(
            title: book.title,
            author: book.author,
            narrator: book.narrator,
            series: book.series,
            seriesNumber: book.seriesNumber,
            year: book.publishedYear,
            publisher: book.publisher,
            genres: book.genres,
            description: book.description,
            duration: book.duration,
            isbn: book.isbn,
            asin: book.asin,
            fileName: existing?.fileName,
            folderName: existing?.folderName,
            chapters: existing?.chapters,
            thumb: book.thumb
        )
    }

    nonisolated func loadMetadata(for book: Book, readOnly: Bool = false) async -> BookMetadata {
        let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)
        do {
            for candidateId in Array(Set([book.id, book.stableId])) {
                guard var loaded = try await MetadataStorage.shared.loadMetadata(bookId: candidateId) else {
                    continue
                }
                if let actual = book.duration {
                    if var backend = loaded.backend {
                        let current = backend.duration
                        let needsUpdate: Bool
                        if let current {
                            needsUpdate = abs(current - actual) > 1
                        } else {
                            needsUpdate = true
                        }

                        if needsUpdate {
                            backend.duration = actual
                            loaded.backend = backend
                            loaded.lastUpdated = Date()
                            if !readOnly {
                                try? await MetadataStorage.shared.saveMetadata(loaded)
                            }
                        }
                    } else if !readOnly {
                        let backend = BackendMetadataLayer(
                            title: nil,
                            author: nil,
                            narrator: nil,
                            series: nil,
                            seriesNumber: nil,
                            year: nil,
                            publisher: nil,
                            genres: nil,
                            description: nil,
                            duration: actual,
                            isbn: nil,
                            asin: nil,
                            fileName: nil,
                            folderName: nil,
                            thumb: nil
                        )
                        loaded.backend = backend
                        loaded.lastUpdated = Date()
                        try? await MetadataStorage.shared.saveMetadata(loaded)
                    }
                }
                return loaded
            }
        } catch {
            AppLogger.network.error("Error loading metadata bookId=\(diagnosticID): \(error)")
        }
        let initialized = initializeBookMetadata(from: book)
        if !readOnly {
            do {
                try await MetadataStorage.shared.saveMetadata(initialized)
            } catch {
                AppLogger.network.error("Failed to persist initialized metadata bookId=\(diagnosticID): \(error)")
            }
        }
        return initialized
    }

    nonisolated private func hasMeaningfulFileMetadata(_ file: FileMetadataLayer) -> Bool {
        if let title = file.title, !title.isEmpty { return true }
        if let author = file.author, !author.isEmpty { return true }
        if let narrator = file.narrator, !narrator.isEmpty { return true }
        if let series = file.series, !series.isEmpty { return true }
        if let publisher = file.publisher, !publisher.isEmpty { return true }
        if let description = file.description, !description.isEmpty { return true }
        if let isbn = file.isbn, !isbn.isEmpty { return true }
        if let asin = file.asin, !asin.isEmpty { return true }
        if let genres = file.genres, !genres.isEmpty { return true }
        if let coverPath = file.coverPath, !coverPath.isEmpty { return true }
        return false
    }

    nonisolated func initializeBookMetadata(from book: Book) -> BookMetadata {
        let folderName = book.filePath.flatMap { path -> String? in
            let url = URL(fileURLWithPath: path)
            return url.deletingLastPathComponent().lastPathComponent
        }
        let fileName = book.filePath.flatMap { path -> String? in
            let url = URL(fileURLWithPath: path)
            return url.deletingPathExtension().lastPathComponent
        }

        let file = FileMetadataLayer(
            title: nil,
            author: nil,
            narrator: nil,
            series: nil,
            seriesNumber: nil,
            year: nil,
            publisher: nil,
            genres: nil,
            description: nil,
            duration: book.duration,
            isbn: nil,
            asin: nil,
            fileName: fileName,
            folderName: folderName
        )

        let backend = BackendMetadataLayer(
            title: book.title,
            author: book.author,
            narrator: book.narrator,
            series: book.series,
            seriesNumber: book.seriesNumber,
            year: book.publishedYear,
            publisher: book.publisher,
            genres: book.genres,
            description: book.description,
            duration: book.duration,
            isbn: book.isbn,
            asin: book.asin,
            fileName: fileName,
            folderName: folderName,
            thumb: book.thumb
        )

        return BookMetadata(bookId: book.id, file: file, backend: backend)
    }

    nonisolated func enrichBookWithStoredMetadata(_ book: Book) async -> Book {
        var metadata = await loadMetadata(for: book, readOnly: true)
        metadata.backend = Self.refreshedBackendLayer(from: book, preserving: metadata.backend)

        let cachedChapters = metadata.backend?.chapters
        let hasFileMetadata = hasMeaningfulFileMetadata(metadata.file)

        guard
            metadata.audible != nil || metadata.googleBooks != nil || metadata.iTunes != nil || metadata.enve != nil
                || metadata.userOverrides != nil || cachedChapters != nil || hasFileMetadata
        else {
            return book
        }

        let merged = mergeMetadata(metadata)

        let resolvedTitle: String = {
            if let customTitle = metadata.userOverrides?.customTitle,
                !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return customTitle
            }

            if book.source == .booklore && book.mediaType == .audiobook {
                return book.title
            }

            return merged.title.isEmpty || merged.title == "Unknown Title" ? book.title : merged.title
        }()
        let resolvedAuthor: String? = {
            if !merged.author.isEmpty, merged.author != "Unknown Author" { return merged.author }
            return book.author
        }()
        let resolvedNarrator: String? = {
            if let n = merged.narrator, !n.isEmpty { return n }
            return book.narrator
        }()
        let resolvedSeries: String? = {
            if let s = merged.series, !s.isEmpty { return s }
            return book.series
        }()
        let resolvedSeriesNumber = merged.seriesNumber ?? book.seriesNumber
        let resolvedSeriesSequence: String? = {
            if let seq = metadata.userOverrides?.customSeriesSequence { return seq }
            return book.seriesSequence ?? resolvedSeriesNumber.map(String.init)
        }()
        let resolvedCover: String? = {
            if let cover = merged.coverUrl {
                if cover.hasPrefix("/") && !FileManager.default.fileExists(atPath: cover) {
                    return book.thumb
                }
                return cover
            }
            return book.thumb
        }()
        let normalizedDescription = DescriptionNormalizer.normalize(merged.description ?? book.description)
        let resolvedChapters: [Chapter]? = {
            let bookChapters = book.chapters ?? []
            guard let cachedChapters, cachedChapters.count > bookChapters.count else {
                return bookChapters.isEmpty ? cachedChapters : bookChapters
            }
            return cachedChapters
        }()

        var enriched = Book(
            id: book.id,
            ratingKey: book.ratingKey,
            title: resolvedTitle,
            author: resolvedAuthor,
            narrator: resolvedNarrator,
            thumb: resolvedCover,
            partKey: book.partKey,
            duration: merged.duration ?? book.duration,
            chapters: resolvedChapters,
            currentChapterIndex: book.currentChapterIndex,
            source: book.source,
            backendId: book.backendId,
            trackIndex: book.trackIndex,
            filePath: book.filePath,
            audioFileIno: book.audioFileIno,
            audioFileInos: book.audioFileInos,
            audioTracks: book.audioTracks,
            isPodcastEpisode: book.isPodcastEpisode,
            episodeId: book.episodeId,
            podcastLibraryItemId: book.podcastLibraryItemId,
            podcastName: book.podcastName,
            mediaType: book.mediaType,
            ebookFormat: book.ebookFormat,
            epubLocator: book.epubLocator,
            ebookProgress: book.ebookProgress,
            ebookFileURL: book.ebookFileURL,
            linkedAudiobookStableId: book.linkedAudiobookStableId,
            linkedAudiobookChapterOffset: book.linkedAudiobookChapterOffset,
            hideFromContinue: book.hideFromContinue,
            epub3Features: book.epub3Features,
            hasAlternateFormat: book.hasAlternateFormat,
            description: normalizedDescription,
            series: resolvedSeries,
            seriesNumber: resolvedSeriesNumber,
            publishedYear: merged.publishedYear,
            genres: merged.genres,
            publisher: merged.publisher,
            isbn: merged.isbn,
            asin: merged.asin,
            addedAt: book.addedAt,
            libraryName: book.libraryName,
            backendName: book.backendName,
            copyright: book.copyright,
            language: book.language,
            encodingTool: book.encodingTool,
            progress: book.progress,
            lastPlayed: book.lastPlayed,
            currentTime: book.currentTime,
            isFinished: book.isFinished,
            lastUpdate: book.lastUpdate,
            providerId: book.providerId,
            libraryId: book.libraryId
        )
        enriched.seriesSequence = resolvedSeriesSequence
        return enriched
    }

    nonisolated func enrichBooksWithStoredMetadata(_ books: [Book]) async -> [Book] {
        guard !books.isEmpty else { return [] }

        let batchSize = 50
        guard books.count > batchSize else {
            return await withTaskGroup(of: (Int, Book).self) { group in
                for (index, book) in books.enumerated() {
                    group.addTask {
                        let enriched = await self.enrichBookWithStoredMetadata(book)
                        return (index, enriched)
                    }
                }
                var results: [(Int, Book)] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
        }

        var allResults: [Book] = Array(repeating: books[0], count: books.count)

        for batchStart in stride(from: 0, to: books.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, books.count)
            let batch = Array(books[batchStart..<batchEnd])

            let batchResults = await withTaskGroup(of: (Int, Book).self) { group in
                for (localIndex, book) in batch.enumerated() {
                    group.addTask {
                        let enriched = await self.enrichBookWithStoredMetadata(book)
                        return (localIndex, enriched)
                    }
                }
                var results: [(Int, Book)] = []
                for await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.map { $0.1 }
            }

            for (localIndex, book) in batchResults.enumerated() {
                allResults[batchStart + localIndex] = book
            }

            await Task.yield()
        }

        return allResults
    }
}
