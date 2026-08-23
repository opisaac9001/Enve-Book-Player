import Foundation

nonisolated public struct FileMetadataLayer: Codable, Equatable, Sendable {
    var title: String?
    var author: String?
    var narrator: String?
    var series: String?
    var seriesNumber: Int?
    var year: Int?
    var publisher: String?
    var genres: [String]?
    var description: String?
    var duration: TimeInterval?
    var isbn: String?
    var asin: String?
    var fileName: String?
    var folderName: String?
    var coverPath: String?
    var copyright: String?
    var language: String?
    var encodingTool: String?
}

nonisolated struct BackendMetadataLayer: Codable, Equatable, Sendable {
    var title: String?
    var author: String?
    var narrator: String?
    var series: String?
    var seriesNumber: Int?
    var year: Int?
    var publisher: String?
    var genres: [String]?
    var description: String?
    var duration: TimeInterval?
    var isbn: String?
    var asin: String?
    var fileName: String?
    var folderName: String?
    var chapters: [Chapter]?
    var thumb: String?
}

nonisolated struct GoogleBooksMetadataLayer: Codable, Equatable, Sendable {
    var isbn: String?
    var title: String?
    var subtitle: String?
    var authors: [String]?
    var publisher: String?
    var publishedDate: String?
    var description: String?
    var pageCount: Int?
    var categories: [String]?
    var averageRating: Double?
    var ratingsCount: Int?
    var imageLinks: GoogleBooksImageLinks?
    var language: String?
}

nonisolated struct GoogleBooksImageLinks: Codable, Equatable, Sendable {
    var smallThumbnail: String?
    var thumbnail: String?
    var small: String?
    var medium: String?
    var large: String?
    var extraLarge: String?
}

nonisolated struct iTunesMetadataLayer: Codable, Equatable, Sendable {
    var trackId: Int?
    var title: String?
    var authors: [String]?
    var narrator: String?
    var description: String?
    var publisher: String?
    var publishedDate: String?
    var duration: TimeInterval?
    var artworkURL: String?
    var previewURL: String?
    var genre: String?
    var copyright: String?
    var trackViewUrl: String?
}

nonisolated struct AudibleMetadataLayer: Codable, Equatable, Sendable {
    var asin: String?
    var title: String?
    var subtitle: String?
    var author: String?
    var narrators: [String]?
    var series: String?
    var seriesNumber: String?
    var description: String?
    var descriptionPlain: String?
    var coverUrl: String?
    var publisher: String?
    var publishedYear: Int?
    var releaseDate: String?
    var genres: [String]?
    var tags: [String]?
    var rating: Double?
    var ratingCount: Int?
    var duration: TimeInterval?
    var language: String?
    var format: String?
}

nonisolated struct EnveMetadataLayer: Codable, Equatable, Sendable {
    var enveId: String?
    var title: String?
    var author: String?
    var narrator: String?
    var publisher: String?
    var releaseYear: Int?
    var isbn: String?
    var asin: String?
    var coverUrl: String?
    var duration: TimeInterval?
    var tags: [String]?
    var description: String?
    var seriesName: String?
    var seriesPosition: String?
}

nonisolated struct AppCacheMetadataLayer: Codable, Equatable, Sendable {
    var normalizedTitle: String?
    var normalizedAuthor: String?
    var playbackSpeed: Double?
    var lastPlayedPosition: TimeInterval?
    var lastPlayedAt: Date?
    var durationOverride: TimeInterval?
    var autoSeriesName: String?
    var autoSeriesNumber: Int?
    var lastMetadataUpdate: Date?
}

nonisolated struct UserOverridesLayer: Codable, Equatable, Sendable {
    var customTitle: String?
    var customAuthor: String?
    var customSeries: String?
    var customSeriesNumber: Int?
    var customSeriesSequence: String?
    var customNarrator: String?
    var customCoverPath: String?
    var customDescription: String?
    var customPublisher: String?
    var customGenres: [String]?
    var userTags: [String]?
    var notes: String?
    var hidden: Bool?
}

nonisolated struct BookMetadata: Codable, Equatable, Sendable {
    var bookId: String
    var backend: BackendMetadataLayer?
    var file: FileMetadataLayer
    var googleBooks: GoogleBooksMetadataLayer?
    var iTunes: iTunesMetadataLayer?
    var audible: AudibleMetadataLayer?
    var enve: EnveMetadataLayer?
    var appCache: AppCacheMetadataLayer?
    var userOverrides: UserOverridesLayer?
    var metadataVersion: String?
    var lastUpdated: Date?

    init(bookId: String, file: FileMetadataLayer) {
        self.bookId = bookId
        self.file = file
        self.metadataVersion = "1.0"
        self.lastUpdated = Date()
    }

    init(bookId: String, file: FileMetadataLayer, backend: BackendMetadataLayer?) {
        self.bookId = bookId
        self.file = file
        self.backend = backend
        self.metadataVersion = "1.0"
        self.lastUpdated = Date()
    }
}

