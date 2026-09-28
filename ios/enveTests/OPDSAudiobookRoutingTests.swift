import Foundation
import Testing

@testable import enve

/// Check direct audio playback and downloads, and reject unsupported formats.
@MainActor
struct OPDSAudiobookRoutingTests {
    private static let providerId = UUID(uuidString: "0F17E6A0-3333-4222-8333-444444444444")!
    private let base = URL(string: "https://catalog.example.invalid/opds/")!

    // MARK: Classification

    @Test(arguments: ["audio/mpeg", "audio/mp4", "audio/flac", "audio/ogg"])
    func aDirectAudioAcquisitionBecomesAnAudiobook(type: String) throws {
        let acquisition = try downloadable([
            OPDSLink(href: "chapter", type: type, rels: ["http://opds-spec.org/acquisition"])
        ])

        #expect(acquisition.format == .audio)
        #expect(acquisition.format.mediaType == .audiobook)
        #expect(acquisition.format.ebookFormat == nil)
    }

    @Test func anAudioExtensionWithoutADeclaredTypeIsStillAnAudiobook() throws {
        let acquisition = try downloadable([
            OPDSLink(href: "book.m4b", type: "application/octet-stream", rels: ["http://opds-spec.org/acquisition"])
        ])

        #expect(acquisition.format == .audio)
    }

    @Test(arguments: [
        ("book.aax", nil as String?),
        ("book.aa", nil as String?),
        ("fulfil", "audio/vnd.audible.aax"),
    ])
    func audibleFilesAreRefusedAsProtectedRatherThanPlayed(href: String, type: String?) {
        let selection = OPDSAcquisitionSelector.select(
            links: [OPDSLink(href: href, type: type, rels: ["http://opds-spec.org/acquisition"])],
            baseURL: base
        )

        guard case .rejected(let reason) = selection else {
            Issue.record("\(href) was accepted as a playable audiobook")
            return
        }
        #expect(reason.contains("Audible DRM"))
    }

    @Test func readiumAudiobookPackagesAndManifestsStayRefused() {
        for type in ["application/audiobook+zip", "application/audiobook+json"] {
            let selection = OPDSAcquisitionSelector.select(
                links: [OPDSLink(href: "pub", type: type, rels: ["http://opds-spec.org/acquisition"])],
                baseURL: base
            )
            guard case .rejected(let reason) = selection else {
                Issue.record("\(type) was accepted although Enve cannot play it")
                continue
            }
            #expect(reason.contains("not a format Enve can open"))
        }
    }

    @Test func anAudioPublicationKeepsItsAudiobookMediaTypeThroughTheFeedParser() throws {
        let parsed = try OPDSFeedParser.parse(
            document: OPDSFeedDocument(
                url: URL(string: "https://catalog.example.invalid/opds/root.json")!,
                contentType: "application/opds+json",
                data: Data(
                    """
                    {"metadata":{"title":"Root"},
                     "links":[{"rel":"self","href":"root.json","type":"application/opds+json"}],
                     "publications":[
                       {"metadata":{"identifier":"urn:audio","title":"Narrated","duration":3600,
                         "narrator":["N. Narrator"]},
                        "links":[{"rel":"http://opds-spec.org/acquisition/open-access",
                                  "href":"narrated.m4b","type":"audio/mp4"}]}
                     ]}
                    """.utf8
                )
            ),
            context: OPDSCatalogContext(providerId: Self.providerId, libraryId: "opds-root")
        )

        let book = try #require(parsed.books.first)
        #expect(book.mediaType == .audiobook)
        #expect(book.ebookFormat == nil)
        #expect(book.duration == 3600)
        #expect(book.partKey == "https://catalog.example.invalid/opds/narrated.m4b")
    }

    // MARK: Provider playback surface

    @Test func theProviderHandsBackTheDirectAudioURLOnTheFeedOrigin() async throws {
        let provider = OPDSProvider(connection: Self.connection())
        let book = Self.book(mediaType: .audiobook, partKey: "https://catalog.example.invalid/opds/narrated.m4b")

        #expect(provider.getAudioURL(for: book)?.absoluteString == book.partKey)

        let session = try await provider.startPlaybackSession(for: book)
        #expect(session.audioTracks.count == 1)
        #expect(session.audioTracks.first?.contentUrl == book.partKey)
        #expect(session.audioTracks.first?.mimeType == "audio/mp4")
        #expect(session.chapters.isEmpty)
    }

    @Test func streamingHeadersCarryTheFeedCredentials() {
        let provider = OPDSProvider(connection: Self.connection())

        let headers = provider.getStreamingHeaders()

        #expect(headers["Authorization"] == "Bearer feed-token")
        #expect(headers["CF-Access-Client-Id"] == "client-id")
    }

    @Test(arguments: [
        "https://evil.example.invalid/opds/narrated.m4b",
        "http://catalog.example.invalid/opds/narrated.m4b",
        "https://catalog.example.invalid:8443/opds/narrated.m4b",
    ])
    func aCrossOriginAudioAcquisitionIsNotStreamed(partKey: String) async {
        let provider = OPDSProvider(connection: Self.connection())
        let book = Self.book(mediaType: .audiobook, partKey: partKey)

        #expect(provider.getAudioURL(for: book) == nil)
        await #expect(throws: (any Error).self) {
            try await provider.startPlaybackSession(for: book)
        }
    }

    @Test func anEbookNeverResolvesToAnAudioURL() async {
        let provider = OPDSProvider(connection: Self.connection())
        let book = Self.book(mediaType: .ebook, partKey: "https://catalog.example.invalid/opds/book.epub")

        #expect(provider.getAudioURL(for: book) == nil)
        await #expect(throws: (any Error).self) {
            try await provider.startPlaybackSession(for: book)
        }
    }

    // MARK: Download planning

    @Test func anOPDSAudiobookPlansAnAudiobookDownload() throws {
        let plan = try DownloadPlanRegistry.shared.plan(
            for: Self.book(mediaType: .audiobook, partKey: "https://catalog.example.invalid/opds/narrated.m4b")
        )

        #expect(plan.providerId == "opds")
        #expect(plan.destination == .audiobookDirectory)
        #expect(plan.postProcessing == [.cacheOfflineAssets])
    }

    @Test func anOPDSEbookStillPlansAValidatedReaderDownload() throws {
        let plan = try DownloadPlanRegistry.shared.plan(
            for: Self.book(mediaType: .ebook, partKey: "https://catalog.example.invalid/opds/book.epub")
        )

        #expect(plan.providerId == "opds")
        #expect(plan.destination == .readerAsset)
        #expect(plan.postProcessing == [.validateEbook, .persistReaderAsset, .cacheOfflineAssets])
    }

    // MARK: Fixtures

    private static func connection() -> ServerConnection {
        ServerConnection(
            name: "Fixture",
            url: "https://catalog.example.invalid/opds/",
            type: .opds,
            token: "feed-token",
            customHeaders: ["CF-Access-Client-Id": "client-id"]
        )
    }

    private static func book(mediaType: AppMediaType, partKey: String) -> Book {
        Book(
            id: "urn:audio",
            title: "Narrated",
            duration: 3600,
            partKey: partKey,
            mediaType: mediaType,
            libraryId: OPDSProvider.rootLibraryId,
            providerId: providerId,
            source: .opds
        )
    }

    private func downloadable(_ links: [OPDSLink]) throws -> OPDSAcquisition {
        guard case .downloadable(let acquisition) = OPDSAcquisitionSelector.select(links: links, baseURL: base) else {
            throw SelectionFailure()
        }
        return acquisition
    }

    private struct SelectionFailure: Error {}
}
