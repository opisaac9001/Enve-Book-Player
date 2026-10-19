import Foundation
import SwiftData

enum BookStoreSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var versionString: String { "1.0.0" }

    static var models: [any PersistentModel.Type] {
        [
            BookRecord.self,
            MediaProgressRecord.self,
            LinkedBookPairRecord.self,
            BookmarkRecord.self,
            AnnotationRecord.self,
            ChapterCacheRecord.self,
            VocabEntryRecord.self,
            LibrarySyncCursor.self,
        ]
    }

    // Frozen stored layout of the version 1 store. Do not edit; add changes to a new schema version.
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
    }
}
