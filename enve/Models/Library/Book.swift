import Foundation

nonisolated public struct Book: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    let ratingKey: String
    var title: String
    var author: String?
    var authors: [String]?
    var narrator: String?
    var thumb: String?
    let partKey: String?
    var duration: TimeInterval?
    var chapters: [Chapter]?
    let currentChapterIndex: Int?
    let source: BookSource
    let backendId: String?
    let trackIndex: Int?
    let filePath: String?

    let audioFileIno: String?
    let audioFileInos: [String]?

    let audioTracks: [AudioTrack]?

    var isPodcastEpisode: Bool
    var episodeId: String?
    var podcastLibraryItemId: String?
    var podcastName: String?

    var mediaType: AppMediaType = .audiobook
    var ebookFormat: String?
    var epubLocator: String?
    var ebookProgress: Double?
    var ebookFileURL: URL?
    var linkedAudiobookStableId: String?
    var linkedAudiobookChapterOffset: Int = 0
    var hideFromContinue: Bool = false
    var epub3Features: EPUB3Features?
    var hasAlternateFormat: Bool = false
    var readAloudSourceStableId: String?
    var serverReadStatus: String?

    var description: String?
    var series: String?
    var seriesNumber: Int?
    var seriesSequence: String?
    var publishedYear: Int?
    var personalRating: Double?
    var goodreadsRating: Double?
    var genres: [String]?
    var publisher: String?
    var isbn: String?
    var asin: String?
    var addedAt: Date?
    var libraryName: String?
    var backendName: String?
    var copyright: String?
    var language: String?
    var encodingTool: String?

    var currentTime: TimeInterval
    var isFinished: Bool
    var lastUpdate: Date

    var providerId: UUID
    var libraryId: String

    nonisolated static func normalizedFractionProgress(_ rawProgress: Double?) -> Double? {
        guard let rawProgress else { return nil }
        if rawProgress.isNaN || !rawProgress.isFinite { return nil }

        let normalized = rawProgress > 1.0 ? (rawProgress / 100.0) : rawProgress
        return min(max(normalized, 0.0), 1.0)
    }

    nonisolated static func progressFromEbookLocator(_ locator: String?) -> Double? {
        guard let locator, !locator.isEmpty,
            let data = locator.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let locations = json["locations"] as? [String: Any]
        else {
            return nil
        }

        let totalProgression = locations["totalProgression"] as? Double
        let progression = locations["progression"] as? Double
        return normalizedFractionProgress(totalProgression ?? progression)
    }

    nonisolated var canonicalEbookProgress: Double {
        let storedProgress = Self.normalizedFractionProgress(ebookProgress) ?? 0
        guard let locatorProgress = Self.progressFromEbookLocator(epubLocator) else {
            return storedProgress
        }
        guard storedProgress > 0.001 else {
            return locatorProgress
        }
        return locatorProgress > storedProgress + 0.02 ? locatorProgress : storedProgress
    }

    nonisolated var isComic: Bool {
        let formats = [
            ebookFormat,
            ebookFileURL?.pathExtension,
            filePath.flatMap { URL(string: $0)?.pathExtension },
            filePath.map { URL(fileURLWithPath: $0).pathExtension },
        ]
        .compactMap { $0?.lowercased() }

        return formats.contains(EbookFormat.cbz.rawValue)
            || formats.contains(EbookFormat.cbr.rawValue)
            || formats.contains(EbookFormat.imagefolder.rawValue)
    }

    enum BookSource: String, Codable {
        case plex
        case audiobookshelf
        case local
        case smb
        case webdav
        case jellyfin
        case emby
        case booklore = "grimmory"
        case realdebrid
        case torbox
        case komga
        case kavita
        case opds
        case storyteller
        case bookOrbit = "bookorbit"
        case silo

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)

            switch rawValue.lowercased() {
            case "booklore", "grimmory":
                self = .booklore
            case "komga":
                self = .komga
            case "kavita":
                self = .kavita
            case "opds":
                self = .opds
            case "storyteller":
                self = .storyteller
            case "bookorbit":
                self = .bookOrbit
            case "silo":
                self = .silo
            case "torbox":
                self = .torbox
            default:
                guard let value = BookSource(rawValue: rawValue) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Unknown book source: \(rawValue)"
                    )
                }
                self = value
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    nonisolated var uniqueId: String {
        "\(providerId)_\(id)"
    }

    nonisolated var canonicalAuthorKey: String {
        let names: [String]
        if let authors, !authors.isEmpty {
            names =
                authors
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else if let author, !author.isEmpty {
            names = [author]
        } else {
            return ""
        }
        return
            names
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .joined(separator: " & ")
    }

    nonisolated var deduplicationKey: String {
        if let isbn, !isbn.isEmpty { return "isbn:\(isbn)" }
        if let asin, !asin.isEmpty { return "asin:\(asin)" }
        let t = title.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
        let a =
            canonicalAuthorKey
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
        return "ta:\(t)|\(a)"
    }

    var seriesInfo: SeriesInfo? {
        guard let s = series else { return nil }
        let sequence = seriesSequence ?? seriesNumber.map(String.init)
        return SeriesInfo(name: s, sequence: sequence)
    }

    var progress: TimeInterval? {
        get { currentTime }
        set { currentTime = newValue ?? 0 }
    }

    var lastPlayed: Date? {
        get { lastUpdate }
        set { lastUpdate = newValue ?? Date() }
    }

    nonisolated init(
        id: String,
        ratingKey: String = "",
        title: String,
        author: String? = nil,
        authors: [String]? = nil,
        narrator: String? = nil,
        thumb: String? = nil,
        partKey: String? = nil,
        duration: TimeInterval? = nil,
        chapters: [Chapter]? = nil,
        currentChapterIndex: Int? = nil,
        source: BookSource = .local,
        backendId: String? = nil,
        trackIndex: Int? = 0,
        filePath: String? = nil,
        audioFileIno: String? = nil,
        audioFileInos: [String]? = nil,
        audioTracks: [AudioTrack]? = nil,
        isPodcastEpisode: Bool = false,
        episodeId: String? = nil,
        podcastLibraryItemId: String? = nil,
        podcastName: String? = nil,
        mediaType: AppMediaType = .audiobook,
        ebookFormat: String? = nil,
        epubLocator: String? = nil,
        ebookProgress: Double? = nil,
        ebookFileURL: URL? = nil,
        linkedAudiobookStableId: String? = nil,
        linkedAudiobookChapterOffset: Int = 0,
        hideFromContinue: Bool = false,
        epub3Features: EPUB3Features? = nil,
        hasAlternateFormat: Bool = false,
        readAloudSourceStableId: String? = nil,
        description: String? = nil,
        series: String? = nil,
        seriesNumber: Int? = nil,
        publishedYear: Int? = nil,
        personalRating: Double? = nil,
        goodreadsRating: Double? = nil,
        genres: [String]? = nil,
        publisher: String? = nil,
        isbn: String? = nil,
        asin: String? = nil,
        addedAt: Date? = nil,
        libraryName: String? = nil,
        backendName: String? = nil,
        copyright: String? = nil,
        language: String? = nil,
        encodingTool: String? = nil,
        progress: TimeInterval? = nil,
        lastPlayed: Date? = nil,
        currentTime: TimeInterval = 0,
        isFinished: Bool = false,
        lastUpdate: Date = Date(),
        providerId: UUID = UUID(),
        libraryId: String = ""
    ) {
        self.id = id
        self.ratingKey = ratingKey
        self.title = title
        self.author = author
        self.authors = authors
        self.narrator = narrator
        self.thumb = thumb
        self.partKey = partKey
        self.duration = duration
        self.chapters = chapters
        self.currentChapterIndex = currentChapterIndex
        self.source = source
        self.backendId = backendId
        self.trackIndex = trackIndex
        self.filePath = filePath
        self.audioFileIno = audioFileIno
        self.audioFileInos = audioFileInos
        self.audioTracks = audioTracks
        self.isPodcastEpisode = isPodcastEpisode
        self.episodeId = episodeId
        self.podcastLibraryItemId = podcastLibraryItemId
        self.podcastName = podcastName
        self.mediaType = mediaType
        self.ebookFormat = ebookFormat
        self.epubLocator = epubLocator
        self.ebookProgress = Self.normalizedFractionProgress(ebookProgress)
        self.ebookFileURL = ebookFileURL
        self.linkedAudiobookStableId = linkedAudiobookStableId
        self.linkedAudiobookChapterOffset = linkedAudiobookChapterOffset
        self.hideFromContinue = hideFromContinue
        self.epub3Features = epub3Features
        self.hasAlternateFormat = hasAlternateFormat
        self.readAloudSourceStableId = readAloudSourceStableId
        self.description = description
        self.series = series
        self.seriesNumber = seriesNumber
        self.seriesSequence = seriesNumber.map(String.init)
        self.publishedYear = publishedYear
        self.personalRating = personalRating
        self.goodreadsRating = goodreadsRating
        self.genres = genres
        self.publisher = publisher
        self.isbn = isbn
        self.asin = asin
        self.addedAt = addedAt
        self.libraryName = libraryName
        self.backendName = backendName
        self.copyright = copyright
        self.language = language
        self.encodingTool = encodingTool

        if let p = progress {
            self.currentTime = p
        } else {
            self.currentTime = currentTime
        }
        self.isFinished = isFinished
        if let lp = lastPlayed {
            self.lastUpdate = lp
        } else {
            self.lastUpdate = lastUpdate
        }
        self.providerId = providerId
        self.libraryId = libraryId
    }

    nonisolated init(
        id: String,
        title: String,
        author: String? = nil,
        authors: [String]? = nil,
        narrator: String? = nil,
        seriesInfo: SeriesInfo? = nil,
        duration: TimeInterval? = nil,
        coverURL: URL? = nil,
        partKey: String? = nil,
        audioFileIno: String? = nil,
        audioFileInos: [String]? = nil,
        audioTracks: [AudioTrack]? = nil,
        isPodcastEpisode: Bool = false,
        episodeId: String? = nil,
        podcastLibraryItemId: String? = nil,
        podcastName: String? = nil,
        mediaType: AppMediaType = .audiobook,
        ebookFormat: String? = nil,
        epubLocator: String? = nil,
        ebookProgress: Double? = nil,
        ebookFileURL: URL? = nil,
        hideFromContinue: Bool = false,
        dateAdded: Date? = nil,
        releaseDate: Date? = nil,
        description: String? = nil,
        genres: [String]? = nil,
        chapters: [Chapter]? = nil,
        publisher: String? = nil,
        progress: Double = 0,
        currentTime: TimeInterval = 0,
        isFinished: Bool = false,
        lastUpdate: Date? = nil,
        libraryId: String = "",
        providerId: UUID = UUID(),
        backendId: String? = nil,
        source: BookSource = .audiobookshelf,
        rawMetadata: [String: Any]? = nil,
        filePath: String? = nil,
        epub3Features: EPUB3Features? = nil,
        publishedYear: Int? = nil,
        personalRating: Double? = nil,
        goodreadsRating: Double? = nil,
        language: String? = nil,
        hasAlternateFormat: Bool = false,
        readAloudSourceStableId: String? = nil
    ) {
        self.id = id
        self.ratingKey = id
        self.title = title
        self.author = author
        self.authors = authors
        self.narrator = narrator
        self.thumb = coverURL?.absoluteString
        self.partKey = partKey
        self.duration = duration
        self.chapters = chapters
        self.currentChapterIndex = nil
        self.source = source
        self.backendId = backendId ?? providerId.uuidString
        self.trackIndex = 0
        self.filePath = filePath
        self.audioFileIno = audioFileIno
        self.audioFileInos = audioFileInos
        self.audioTracks = audioTracks
        self.isPodcastEpisode = isPodcastEpisode
        self.episodeId = episodeId
        self.podcastLibraryItemId = podcastLibraryItemId
        self.podcastName = podcastName
        self.mediaType = mediaType
        self.ebookFormat = ebookFormat
        self.epubLocator = epubLocator
        self.ebookProgress = Self.normalizedFractionProgress(ebookProgress)
        self.ebookFileURL = ebookFileURL
        self.linkedAudiobookStableId = nil
        self.linkedAudiobookChapterOffset = 0
        self.hideFromContinue = hideFromContinue
        self.epub3Features = epub3Features
        self.hasAlternateFormat = hasAlternateFormat
        self.readAloudSourceStableId = readAloudSourceStableId
        self.description = description
        self.series = seriesInfo?.name
        self.seriesNumber = seriesInfo?.sequence.flatMap { Int($0) }
        self.seriesSequence = seriesInfo?.sequence
        self.publishedYear = publishedYear
        self.personalRating = personalRating
        self.goodreadsRating = goodreadsRating
        self.genres = genres
        self.publisher = publisher
        self.isbn = nil
        self.asin = nil
        self.addedAt = dateAdded
        self.libraryName = nil
        self.backendName = nil
        self.copyright = nil
        self.language = language
        self.encodingTool = nil
        self.currentTime = currentTime > 0 ? currentTime : 0
        self.isFinished = isFinished
        self.lastUpdate = lastUpdate ?? Date()
        self.providerId = providerId
        self.libraryId = libraryId
    }

    public nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = try c.decode(String.self, forKey: .id)
        ratingKey = try c.decodeIfPresent(String.self, forKey: .ratingKey) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Unknown"
        author = try c.decodeIfPresent(String.self, forKey: .author)
        authors = try c.decodeIfPresent([String].self, forKey: .authors)
        narrator = try c.decodeIfPresent(String.self, forKey: .narrator)
        thumb = try c.decodeIfPresent(String.self, forKey: .thumb)
        partKey = try c.decodeIfPresent(String.self, forKey: .partKey)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters)
        currentChapterIndex = try c.decodeIfPresent(Int.self, forKey: .currentChapterIndex)
        source = try c.decodeIfPresent(BookSource.self, forKey: .source) ?? .local
        backendId = try c.decodeIfPresent(String.self, forKey: .backendId)
        trackIndex = try c.decodeIfPresent(Int.self, forKey: .trackIndex)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        audioFileIno = try c.decodeIfPresent(String.self, forKey: .audioFileIno)
        audioFileInos = try c.decodeIfPresent([String].self, forKey: .audioFileInos)
        audioTracks = try c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks)

        isPodcastEpisode = try c.decodeIfPresent(Bool.self, forKey: .isPodcastEpisode) ?? false
        episodeId = try c.decodeIfPresent(String.self, forKey: .episodeId)
        podcastLibraryItemId = try c.decodeIfPresent(String.self, forKey: .podcastLibraryItemId)
        podcastName = try c.decodeIfPresent(String.self, forKey: .podcastName)

        description = try c.decodeIfPresent(String.self, forKey: .description)
        series = try c.decodeIfPresent(String.self, forKey: .series)
        seriesNumber = try c.decodeIfPresent(Int.self, forKey: .seriesNumber)
        seriesSequence = try c.decodeIfPresent(String.self, forKey: .seriesSequence)
        publishedYear = try c.decodeIfPresent(Int.self, forKey: .publishedYear)
        personalRating = try c.decodeIfPresent(Double.self, forKey: .personalRating)
        goodreadsRating = try c.decodeIfPresent(Double.self, forKey: .goodreadsRating)
        genres = try c.decodeIfPresent([String].self, forKey: .genres)
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        isbn = try c.decodeIfPresent(String.self, forKey: .isbn)
        asin = try c.decodeIfPresent(String.self, forKey: .asin)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
        libraryName = try c.decodeIfPresent(String.self, forKey: .libraryName)
        backendName = try c.decodeIfPresent(String.self, forKey: .backendName)
        copyright = try c.decodeIfPresent(String.self, forKey: .copyright)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        encodingTool = try c.decodeIfPresent(String.self, forKey: .encodingTool)

        currentTime = try c.decodeIfPresent(TimeInterval.self, forKey: .currentTime) ?? 0
        isFinished = try c.decodeIfPresent(Bool.self, forKey: .isFinished) ?? false
        lastUpdate = try c.decodeIfPresent(Date.self, forKey: .lastUpdate) ?? Date()
        providerId = try c.decodeIfPresent(UUID.self, forKey: .providerId) ?? UUID()
        libraryId = try c.decodeIfPresent(String.self, forKey: .libraryId) ?? ""

        mediaType = try c.decodeIfPresent(AppMediaType.self, forKey: .mediaType) ?? .audiobook
        ebookFormat = try c.decodeIfPresent(String.self, forKey: .ebookFormat)
        epubLocator = try c.decodeIfPresent(String.self, forKey: .epubLocator)
        ebookProgress = Self.normalizedFractionProgress(try c.decodeIfPresent(Double.self, forKey: .ebookProgress))
        ebookFileURL = try c.decodeIfPresent(URL.self, forKey: .ebookFileURL)
        linkedAudiobookStableId = try c.decodeIfPresent(String.self, forKey: .linkedAudiobookStableId)
        linkedAudiobookChapterOffset = try c.decodeIfPresent(Int.self, forKey: .linkedAudiobookChapterOffset) ?? 0
        hideFromContinue = try c.decodeIfPresent(Bool.self, forKey: .hideFromContinue) ?? false
        epub3Features = try c.decodeIfPresent(EPUB3Features.self, forKey: .epub3Features)
        hasAlternateFormat = try c.decodeIfPresent(Bool.self, forKey: .hasAlternateFormat) ?? false
        readAloudSourceStableId = try c.decodeIfPresent(String.self, forKey: .readAloudSourceStableId)
        serverReadStatus = try c.decodeIfPresent(String.self, forKey: .serverReadStatus)
    }

    var dateAdded: Date? {
        get { addedAt }
    }

    var releaseDate: Date? {
        get { nil }
    }

    var rawMetadata: [String: Any]? {
        get { nil }
    }

    nonisolated var coverURL: URL? {
        guard let thumb = thumb else {
            return fallbackCachedCoverURL()
        }

        if source == .local || source == .smb {
            if let url = URL(string: thumb), url.scheme != nil {
                return url
            }
            let fileURL = URL(fileURLWithPath: thumb)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
            }
            return fallbackCachedCoverURL()
        }

        if thumb.hasPrefix("/") {
            let fileURL = URL(fileURLWithPath: thumb)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
            }
            return fallbackCachedCoverURL()
        }

        if let url = URL(string: thumb), url.scheme != nil {
            return url
        }
        return fallbackCachedCoverURL()
    }

    nonisolated private func fallbackCachedCoverURL() -> URL? {
        if let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let sanitizedBookId = id.replacingOccurrences(of: ":", with: "_")
            let cachedCoverURL =
                cachesDirectory
                .appendingPathComponent("Covers", isDirectory: true)
                .appendingPathComponent("\(sanitizedBookId).jpg")
            if FileManager.default.fileExists(atPath: cachedCoverURL.path) {
                return cachedCoverURL
            }
        }

        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let appSupportURL {
            let sanitized =
                downloadKey
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "\\", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: "?", with: "-")
                .replacingOccurrences(of: "&", with: "-")
                .replacingOccurrences(of: "=", with: "-")
            let persistentCoverURL =
                appSupportURL
                .appendingPathComponent("Enve/Covers", isDirectory: true)
                .appendingPathComponent("\(sanitized).jpg", isDirectory: false)
            if FileManager.default.fileExists(atPath: persistentCoverURL.path) {
                return persistentCoverURL
            }
        }

        return nil
    }

    nonisolated var progressPercentage: Double {
        if mediaType == .ebook {
            return Self.normalizedFractionProgress(ebookProgress) ?? 0.0
        }
        guard let duration = duration, duration > 0 else {
            return 0.0
        }
        return min(currentTime / duration, 1.0)
    }

    var isStarted: Bool {
        if mediaType == .ebook {
            return (Self.normalizedFractionProgress(ebookProgress) ?? 0) > 0
        }
        return currentTime > 0
    }

    nonisolated var isCompleted: Bool {
        if isFinished { return true }
        if mediaType == .ebook {
            return (Self.normalizedFractionProgress(ebookProgress) ?? 0) >= 0.99
        }
        guard let duration = duration else { return false }
        return currentTime >= duration * 0.99
    }

    nonisolated var isReadAloudBook: Bool { readAloudSourceStableId != nil }

    nonisolated var hasEPUB3MediaOverlay: Bool {
        isReadAloudBook || epub3Features?.hasMediaOverlay == true
    }

    nonisolated var isStorytellerReadAloud: Bool {
        source == .storyteller && epub3Features?.hasMediaOverlay == true
    }

    nonisolated var epubLocatorIsAudio: Bool {
        guard let epubLocator,
            let data = epubLocator.data(using: .utf8),
            let locator = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let type = (locator["type"] as? String)?.lowercased() ?? ""
        let href = (locator["href"] as? String)?.lowercased() ?? ""
        return type.contains("audio") || href.hasPrefix("audiobook://")
    }

    nonisolated var stableId: String {
        if let readAloudSourceStableId {
            return "storyalign:\(readAloudSourceStableId)"
        }
        switch source {
        case .plex:
            return "plex:\(ratingKey)"
        case .audiobookshelf:
            return "audiobookshelf:\(backendId ?? providerId.uuidString):\(id)"
        case .local:
            return "local:\(backendId ?? "unknown"):\(id)"
        case .smb:
            return "smb:\(backendId ?? "unknown"):\(id)"
        case .webdav:
            return "webdav:\(backendId ?? providerId.uuidString):\(id)"
        case .jellyfin:
            return "jellyfin:\(backendId ?? providerId.uuidString):\(id)"
        case .emby:
            return "emby:\(backendId ?? providerId.uuidString):\(id)"
        case .booklore:
            return "grimmory:\(backendId ?? providerId.uuidString):\(id)"
        case .realdebrid:
            return "realdebrid:\(backendId ?? providerId.uuidString):\(id)"
        case .torbox:
            return "torbox:\(backendId ?? providerId.uuidString):\(id)"
        case .komga:
            return "komga:\(backendId ?? providerId.uuidString):\(id)"
        case .kavita:
            return "kavita:\(backendId ?? providerId.uuidString):\(id)"
        case .opds:
            return "opds:\(backendId ?? providerId.uuidString):\(id)"
        case .storyteller:
            return "storyteller:\(backendId ?? providerId.uuidString):\(id)"
        case .bookOrbit:
            return "bookorbit:\(backendId ?? providerId.uuidString):\(id)"
        case .silo:
            return "silo:\(backendId ?? providerId.uuidString):\(id)"
        }
    }

    nonisolated var downloadKey: String { stableId }

    nonisolated var isMultiFile: Bool {
        guard let tracks = audioTracks else { return false }
        return tracks.count > 1
    }

    func audioTrack(at globalPosition: TimeInterval) -> AudioTrack? {
        return audioTracks?.track(at: globalPosition)
    }

    func localPosition(for globalPosition: TimeInterval) -> (trackIndex: Int, localOffset: TimeInterval)? {
        return audioTracks?.localPosition(for: globalPosition)
    }

    func globalPosition(trackIndex: Int, localOffset: TimeInterval) -> TimeInterval? {
        return audioTracks?.globalPosition(trackIndex: trackIndex, localOffset: localOffset)
    }

    nonisolated func withPlaybackSessionTimeline(tracks: [AudioTrackInfo], duration: TimeInterval?) -> Book {
        let audioTracks = tracks.map {
            AudioTrack(
                index: $0.index,
                title: $0.title,
                contentUrl: $0.contentUrl,
                duration: $0.duration,
                startOffset: $0.startOffset,
                format: $0.mimeType
            )
        }

        var copy = Book(
            id: id,
            ratingKey: ratingKey,
            title: title,
            author: author,
            authors: authors,
            narrator: narrator,
            thumb: thumb,
            partKey: partKey,
            duration: duration ?? self.duration,
            chapters: chapters,
            currentChapterIndex: currentChapterIndex,
            source: source,
            backendId: backendId,
            trackIndex: trackIndex,
            filePath: filePath,
            audioFileIno: audioFileIno,
            audioFileInos: audioFileInos,
            audioTracks: audioTracks.isEmpty ? self.audioTracks : audioTracks,
            isPodcastEpisode: isPodcastEpisode,
            episodeId: episodeId,
            podcastLibraryItemId: podcastLibraryItemId,
            podcastName: podcastName,
            mediaType: mediaType,
            ebookFormat: ebookFormat,
            epubLocator: epubLocator,
            ebookProgress: ebookProgress,
            ebookFileURL: ebookFileURL,
            linkedAudiobookStableId: linkedAudiobookStableId,
            linkedAudiobookChapterOffset: linkedAudiobookChapterOffset,
            hideFromContinue: hideFromContinue,
            epub3Features: epub3Features,
            hasAlternateFormat: hasAlternateFormat,
            readAloudSourceStableId: readAloudSourceStableId,
            description: description,
            series: series,
            seriesNumber: seriesNumber,
            publishedYear: publishedYear,
            personalRating: personalRating,
            goodreadsRating: goodreadsRating,
            genres: genres,
            publisher: publisher,
            isbn: isbn,
            asin: asin,
            addedAt: addedAt,
            libraryName: libraryName,
            backendName: backendName,
            copyright: copyright,
            language: language,
            encodingTool: encodingTool,
            currentTime: currentTime,
            isFinished: isFinished,
            lastUpdate: lastUpdate,
            providerId: providerId,
            libraryId: libraryId
        )
        copy.seriesSequence = seriesSequence
        copy.serverReadStatus = serverReadStatus
        return copy
    }

}
