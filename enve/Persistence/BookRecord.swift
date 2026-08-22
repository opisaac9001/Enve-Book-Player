import Foundation
import SwiftData

@Model
final class BookRecord {
    var uniqueId: String = ""
    var stableId: String = ""

    var bookId: String = ""
    var ratingKey: String = ""
    var title: String = ""
    var author: String?
    var authors: [String]?
    var narrator: String?
    var thumb: String?
    var partKey: String?
    var duration: TimeInterval?
    var source: String = "local"
    var backendId: String?
    var trackIndex: Int?
    var filePath: String?
    var audioFileIno: String?
    var mediaType: String = "audiobook"
    var ebookFormat: String?

    var series: String?

    var searchText: String = ""
    var titleSortKey: String = ""
    var titleMissingRank: Int = 0
    var authorGivenSortKey: String = ""
    var authorSurnameSortKey: String = ""
    var authorMissingRank: Int = 0
    var narratorGivenSortKey: String = ""
    var narratorSurnameSortKey: String = ""
    var narratorMissingRank: Int = 0
    var seriesSortKey: String = ""
    var seriesNumberSortValue: Double = Double.greatestFiniteMagnitude
    var seriesMissingRank: Int = 0
    var progressSortValue: Double = 0
    var durationSortValue: Double = 0
    var durationMissingRank: Int = 0
    var yearSortValue: Int = 0
    var yearMissingRank: Int = 0
    var goodreadsRatingSortValue: Double = 0
    var goodreadsRatingMissingRank: Int = 0
    var addedAtSortValue: Date = Date.distantPast
    var addedAtMissingRank: Int = 0

    var workKey: String = ""
    var editionKey: String = ""
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
    var bookDescription: String?
    var language: String?

    var currentTime: TimeInterval = 0
    var ebookProgress: Double?
    var isFinished: Bool = false
    var lastUpdate: Date = Date()
    var hideFromContinue: Bool = false

    var epubLocator: String?
    var linkedAudiobookStableId: String?
    var linkedAudiobookChapterOffset: Int = 0
    var hasAlternateFormat: Bool = false
    var readAloudSourceStableId: String?

    var isPodcastEpisode: Bool = false
    var episodeId: String?
    var podcastLibraryItemId: String?
    var podcastName: String?

    var providerId: String = ""
    var libraryId: String = ""

    var serverReadStatus: String?
    var isHidden: Bool = false
    var isDeleted: Bool = false

    var ebookFileURLPath: String?
    var epub3HasMediaOverlay: Bool = false
    var audioTracksJSON: Data?

    var lastSyncDate: Date?

    var syncGeneration: Int = 0

    init() {}

    init(from book: Book) {
        self.uniqueId = book.uniqueId
        self.stableId = book.stableId
        self.bookId = book.id
        self.ratingKey = book.ratingKey
        self.title = book.title
        self.author = book.author
        self.authors = book.authors
        self.narrator = book.narrator
        self.thumb = book.thumb
        self.partKey = book.partKey
        self.duration = book.duration
        self.source = book.source.rawValue
        self.backendId = book.backendId
        self.trackIndex = book.trackIndex
        self.filePath = book.filePath
        self.audioFileIno = book.audioFileIno
        self.mediaType = book.mediaType.rawValue
        self.ebookFormat = book.ebookFormat

        self.series = book.series
        self.searchText = BookRecord.makeSearchText(title: book.title, author: book.author, narrator: book.narrator, series: book.series)
        self.workKey = WorkIdentity.workKey(for: book)
        self.editionKey = WorkIdentity.editionKey(for: book)
        self.seriesSequence = book.seriesSequence
        self.publishedYear = book.publishedYear
        self.personalRating = book.personalRating
        self.goodreadsRating = book.goodreadsRating
        self.genres = book.genres
        self.publisher = book.publisher
        self.isbn = book.isbn
        self.asin = book.asin
        self.addedAt = book.addedAt
        self.libraryName = book.libraryName
        self.backendName = book.backendName
        self.bookDescription = book.description
        self.language = book.language

        self.currentTime = book.currentTime
        self.ebookProgress = book.ebookProgress
        self.isFinished = book.isFinished
        self.lastUpdate = book.lastUpdate
        self.hideFromContinue = book.hideFromContinue
        self.serverReadStatus = book.serverReadStatus

        self.epubLocator = book.epubLocator
        self.linkedAudiobookStableId = book.linkedAudiobookStableId
        self.linkedAudiobookChapterOffset = book.linkedAudiobookChapterOffset
        self.hasAlternateFormat = book.hasAlternateFormat
        self.readAloudSourceStableId = book.readAloudSourceStableId

        self.isPodcastEpisode = book.isPodcastEpisode
        self.episodeId = book.episodeId
        self.podcastLibraryItemId = book.podcastLibraryItemId
        self.podcastName = book.podcastName

        self.providerId = book.providerId.uuidString
        self.libraryId = book.libraryId

        self.ebookFileURLPath = book.ebookFileURL?.path
        self.epub3HasMediaOverlay = book.epub3Features?.hasMediaOverlay ?? false
        self.audioTracksJSON = book.audioTracks.flatMap { try? JSONEncoder().encode($0) }

        self.lastSyncDate = Date()
        refreshSortKeys()
    }

