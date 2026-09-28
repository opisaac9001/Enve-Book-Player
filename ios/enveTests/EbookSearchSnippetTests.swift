import Testing

@testable import enve

struct EbookSearchSnippetTests {
    @Test func aLongLeadInKeepsOnlyTheWholeWordsNearestTheMatch() {
        let before = "It was a dark and stormy night; the rain fell in torrents, except at occasional intervals, when it was checked by a violent gust of "

        let lead = EbookSearchResult.snippetLead(before)

        #expect(lead.hasPrefix("…"))
        #expect(lead.hasSuffix("violent gust of "))
        #expect(lead.count <= 62)
        #expect(!lead.dropFirst().hasPrefix(" "))
    }

    @Test func aShortLeadInIsKeptWithItsLineBreaksCollapsed() {
        #expect(EbookSearchResult.snippetLead("carrying\n  that very same ") == "carrying that very same ")
        #expect(EbookSearchResult.snippetLead("") == "")
    }
}
