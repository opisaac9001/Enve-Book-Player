import Foundation
import Testing

@testable import enve

@MainActor
struct DownloadPlanTests {
    @Test func everyBookSourceHasARegisteredPlan() throws {
        let sources: [Book.BookSource] = [
            .plex, .audiobookshelf, .local, .smb, .webdav, .jellyfin, .emby, .booklore,
            .realdebrid, .torbox, .komga, .kavita, .opds, .storyteller, .bookOrbit, .silo,
        ]
        for source in sources {
            let mediaType: AppMediaType = [.komga, .kavita, .opds].contains(source) ? .ebook : .audiobook
            let plan = try DownloadPlanRegistry.shared.plan(for: makeBook(source: source, mediaType: mediaType))
            #expect(!plan.providerId.isEmpty)
            #expect(!plan.files.isEmpty)
            #expect(plan.postProcessing.contains(.cacheOfflineAssets))
        }
    }

    @Test func ebookProviderPlanDeclaresReaderDestinationAndValidation() throws {
        let plan = try DownloadPlanRegistry.shared.plan(for: makeBook(source: .booklore, mediaType: .ebook))

        #expect(plan.destination == .readerAsset)
        #expect(plan.files == [DownloadPlanFile(source: .providerSession, headers: [:], relativePath: nil)])
        #expect(plan.postProcessing == [.validateEbook, .persistReaderAsset, .cacheOfflineAssets])
    }

    @Test func serverPageOnlyProviderRejectsAudiobookPlan() {
        #expect(throws: (any Error).self) {
            try DownloadPlanRegistry.shared.plan(for: makeBook(source: .komga, mediaType: .audiobook))
        }
    }

    @Test func localPlanDeclaresLocalFileSource() throws {
        let plan = try DownloadPlanRegistry.shared.plan(for: makeBook(source: .local, mediaType: .audiobook))

        #expect(plan.destination == .audiobookDirectory)
        #expect(plan.files.first?.source == .localAsset)
    }

    @Test func plexPlanNormalizesEverySupportedPartKeyShape() {
        #expect(PlexDownloadPlanProvider.normalizedStreamPath("/library/parts/12/file") == "/library/parts/12/file")
        #expect(PlexDownloadPlanProvider.normalizedStreamPath("library/parts/12/file") == "/library/parts/12/file")
        #expect(PlexDownloadPlanProvider.normalizedStreamPath("12") == "/library/parts/12/file")
        #expect(PlexDownloadPlanProvider.normalizedStreamPath("audio/file.m4b") == "/audio/file.m4b")
    }

    @Test func webDAVPlanBuildsBasicAuthorizationWithoutLoggingCredentials() {
        #expect(
            WebDAVDownloadPlanProvider.basicAuthorizationHeader(username: "reader", password: "secret")
                == "cmVhZGVyOnNlY3JldA=="
        )
    }

    @Test func mediaServerPlansBuildStaticAudioURLs() {
        let jellyfin = JellyfinDownloadPlanProvider.streamURL(
            baseURL: "https://jellyfin.example/",
            itemId: "item one",
            token: "token"
        )
        let emby = EmbyDownloadPlanProvider.streamURL(
            baseURL: "https://emby.example/emby/",
            itemId: "item-two",
            token: "token"
        )

        #expect(jellyfin?.path == "/Audio/item one/stream")
        #expect(jellyfin?.query?.contains("static=true") == true)
        #expect(jellyfin?.query?.contains("api_key=token") == true)
        #expect(emby?.path == "/emby/Audio/item-two/stream")
        #expect(emby?.query?.contains("api_key=token") == true)
    }

    private func makeBook(source: Book.BookSource, mediaType: AppMediaType) -> Book {
        Book(
            id: "book-\(source.rawValue)",
            title: "Download Plan",
            mediaType: mediaType,
            libraryId: "library",
            providerId: UUID(),
            source: source
        )
    }
}