    static func makeSearchText(title: String, author: String?, narrator: String?, series: String?) -> String {
        [title, author, narrator, series]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    func toBook() -> Book? {
        guard !uniqueId.isEmpty, !stableId.isEmpty else { return nil }
        guard let sourceEnum = Book.BookSource(rawValue: source),
            let providerUUID = UUID(uuidString: providerId)
        else {
            return nil
        }
        let mediaTypeEnum = AppMediaType(rawValue: mediaType) ?? .audiobook

        let restoredEbookURL: URL? = {
            if let path = ebookFileURLPath, !path.isEmpty {
                return BookRecord.rebaseSandboxPath(path)
            } else if let path = filePath, !path.isEmpty {
                return BookRecord.rebaseSandboxPath(path)
            }
            return nil
        }()

        var result = Book(
            id: bookId,
            ratingKey: ratingKey,
            title: title,
            author: author,
            authors: authors,
            narrator: narrator,
            thumb: thumb,
            partKey: partKey,
            duration: duration,
            chapters: nil,
            currentChapterIndex: nil,
            source: sourceEnum,
            backendId: backendId,
            trackIndex: trackIndex,
            filePath: filePath,
            audioFileIno: audioFileIno,
            audioFileInos: nil,
            audioTracks: audioTracksJSON.flatMap { try? JSONDecoder().decode([AudioTrack].self, from: $0) },
            isPodcastEpisode: isPodcastEpisode,
            episodeId: episodeId,
            podcastLibraryItemId: podcastLibraryItemId,
            podcastName: podcastName,
            mediaType: mediaTypeEnum,
            ebookFormat: ebookFormat,
            epubLocator: epubLocator,
            ebookProgress: ebookProgress,
            ebookFileURL: restoredEbookURL,
            linkedAudiobookStableId: linkedAudiobookStableId,
            linkedAudiobookChapterOffset: linkedAudiobookChapterOffset,
            hideFromContinue: hideFromContinue,
            epub3Features: epub3HasMediaOverlay ? EPUB3Features(hasMediaOverlay: true) : nil,
            hasAlternateFormat: hasAlternateFormat,
            readAloudSourceStableId: readAloudSourceStableId,
            description: bookDescription,
            series: series,
            seriesNumber: seriesSequence.flatMap { Int($0) },
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
            language: language,
            currentTime: currentTime,
            isFinished: isFinished,
            lastUpdate: lastUpdate,
            providerId: providerUUID,
            libraryId: libraryId
        )
        result.serverReadStatus = serverReadStatus

        result.seriesSequence = seriesSequence
        return result
    }

    func update(from book: Book) {
        self.title = book.title
        self.author = book.author
        self.authors = book.authors
        self.narrator = book.narrator
        self.thumb = book.thumb
        self.duration = book.duration
        self.filePath = book.filePath
        self.audioFileIno = book.audioFileIno

        self.series = book.series
        self.searchText = BookRecord.makeSearchText(title: book.title, author: book.author, narrator: book.narrator, series: book.series)
        self.workKey = WorkIdentity.workKey(for: book)
        self.editionKey = WorkIdentity.editionKey(for: book)
        self.seriesSequence = book.seriesSequence
        self.publishedYear = book.publishedYear
        self.personalRating = book.personalRating
        self.goodreadsRating = book.goodreadsRating
        self.genres = book.genres
        self.publisher = book.publisher
        self.isbn = book.isbn
        self.asin = book.asin
        self.addedAt = book.addedAt
        self.libraryName = book.libraryName
        self.backendName = book.backendName
        self.bookDescription = book.description
        self.language = book.language

        if book.lastUpdate >= self.lastUpdate {
            self.currentTime = book.currentTime
            self.ebookProgress = book.ebookProgress
            self.epubLocator = book.epubLocator
            self.isFinished = book.isFinished
            self.lastUpdate = book.lastUpdate
            self.hideFromContinue = book.hideFromContinue
        }
        self.serverReadStatus = book.serverReadStatus

        self.linkedAudiobookStableId = book.linkedAudiobookStableId
        self.linkedAudiobookChapterOffset = book.linkedAudiobookChapterOffset
        self.hasAlternateFormat = book.hasAlternateFormat
        self.readAloudSourceStableId = book.readAloudSourceStableId

        self.isPodcastEpisode = book.isPodcastEpisode
        self.episodeId = book.episodeId
        self.podcastLibraryItemId = book.podcastLibraryItemId
        self.podcastName = book.podcastName

        self.ebookFileURLPath = book.ebookFileURL?.path
        self.ebookFormat = book.ebookFormat
        self.epub3HasMediaOverlay = book.epub3Features?.hasMediaOverlay ?? false
        if let tracks = book.audioTracks {
            self.audioTracksJSON = try? JSONEncoder().encode(tracks)
        }

        self.lastSyncDate = Date()
        refreshSortKeys()
    }

    func refreshSortKeys() {
        let title = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        titleMissingRank = BookSortKeys.missingRank(title.isEmpty)
        titleSortKey = BookSortKeys.text(title)

        authorMissingRank = BookSortKeys.missingRank(BookSortKeys.isMissing(author))
        authorGivenSortKey = BookSortKeys.name(author, style: .given)
        authorSurnameSortKey = BookSortKeys.name(author, style: .surname)

        narratorMissingRank = BookSortKeys.missingRank(BookSortKeys.isMissing(narrator))
        narratorGivenSortKey = BookSortKeys.name(narrator, style: .given)
        narratorSurnameSortKey = BookSortKeys.name(narrator, style: .surname)

        seriesMissingRank = BookSortKeys.missingRank(BookSortKeys.isMissing(series))
        seriesSortKey = BookSortKeys.text(series)
        seriesNumberSortValue = BookSortKeys.seriesNumber(seriesSequence)

        progressSortValue = BookSortKeys.progress(
            mediaType: mediaType,
            currentTime: currentTime,
            duration: duration,
            ebookProgress: ebookProgress
        )
        durationMissingRank = BookSortKeys.missingRank(duration == nil)
        durationSortValue = duration ?? 0
        yearMissingRank = BookSortKeys.missingRank(publishedYear == nil)
        yearSortValue = publishedYear ?? 0
        let rating = max(personalRating ?? 0, goodreadsRating ?? 0)
        goodreadsRatingMissingRank = BookSortKeys.missingRank(personalRating == nil && goodreadsRating == nil)
        goodreadsRatingSortValue = rating
        addedAtMissingRank = BookSortKeys.missingRank(addedAt == nil)
        addedAtSortValue = addedAt ?? .distantPast
    }

    nonisolated static func rebaseSandboxPath(_ storedPath: String) -> URL {
        let fm = FileManager.default
        let markers: [(String, FileManager.SearchPathDirectory)] = [
            ("/Documents/", .documentDirectory),
            ("/Library/Caches/", .cachesDirectory),
            ("/Library/Application Support/", .applicationSupportDirectory),
        ]
        for (marker, directory) in markers {
            guard let range = storedPath.range(of: marker) else { continue }
            let relative = String(storedPath[range.upperBound...])
            guard !relative.isEmpty,
                let root = fm.urls(for: directory, in: .userDomainMask).first
            else { continue }
            return root.appendingPathComponent(relative)
        }
        return URL(fileURLWithPath: storedPath)
    }
}

enum BookSortKeys {
    enum NameStyle { case given, surname }

