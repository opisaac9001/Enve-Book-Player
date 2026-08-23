import Foundation
import Testing

@testable import enve

struct ProviderEbookAPIContractTests {
    @Test @MainActor func providersExposeOnlyImplementedOptionalCapabilities() {
        let opds: any ProviderConnectionHandling = OPDSProvider(connection: connection(type: .opds))
        #expect(opds is any EbookDownloadProvider)
        #expect(!(opds is any PlaybackSessionProvider))
        #expect(!(opds is any EbookProgressPulling))
        #expect(!(opds is any EbookProgressPushing))

        let komga: any ProviderConnectionHandling = KomgaProvider(connection: connection(type: .komga))
        #expect(komga is any EbookDownloadProvider)
        #expect(komga is any EbookProgressPushing)
        #expect(!(komga is any EbookProgressPulling))
        #expect(komga is any ServerPageProvider)
        #expect(!(komga is any PlaybackSessionProvider))

        let webDAV: any ProviderConnectionHandling = WebDAVProvider(connection: connection(type: .webdav))
        #expect(webDAV is any PlaybackSessionProvider)
        #expect(webDAV is any EbookDownloadProvider)
        #expect(!(webDAV is any AudiobookProgressPulling))
        #expect(!(webDAV is any AudiobookProgressPushing))
        #expect(!(webDAV is any EbookProgressPulling))
        #expect(!(webDAV is any EbookProgressPushing))

        let booklore: any ProviderConnectionHandling = BookloreProvider(connection: connection(type: .booklore))
        #expect(booklore is any PlaybackSessionProvider)
        #expect(booklore is any AudiobookProgressProvider)
        #expect(booklore is any EbookProgressProvider)
        #expect(booklore is any EbookDownloadProvider)
        #expect(booklore is any PersonalRatingProvider)
    }

    @Test func audiobookshelfClassifiesEbookOnlyBookLibraryItemsAsEbooks() {
        let mediaType = ABSMediaTypeClassifier.classify(
            libraryMediaType: "book",
            itemMediaType: "book",
            hasAudio: false,
            ebookFormat: "epub",
            hasEbookFile: false
        )

        #expect(mediaType == .ebook)
    }

    @Test func audiobookshelfKeepsDualFormatItemsAudiobookFirst() {
        let mediaType = ABSMediaTypeClassifier.classify(
            libraryMediaType: "book",
            itemMediaType: "book",
            hasAudio: true,
            ebookFormat: "epub",
            hasEbookFile: false
        )

        #expect(mediaType == .audiobook)
    }

    @Test func grimmoryProgressPayloadUsesNativeAppContract() throws {
        let request = BookloreProgressClient.EbookProgressRequest(
            fileProgress: .init(
                bookFileId: 107,
                positionData: "epubcfi(/6/4!/4/2:3)",
                positionHref: "chapter.xhtml",
                progressPercent: 42,
                ttsPositionCfi: "epubcfi(/6/4!/4/4:1)",
                contentSourceProgressPercent: 18
            )
        )
        let root = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                as? [String: Any]
        )
        #expect(Set(root.keys) == ["fileProgress"])

        let fileProgress = try #require(
            root["fileProgress"] as? [String: Any]
        )
        #expect(
            Set(fileProgress.keys) == [
                "bookFileId",
                "positionData",
                "positionHref",
                "progressPercent",
                "ttsPositionCfi",
                "contentSourceProgressPercent",
            ]
        )
        #expect(fileProgress["bookFileId"] as? Int == 107)
        #expect(fileProgress["positionData"] as? String == "epubcfi(/6/4!/4/2:3)")
        #expect(fileProgress["positionHref"] as? String == "chapter.xhtml")
        #expect(fileProgress["progressPercent"] as? Double == 42)
        #expect(fileProgress["contentSourceProgressPercent"] as? Double == 18)
    }

    @Test func siloProgressPayloadUsesServerContract() throws {
        let request = SiloEbookProgressUpdateRequest(
            fileID: 51,
            location: "epubcfi(/6/4!/4/2:3)",
            progress: 0.42
        )
        let root = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                as? [String: Any]
        )

        #expect(Set(root.keys) == ["file_id", "location", "progress"])
        #expect(root["file_id"] as? Int == 51)
        #expect(root["location"] as? String == "epubcfi(/6/4!/4/2:3)")
        #expect(root["progress"] as? Double == 0.42)
    }

    @MainActor
    private func connection(type: ProviderType) -> ServerConnection {
        ServerConnection(
            name: "Fixture",
            url: "https://provider.example.test",
            type: type
        )
    }
}
