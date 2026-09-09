import Foundation
import Testing
@testable import enve

@MainActor
struct LinkedBookPassageTests {
    private let passage = "Beyond the silver river, Eleanor discovered a forgotten garden where crimson flowers bloomed beneath ancient willow trees."

    @Test func findsUniquePassageAndPreservesPrintedPunctuation() {
        let index = LinkedBookTextIndex(chunks: [chunk(passage)])
        let match = LinkedBookSparseMatcher.match(
            transcript: passage.lowercased(), expectedProgress: 0.5, in: index, requiresUniquePassage: true
        )
        #expect(match != nil)
        #expect(match?.href == "chapter.xhtml")
        #expect(passage.contains(match?.quote ?? "missing"))
    }

    @Test func refusesRepeatedPassageEvenAtExpectedPosition() {
        let index = LinkedBookTextIndex(chunks: [
            chunk(passage, index: 0),
            chunk("The distant mountains were hidden by thick rolling clouds as the travelers walked slowly toward their village.", index: 1),
            chunk(passage, index: 2),
        ])
        #expect(LinkedBookSparseMatcher.match(
            transcript: passage, expectedProgress: 0.1, in: index, requiresUniquePassage: true
        ) == nil)
    }

    @Test func refusesShortOrUnrelatedSpeech() {
        let index = LinkedBookTextIndex(chunks: [chunk(passage)])
        for text in ["Beyond the river", "The spacecraft entered orbit around Jupiter while mission control prepared their instruments for measuring radiation"] {
            #expect(LinkedBookSparseMatcher.match(
                transcript: text, expectedProgress: 0.5, in: index, requiresUniquePassage: true
            ) == nil)
        }
    }

    private func chunk(_ text: String, index: Int = 0) -> EbookContextChunk {
        EbookContextChunk(id: "chunk-\(index)", bookStableId: "ebook", title: nil,
                          href: "chapter.xhtml", index: index,
                          startProgress: Double(index) / 3, endProgress: Double(index + 1) / 3, text: text)
    }
}
