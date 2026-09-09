import CoreGraphics
import Testing

@testable import enve

struct CoverTileTests {
    @Test func audiobookArtworkUsesSquareRatio() {
        let book = Book(id: "audio", title: "Audio", mediaType: .audiobook)

        #expect(book.hearthCoverRatio == 1)
    }

    @Test func ebookArtworkUsesPortraitRatio() {
        let book = Book(id: "ebook", title: "Ebook", mediaType: .ebook)

        #expect(book.hearthCoverRatio == 1.5)
    }
}
