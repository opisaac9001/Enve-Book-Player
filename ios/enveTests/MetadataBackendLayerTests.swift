import Foundation
import Testing

@testable import enve

@MainActor
struct MetadataBackendLayerTests {
    @Test func anAbsentLayerIsSeededFromTheBook() {
        let layer = MetadataManager.backendLayer(fillingGapsIn: nil, from: Self.book())

        #expect(layer.title == "Stream Recovered")
        #expect(layer.narrator == "Reader")
        #expect(layer.description == "From the stream")
        #expect(layer.series == "Arc")
        #expect(layer.seriesNumber == 2)
        #expect(layer.year == 2011)
        #expect(layer.publisher == "House")
        #expect(layer.genres == ["Fantasy"])
        #expect(layer.duration == 3_600)
        #expect(layer.isbn == "9780000000001")
        #expect(layer.asin == "B00TEST")
    }

    @Test func serverSuppliedValuesAreNeverOverwritten() {
        var existing = BackendMetadataLayer()
        existing.narrator = "Server Narrator"
        existing.description = "Server description"
        existing.genres = ["Mystery"]
        existing.publisher = "Server House"

        let layer = MetadataManager.backendLayer(fillingGapsIn: existing, from: Self.book())

        #expect(layer.narrator == "Server Narrator")
        #expect(layer.description == "Server description")
        #expect(layer.genres == ["Mystery"])
        #expect(layer.publisher == "Server House")
        #expect(layer.series == "Arc")
        #expect(layer.isbn == "9780000000001")
    }

    @Test func emptyStreamValuesDoNotReplaceMissingFields() {
        var book = Self.book()
        book.narrator = ""
        book.description = ""
        book.genres = []

        var existing = BackendMetadataLayer()
        existing.title = "Server Title"

        let layer = MetadataManager.backendLayer(fillingGapsIn: existing, from: book)

        #expect(layer.title == "Server Title")
        #expect(layer.narrator == nil)
        #expect(layer.description == nil)
        #expect(layer.genres == nil)
    }

    @Test func anEmptyStoredGenreListIsBackfilled() {
        var existing = BackendMetadataLayer()
        existing.genres = []

        let layer = MetadataManager.backendLayer(fillingGapsIn: existing, from: Self.book())

        #expect(layer.genres == ["Fantasy"])
    }

    @Test func catalogRefreshReplacesStaleBackendFieldsAndKeepsExtractedChapters() {
        let chapters = [Chapter(id: "0", start: 0, end: 60, title: "Opening")]
        let existing = BackendMetadataLayer(
            title: "Old title",
            author: "Old author",
            narrator: "Old narrator",
            series: "Old series",
            seriesNumber: 1,
            year: 1999,
            publisher: "Old publisher",
            genres: ["Old genre"],
            description: "Old description",
            duration: 120,
            isbn: "old-isbn",
            asin: "old-asin",
            fileName: "download.m4b",
            folderName: "Downloads",
            chapters: chapters,
            thumb: "https://example.com/old.jpg"
        )

        var book = Self.book()
        book.thumb = "https://example.com/new.jpg"
        let layer = MetadataManager.refreshedBackendLayer(from: book, preserving: existing)

        #expect(layer.title == "Stream Recovered")
        #expect(layer.author == "Author")
        #expect(layer.narrator == "Reader")
        #expect(layer.series == "Arc")
        #expect(layer.seriesNumber == 2)
        #expect(layer.year == 2011)
        #expect(layer.publisher == "House")
        #expect(layer.genres == ["Fantasy"])
        #expect(layer.description == "From the stream")
        #expect(layer.duration == 3_600)
        #expect(layer.isbn == "9780000000001")
        #expect(layer.asin == "B00TEST")
        #expect(layer.thumb == "https://example.com/new.jpg")
        #expect(layer.fileName == "download.m4b")
        #expect(layer.folderName == "Downloads")
        #expect(layer.chapters == chapters)
    }

    private static func book() -> Book {
        Book(
            id: "grimmory-1",
            title: "Stream Recovered",
            author: "Author",
            narrator: "Reader",
            duration: 3_600,
            source: .booklore,
            description: "From the stream",
            series: "Arc",
            seriesNumber: 2,
            publishedYear: 2011,
            genres: ["Fantasy"],
            publisher: "House",
            isbn: "9780000000001",
            asin: "B00TEST",
            providerId: UUID(),
            libraryId: "library-1"
        )
    }
}