struct MergedMetadata: Sendable {
    var title: String
    var author: String
    var narrator: String?
    var series: String?
    var seriesNumber: Int?
    var description: String?
    var duration: TimeInterval?
    var coverUrl: String?
    var publisher: String?
    var publishedYear: Int?
    var genres: [String]?
    var isbn: String?
    var asin: String?
    var rating: Double?
    var tags: [String]?
    var notes: String?

    var sources: MetadataSources

    nonisolated init(
        title: String,
        author: String,
        narrator: String? = nil,
        series: String? = nil,
        seriesNumber: Int? = nil,
        description: String? = nil,
        duration: TimeInterval? = nil,
        coverUrl: String? = nil,
        publisher: String? = nil,
        publishedYear: Int? = nil,
        genres: [String]? = nil,
        isbn: String? = nil,
        asin: String? = nil,
        rating: Double? = nil,
        tags: [String]? = nil,
        notes: String? = nil,
        sources: MetadataSources
    ) {
        self.title = title
        self.author = author
        self.narrator = narrator
        self.series = series
        self.seriesNumber = seriesNumber
        self.description = description
        self.duration = duration
        self.coverUrl = coverUrl
        self.publisher = publisher
        self.publishedYear = publishedYear
        self.genres = genres
        self.isbn = isbn
        self.asin = asin
        self.rating = rating
        self.tags = tags
        self.notes = notes
        self.sources = sources
    }
}

struct MetadataSources: Sendable {
    var title: MetadataSource
    var author: MetadataSource
    var narrator: MetadataSource
    var series: MetadataSource
    var cover: MetadataSource
    var description: MetadataSource
    var duration: MetadataSource
}

enum MetadataSource: String, Codable, Sendable {
    case backend = "Backend (Plex/Audiobookshelf)"
    case file = "Embedded File"
    case openLibrary = "Open Library"
    case googleBooks = "Google Books"
    case iTunes = "iTunes"
    case enve = "Enve Metadata Server"
    case audible = "Metadata Search"
    case appCache = "App Cache"
    case userOverrides = "User Override"
}

struct AudibleSearchResult: Codable, Identifiable, Equatable, Sendable {
    var id: String { asin }
    let asin: String
    let title: String
    let authors: [String]
    let narrators: [String]
    let duration: Int
    let releaseDate: String?
    let coverUrl: String?
    let rating: Double?
    let description: String?
    let seriesName: String?
    let seriesPosition: String?

    init(
        asin: String,
        title: String,
        authors: [String],
        narrators: [String],
        duration: Int,
        releaseDate: String?,
        coverUrl: String?,
        rating: Double?,
        description: String?,
        seriesName: String? = nil,
        seriesPosition: String? = nil
    ) {
        self.asin = asin
        self.title = title
        self.authors = authors
        self.narrators = narrators
        self.duration = duration
        self.releaseDate = releaseDate
        self.coverUrl = coverUrl
        self.rating = rating
        self.description = description
        self.seriesName = seriesName
        self.seriesPosition = seriesPosition
    }
}

enum MetadataLayerType {
    case file
    case openLibrary
    case googleBooks
    case iTunes
    case audible
    case enve
    case appCache
    case userOverrides
}

struct ComicCredits: Equatable, Sendable {
    struct RoleGroup: Equatable, Sendable, Identifiable {
        let role: String
        let displayName: String
        let names: [String]
        var id: String { role }
    }

    let roles: [RoleGroup]
    let releaseDate: Date?
    let pageCount: Int?

    var isEmpty: Bool {
        roles.isEmpty && releaseDate == nil && pageCount == nil
    }

    private static let roleOrder: [(String, String)] = [
        ("writer", "Writer"),
        ("penciller", "Penciller"),
        ("inker", "Inker"),
        ("colorist", "Colorist"),
        ("letterer", "Letterer"),
        ("cover", "Cover Artist"),
        ("editor", "Editor"),
        ("translator", "Translator"),
    ]

    static func orderedRoles(from byRole: [String: [String]]) -> [RoleGroup] {
        var groups: [RoleGroup] = []
        for (role, display) in roleOrder {
            if let names = byRole[role], !names.isEmpty {
                groups.append(RoleGroup(role: role, displayName: display, names: names))
            }
        }

        let known = Set(roleOrder.map(\.0))
        for (role, names) in byRole.sorted(by: { $0.key < $1.key }) where !known.contains(role) && !names.isEmpty {
            groups.append(RoleGroup(role: role, displayName: role.capitalized, names: names))
        }
        return groups
    }
}
