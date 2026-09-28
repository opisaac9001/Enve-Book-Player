import Testing

@testable import enve

@MainActor
struct RemoteEbookCacheIdentityTests {
    @Test func distinguishesBookIdentifiersThatShareAPrefix() {
        #expect(LocalEbookImporter.matchesRemoteBookIdentifier("1-Book.epub", identifier: "1"))
        #expect(LocalEbookImporter.matchesRemoteBookIdentifier("1.epub", identifier: "1"))
        #expect(!LocalEbookImporter.matchesRemoteBookIdentifier("18-Other.epub", identifier: "1"))
        #expect(!LocalEbookImporter.matchesRemoteBookIdentifier("10.epub", identifier: "1"))
        #expect(!LocalEbookImporter.matchesRemoteBookIdentifier("book-10.epub", identifier: "book-1"))
    }
}
