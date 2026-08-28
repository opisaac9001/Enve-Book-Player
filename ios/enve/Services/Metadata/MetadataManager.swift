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

    func extractAndSaveEmbeddedMetadata(for book: Book) async throws {
        let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)
        let existingMetadata = try? await MetadataStorage.shared.loadMetadata(bookId: book.id)

        if let existing = existingMetadata, existing.audible?.asin != nil {
            AppLogger.network.debug("Skipping extraction bookId=\(diagnosticID) - already has external metadata")
            return
        }

        var embeddedMetadata: FileMetadataLayer?
        var embeddedChapters: [Chapter]?

        if book.mediaType == .ebook, let ebookURL = resolveLocalEbookURL(for: book) {
            AppLogger.network.debug("Extracting metadata from ebook file bookId=\(diagnosticID)")
            do {
                let ebookMetadata = try await LocalEbookImporter.shared.extractMetadata(from: ebookURL)
                embeddedMetadata = fileMetadataLayer(from: ebookMetadata, fileURL: ebookURL)
                embeddedChapters = ebookMetadata.chapters?.map {
                    Chapter(id: $0.id, start: $0.startTime, end: $0.endTime, title: $0.title)
                }
                AppLogger.network.debug("Extracted metadata from ebook file bookId=\(diagnosticID)")
            } catch {
                AppLogger.network.error("Failed to extract from ebook file bookId=\(diagnosticID): \(error.localizedDescription)")
            }
        }

        if embeddedMetadata == nil,
            let localFileURL = LocalStorageManager.shared.localAudiobookFileURLIfExists(bookId: book.downloadKey)
        {
            AppLogger.network.debug("Extracting metadata from local file bookId=\(diagnosticID)")
            do {
                embeddedMetadata = try await FileMetadataExtractor.shared.extractMetadata(from: localFileURL)
                AppLogger.network.debug("Extracted metadata from local file bookId=\(diagnosticID)")
            } catch {
                AppLogger.network.error("Failed to extract from local file bookId=\(diagnosticID): \(error.localizedDescription)")
            }
        }

        if embeddedMetadata == nil, book.mediaType == .audiobook {
            AppLogger.network.debug("Attempting remote metadata extraction bookId=\(diagnosticID)")
            do {
                let streamURL = try await getStreamURL(for: book)
                if let streamURL = streamURL {
                    embeddedMetadata = try await FileMetadataExtractor.shared.extractMetadataFromRemoteStream(
                        streamURL: streamURL,
                        timeout: 10.0
                    )
                    AppLogger.network.debug("Extracted metadata from remote stream bookId=\(diagnosticID)")
                }
            } catch {
                AppLogger.network.error("Failed to extract from remote stream bookId=\(diagnosticID): \(error.localizedDescription)")
            }
        }

        guard let embedded = embeddedMetadata else {
            AppLogger.network.debug("Could not extract embedded metadata bookId=\(diagnosticID)")
            return
        }

        var metadata = existingMetadata ?? initializeBookMetadata(from: book)

        mergeFileMetadata(&metadata.file, with: embedded, from: book)

        if metadata.backend == nil {
            let folderName = book.filePath.flatMap { path -> String? in
                let url = URL(fileURLWithPath: path)
                return url.deletingLastPathComponent().lastPathComponent
            }
            let fileName = book.filePath.flatMap { path -> String? in
                let url = URL(fileURLWithPath: path)
                return url.deletingPathExtension().lastPathComponent
            }

            metadata.backend = BackendMetadataLayer(
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
        }

        if let embeddedChapters, !embeddedChapters.isEmpty,
            metadata.backend?.chapters?.isEmpty != false
        {
            metadata.backend?.chapters = embeddedChapters
        }

        if let asin = embedded.asin, !asin.isEmpty {
            let asinDiagnosticID = DiagnosticLogSanitizer.identifier(for: asin)
            AppLogger.network.debug("Found embedded ASIN bookId=\(diagnosticID) asinId=\(asinDiagnosticID)")
            do {
                let countryCode = SettingsManager.shared.audibleCountryCode
                let audibleMetadata = try await AudibleService.shared.getProductDetails(asin: asin, countryCode: countryCode)

                metadata.audible = audibleMetadata
                metadata.lastUpdated = Date()

                AppLogger.network.debug("Fetched and saved external metadata asinId=\(asinDiagnosticID)")
            } catch {
                AppLogger.network.error(
                    "Failed to fetch external metadata asinId=\(asinDiagnosticID): \(error.localizedDescription)"
                )
            }
        }

        metadata.lastUpdated = Date()
        try await MetadataStorage.shared.saveMetadata(metadata)

        await MainActor.run {
            NotificationCenter.default.post(name: .metadataUpdated, object: book.id)
        }

        AppLogger.network.debug("Saved embedded metadata bookId=\(diagnosticID)")
    }

    private func mergeFileMetadata(_ existing: inout FileMetadataLayer, with embedded: FileMetadataLayer, from book: Book) {
        if existing.fileName == nil {
            existing.fileName =
                embedded.fileName
                ?? book.filePath.flatMap { path -> String? in
                    let url = URL(fileURLWithPath: path)
                    return url.deletingPathExtension().lastPathComponent
                }
        }

        if existing.folderName == nil {
            existing.folderName =
                embedded.folderName
                ?? book.filePath.flatMap { path -> String? in
                    let url = URL(fileURLWithPath: path)
                    return url.deletingLastPathComponent().lastPathComponent
                }
        }

        if let title = embedded.title, !title.isEmpty {
            existing.title = title
        }
        if let author = embedded.author, !author.isEmpty {
            existing.author = author
        }
        if let narrator = embedded.narrator, !narrator.isEmpty {
            existing.narrator = narrator
        }
        if let series = embedded.series, !series.isEmpty {
            existing.series = series
        }
        if let seriesNumber = embedded.seriesNumber {
            existing.seriesNumber = seriesNumber
        }
        if let year = embedded.year {
            existing.year = year
        }
        if let publisher = embedded.publisher, !publisher.isEmpty {
            existing.publisher = publisher
        }
        if let genres = embedded.genres, !genres.isEmpty {
            existing.genres = genres
        }
        if let description = embedded.description, !description.isEmpty {
            existing.description = description
        }
        if let isbn = embedded.isbn, !isbn.isEmpty {
            existing.isbn = isbn
        }
        if let asin = embedded.asin, !asin.isEmpty {
            existing.asin = asin
        }
        if let coverPath = embedded.coverPath, !coverPath.isEmpty {
            existing.coverPath = coverPath
        }
        if existing.duration == nil {
            existing.duration = embedded.duration
        }
    }

    private func resolveLocalEbookURL(for book: Book) -> URL? {
        LocalEbookImporter.shared.resolveExistingLocalEbookURL(
            bookIdentifier: book.id,
            ebookFileURL: book.ebookFileURL,
            filePath: book.filePath
        )
    }

    private func fileMetadataLayer(from metadata: LocalBookMetadata, fileURL: URL) -> FileMetadataLayer {
        FileMetadataLayer(
            title: metadata.title,
            author: metadata.author,
            narrator: metadata.narrator,
            series: metadata.series,
            seriesNumber: metadata.seriesNumber,
            year: metadata.publishedYear,
            publisher: metadata.publisher,
            genres: metadata.genres,
            description: metadata.description,
            duration: metadata.duration,
            isbn: metadata.isbn,
            asin: metadata.asin,
            fileName: fileURL.deletingPathExtension().lastPathComponent,
            folderName: fileURL.deletingLastPathComponent().lastPathComponent,
            coverPath: metadata.coverImagePath,
            copyright: metadata.copyright,
            language: metadata.language,
            encodingTool: metadata.encodingTool
        )
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

    private func getStreamURL(for book: Book) async throws -> URL? {
        let plexService = PlexService()
        let audiobookshelfService = AudiobookshelfService()

        switch book.source {
        case .plex:
            guard let token = PlexAuthStore.shared.loadToken() else {
                throw NSError(domain: "MetadataManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing Plex token"])
            }

            let servers = try await plexService.getPlexServers(token: token)
            guard let server = servers.first else {
                throw NSError(domain: "MetadataManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No Plex servers found"])
            }

            let workingServerUrl = await plexService.findBestConnection(server: server)
            guard let serverUrl = workingServerUrl else {
                throw NSError(
                    domain: "MetadataManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not determine working server URL"]
                )
            }

            var partKey = book.partKey
            if partKey == nil || partKey?.isEmpty == true {
                guard let baseURL = URL(string: serverUrl),
                    let url = URL(string: "/library/metadata/\(book.ratingKey)", relativeTo: baseURL)
                else {
                    throw NSError(domain: "MetadataManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
                }

                var request = URLRequest(url: url)
                request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
                request.setValue("application/xml", forHTTPHeaderField: "Accept")

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                    httpResponse.statusCode == 200
                else {
                    throw NSError(domain: "MetadataManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch metadata"])
                }

                partKey = "/library/parts/\(book.ratingKey)"
            }

            guard let finalPartKey = partKey else {
                throw NSError(domain: "MetadataManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No part key available"])
            }

            return plexService.getStreamUrl(
                serverUrl: serverUrl,
                partKey: finalPartKey,
                token: token,
                ratingKey: book.ratingKey
            )

        case .audiobookshelf:
            let backendId = book.backendId ?? book.providerId.uuidString
            guard let backend = AppState.shared.providerConnections.backend(id: backendId) else {
                throw NSError(domain: "MetadataManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing backend configuration"])
            }

            return try await audiobookshelfService.getStreamUrl(
                libraryItemId: book.partKey ?? book.id,
                trackIndex: book.trackIndex ?? 0,
                backend: backend
            )

        case .local:
            if let filePath = book.filePath ?? book.partKey,
                !filePath.isEmpty
            {
                return URL(fileURLWithPath: filePath)
            }
            throw NSError(domain: "MetadataManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No file path for local book"])

        case .smb:
            if let local = LocalStorageManager.shared.localAudiobookFileURLIfExists(bookId: book.downloadKey) {
                return local
            }
            throw NSError(domain: "MetadataManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "SMB book must be downloaded first"])

        case .webdav, .torbox, .booklore, .realdebrid, .komga, .kavita, .opds, .storyteller, .bookOrbit, .silo:
            if let provider = AppState.shared.providerConnections.capability(PlaybackSessionProvider.self, for: book) {
                return provider.getAudioURL(for: book)
            }
            throw NSError(domain: "MetadataManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebDAV provider not available"])

        case .jellyfin, .emby:
            let backendId = book.backendId ?? book.providerId.uuidString
            guard let backend = AppState.shared.providerConnections.backend(id: backendId) else {
                throw NSError(domain: "MetadataManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing backend configuration"])
            }

            return try await audiobookshelfService.getStreamUrl(
                libraryItemId: book.partKey ?? book.id,
                trackIndex: book.trackIndex ?? 0,
                backend: backend
            )
        }
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

    nonisolated func mergeLocalBookMetadata(
        sidecar: LocalBookMetadata?,
        embedded: LocalBookMetadata
    ) -> LocalBookMetadata {
        guard let sidecar = sidecar else {
            return embedded
        }

        return LocalBookMetadata(
            title: sidecar.title.isEmpty ? embedded.title : sidecar.title,
            author: sidecar.author ?? embedded.author,
            narrator: sidecar.narrator ?? embedded.narrator,
            description: sidecar.description ?? embedded.description,
            series: sidecar.series ?? embedded.series,
            seriesNumber: sidecar.seriesNumber ?? embedded.seriesNumber,
            seriesSequence: sidecar.seriesSequence ?? embedded.seriesSequence,
            publishedYear: sidecar.publishedYear ?? embedded.publishedYear,
            genres: (sidecar.genres?.isEmpty == false) ? sidecar.genres : embedded.genres,
            publisher: sidecar.publisher ?? embedded.publisher,
            isbn: sidecar.isbn ?? embedded.isbn,
            asin: sidecar.asin ?? embedded.asin,
            duration: sidecar.duration ?? embedded.duration,
            chapters: (sidecar.chapters?.isEmpty == false) ? sidecar.chapters : embedded.chapters,
            coverImagePath: sidecar.coverImagePath ?? embedded.coverImagePath,
            lastUpdated: Date(),
            metadataVersion: sidecar.metadataVersion
        )
    }

    nonisolated func mergeChapters(
        sidecar: [LocalChapter]?,
        embedded: [LocalChapter]?
    ) -> [LocalChapter]? {
        if let sidecarChapters = sidecar, !sidecarChapters.isEmpty {
            return sidecarChapters
        }
        if let embeddedChapters = embedded, !embeddedChapters.isEmpty {
            return embeddedChapters
        }
        return nil
    }

    func createBookFromLocalMetadata(
        _ metadata: LocalBookMetadata,
        bookFile: LocalBookFile,
        libraryId: String
    ) -> Book {
        let chapters: [Chapter]? = metadata.chapters?.enumerated().map { index, localChapter in
            Chapter(
                id: localChapter.id,
                start: localChapter.startTime,
                end: localChapter.endTime,
                title: localChapter.title
            )
        }

        var book = Book(
            id: bookFile.id,
            ratingKey: bookFile.id,
            title: metadata.title,
            author: metadata.author,
            narrator: metadata.narrator,
            thumb: metadata.coverImagePath,
            partKey: bookFile.filePath,
            duration: metadata.duration,
            chapters: chapters,
            currentChapterIndex: nil,
            source: .local,
            backendId: libraryId,
            trackIndex: 0,
            filePath: bookFile.filePath,
            audioTracks: bookFile.toAudioTracks(),
            epub3Features: metadata.epub3Features,
            description: metadata.description,
            series: metadata.series,
            seriesNumber: metadata.seriesNumber,
            publishedYear: metadata.publishedYear,
            genres: metadata.genres,
            publisher: metadata.publisher,
            isbn: metadata.isbn,
            asin: metadata.asin,
            addedAt: bookFile.extractedAt,
            libraryName: nil,
            backendName: nil,
            progress: nil,
            lastPlayed: nil
        )
        book.seriesSequence = metadata.seriesSequence ?? metadata.seriesNumber.map(String.init)
        return book
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