    nonisolated static func isMissing(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    nonisolated static func missingRank(_ missing: Bool) -> Int {
        missing ? 1 : 0
    }

    nonisolated static func text(_ value: String?) -> String {
        naturalKey(value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    nonisolated static func name(_ value: String?, style: NameStyle) -> String {
        let components = parsedName(value)
        switch style {
        case .given:
            return naturalKey(components.given.isEmpty ? components.fallback : "\(components.given) \(components.surname)")
        case .surname:
            return naturalKey(components.surname.isEmpty ? components.fallback : "\(components.surname) \(components.given)")
        }
    }

    nonisolated static func seriesNumber(_ sequence: String?) -> Double {
        sequence.flatMap(Double.init) ?? .greatestFiniteMagnitude
    }

    nonisolated static func progress(
        mediaType: String,
        currentTime: TimeInterval,
        duration: TimeInterval?,
        ebookProgress: Double?
    ) -> Double {
        if mediaType == AppMediaType.ebook.rawValue {
            return Book.normalizedFractionProgress(ebookProgress) ?? 0
        }
        guard let duration, duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private nonisolated static func naturalKey(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var key = ""
        var digits = ""

        func flushDigits() {
            guard !digits.isEmpty else { return }
            let trimmed = digits.drop { $0 == "0" }
            let significant = trimmed.isEmpty ? "0" : String(trimmed)
            key += String(format: "%012d", significant.count)
            key += significant
            digits.removeAll(keepingCapacity: true)
        }

        for scalar in folded.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                digits.unicodeScalars.append(scalar)
            } else {
                flushDigits()
                key.unicodeScalars.append(scalar)
            }
        }
        flushDigits()
        return key
    }

    private nonisolated static func parsedName(_ value: String?) -> (given: String, surname: String, fallback: String) {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleaned.isEmpty else { return ("", "", "") }
        let primary = firstNameCandidate(cleaned)
        let commaParts =
            primary
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if commaParts.count >= 2, looksLikeReversedName(surname: commaParts[0], given: commaParts[1]) {
            return (commaParts[1], commaParts[0], primary)
        }

        var tokens =
            primary
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: nameTrimCharacters) }
            .filter { !$0.isEmpty }
        while let last = tokens.last, nameSuffixes.contains(last.lowercased().trimmingCharacters(in: nameTrimCharacters)) {
            tokens.removeLast()
        }
        guard let surname = tokens.last else { return ("", "", primary) }
        let given = tokens.dropLast().joined(separator: " ")
        return (given, surname, primary)
    }

    private nonisolated static func firstNameCandidate(_ value: String) -> String {
        let separators = [";", " / ", " & ", " and "]
        for separator in separators {
            if let range = value.range(of: separator, options: [.caseInsensitive]) {
                return String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let commaParts =
            value
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if commaParts.count > 2 {
            return commaParts[0]
        }
        return value
    }

    private nonisolated static func looksLikeReversedName(surname: String, given: String) -> Bool {
        let surnameTokens = surname.split(whereSeparator: { $0.isWhitespace })
        let givenTokens = given.split(whereSeparator: { $0.isWhitespace })
        guard !surnameTokens.isEmpty, !givenTokens.isEmpty else { return false }
        return surnameTokens.count <= 2 || givenTokens.contains { $0.contains(".") }
    }

    private nonisolated static var nameTrimCharacters: CharacterSet {
        var characters = CharacterSet.whitespacesAndNewlines
        characters.insert(charactersIn: ".,")
        return characters
    }

    private nonisolated static var nameSuffixes: Set<String> {
        ["jr", "sr", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"]
    }
}
