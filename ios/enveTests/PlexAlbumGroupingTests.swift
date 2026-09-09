import Foundation
import Testing
@testable import enve

@MainActor
struct PlexAlbumGroupingTests {
    private let provider = PlexProvider(connection: ServerConnection(
        name: "Plex", url: "https://example.invalid", type: .plex))

    private func metadata(_ id: String, title: String, path: String? = nil) throws -> PlexProvider.PlexMetadata {
        var fields: [String: Any] = ["ratingKey": id, "key": "/library/metadata/\(id)",
            "title": title, "type": path == nil ? "album" : "track", "duration": 45000,
            "parentTitle": "[Unknown Album]", "grandparentTitle": "Test Author"]
        if let path {
            fields["Media"] = [["Part": [["key": "/library/parts/\(id)/file", "file": path]]]]
        }
        return try JSONDecoder().decode(PlexProvider.PlexMetadata.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func unrelatedLooseBooksKeepTheirOwnIdentityAndTimeline() throws {
        let album = try metadata("1", title: "[Unknown Album]")
        let tracks = try [metadata("2", title: "First", path: "/books/First.m4b"),
            metadata("3", title: "Second", path: "/books/Second.mp3"),
            metadata("4", title: "Third", path: "/books/Third.m4b")]
        let books = provider.mapPlexAlbum(album, tracks: tracks, libraryId: "library", libraryRoots: ["/books"])
        #expect(books.map(\.id) == ["2", "3", "4"])
        #expect(books.map(\.title) == ["First", "Second", "Third"])
        #expect(books.allSatisfy { $0.duration == 45 && $0.audioTracks?.count == 1 })
        #expect(books.allSatisfy { $0.seriesInfo?.name != "[Unknown Album]" })
        #expect(resolvePlexProgressTarget(book: books[1], currentTime: 12).ratingKey == "3")
    }

    @Test func numberedChaptersKeepAlbumIdentityAndUseFolderTitle() throws {
        let album = try metadata("1", title: "Unknown Album (02/01/2018 7:34:00 PM)")
        let tracks = try [metadata("2", title: "Story", path: "/books/Story/001 Story.mp3"),
            metadata("3", title: "Story", path: "/books/Story/002 Story.mp3")]
        let books = provider.mapPlexAlbum(album, tracks: tracks, libraryId: "library", libraryRoots: ["/books"])
        #expect(books.count == 1)
        #expect(books.first?.id == "1")
        #expect(books.first?.title == "Story")
        #expect(books.first?.duration == 90)
        #expect(books.first?.audioTracks?.map(\.startOffset) == [0, 45])
    }

    @Test func genericPartNamesStayTogether() throws {
        let tracks = try [metadata("2", title: "Part 001", path: "/books/Story/Part 001.mp3"),
            metadata("3", title: "Part 002", path: "/books/Story/Part 002.mp3")]
        let books = provider.mapPlexAlbum(try metadata("1", title: "[Unknown Album]"), tracks: tracks, libraryId: "library", libraryRoots: ["/books"])
        #expect(books.count == 1)
        #expect(books.first?.title == "Story")
    }

    @Test func namedAlbumPreservesItsMetadata() throws {
        let tracks = try [metadata("2", title: "First", path: "/books/First.mp3"),
            metadata("3", title: "Second", path: "/books/Second.mp3")]
        let books = provider.mapPlexAlbum(try metadata("1", title: "Named Album"), tracks: tracks, libraryId: "library", libraryRoots: ["/books"])
        #expect(books.count == 1)
        #expect(books.first?.title == "Named Album")
        #expect(books.first?.id == "1")
    }
    @Test func unnumberedChaptersStayInTheirBookFolder() throws {
        let tracks = try [metadata("2", title: "Prologue", path: "/books/Story/Prologue.mp3"),
            metadata("3", title: "The Journey", path: "/books/Story/The Journey.mp3"),
            metadata("4", title: "Epilogue", path: "/books/Story/Epilogue.mp3")]
        let books = provider.mapPlexAlbum(try metadata("1", title: "[Unknown Album]"), tracks: tracks,
            libraryId: "library", libraryRoots: ["/books"])
        #expect(books.count == 1)
        #expect(books.first?.title == "Story")
        #expect(books.first?.id == "1")
    }

    @Test func discFoldersKeepOneBookInNaturalOrder() throws {
        let tracks = try [metadata("20", title: "Second", path: "/books/Story/CD2/01.mp3"),
            metadata("30", title: "First", path: "/books/Story/CD1/02.mp3"),
            metadata("10", title: "Opening", path: "/books/Story/CD1/01.mp3")]
        let books = provider.mapPlexAlbum(try metadata("1", title: "[Unknown Album]"), tracks: tracks,
            libraryId: "library", libraryRoots: ["/books"])
        #expect(books.count == 1)
        #expect(books.first?.title == "Story")
        #expect(books.first?.audioTracks?.map(\.id) == ["10", "30", "20"])
    }

    @Test func numberedRootBooksAreNotMistakenForChapters() throws {
        let tracks = try [metadata("2", title: "1984", path: "/books/1984.m4b"),
            metadata("3", title: "First", path: "/books/01 First Book.m4b"),
            metadata("4", title: "Second", path: "/books/02 Second Book.m4b")]
        let books = provider.mapPlexAlbum(try metadata("1", title: "[Unknown Album]"), tracks: tracks,
            libraryId: "library", libraryRoots: ["/books"])
        #expect(books.map(\.title) == ["1984", "01 First Book", "02 Second Book"])
    }

    @Test func missingPathsOrLibraryRootsKeepAlbumIdentity() throws {
        let album = try metadata("1", title: "[Unknown Album]")
        let tracks = try [metadata("2", title: "Chapter"), metadata("3", title: "Another")]
        #expect(provider.mapPlexAlbum(album, tracks: tracks, libraryId: "library", libraryRoots: ["/books"]).first?.id == "1")
        let located = try [metadata("2", title: "First", path: "/books/First.m4b"), metadata("3", title: "Second", path: "/books/Second.m4b")]
        #expect(provider.mapPlexAlbum(album, tracks: located, libraryId: "library").count == 1)
    }

    @Test func existingUserDataPreventsDestructiveRegrouping() {
        var book = Book(id: "album", title: "Unknown Album", mediaType: .audiobook)
        #expect(!PlexProvider.shouldPreserveAlbum(book, hasBookmarks: false, isDownloaded: false))
        #expect(PlexProvider.shouldPreserveAlbum(book, hasBookmarks: true, isDownloaded: false))
        #expect(PlexProvider.shouldPreserveAlbum(book, hasBookmarks: false, isDownloaded: true))
        book.currentTime = 60
        #expect(PlexProvider.shouldPreserveAlbum(book, hasBookmarks: false, isDownloaded: false))
        book.currentTime = 0
        book.isFinished = true
        #expect(PlexProvider.shouldPreserveAlbum(book, hasBookmarks: false, isDownloaded: false))
    }

}
