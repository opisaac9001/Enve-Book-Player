import Foundation
import Testing

@testable import enve

// Fixtures are trimmed captures from the enve-lab servers with identities replaced.

@MainActor
struct GrimmoryResponseFixtureTests {
    @Test func currentUserDecodesNestedPermissions() throws {
        let user = try JSONDecoder().decode(GrimmoryUser.self, from: Data(
            #"""
            {"id":1,"username":"fixture-user","name":"Fixture User","email":"fixture@local.invalid",
             "locale":"en","theme":"grimmory","themeAccent":null,"provisioningMethod":"LOCAL","assignedLibraries":[],
             "permissions":{"admin":true,"canUpload":true,"canDownload":true,"canEditMetadata":true,"demoUser":false},
             "defaultPassword":false}
            """#.utf8))

        #expect(user.id == 1)
        #expect(user.username == "fixture-user")
        #expect(user.displayName == "Fixture User")
        #expect(user.email == "fixture@local.invalid")
        #expect(user.isAdmin)
        #expect(user.permissions.canDownload == true)
    }

    @Test func currentUserWithoutPermissionsObjectIsRejected() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GrimmoryUser.self, from: Data(
                #"{"id":1,"username":"fixture-user","name":"Fixture User","admin":true}"#.utf8))
        }
    }

    @Test func audiobookDetailPercentagesAreHundredths() throws {
        let fixture = Data(
            #"""
            {"id":30279,"title":"Chaptered M4B Book","readStatus":"READING","readProgress":0.35,"primaryFileType":"AUDIOBOOK",
             "epubProgress":{"cfi":"epubcfi(/6/2!/4,/2,/6/1:58)","href":null,"percentage":100.0,"updatedAt":"2026-09-19T22:28:25Z"},
             "audiobookProgress":{"positionMs":21000,"trackIndex":null,"percentage":35.0,"updatedAt":"2026-09-19T22:28:25Z"},
             "koreaderProgress":{"percentage":0.35,"device":null,"deviceId":null,"lastSyncTime":"2026-09-19T22:28:25Z"}}
            """#.utf8)
        let book = Book(id: "30279", title: "Chaptered M4B Book", duration: 60, source: .booklore, providerId: UUID(), libraryId: "3")

        let progress = try #require(BookloreProgressClient.decodeAudiobookProgress(fixture, for: book))

        #expect(progress.percentage == 0.35)
        #expect(progress.positionSeconds == 21)
    }

    @Test func readProgressFollowsTheServersMixedScale() {
        #expect(abs((BookloreBookMapper.fraction(fromPercent: 68.3333) ?? 0) - 0.683333) < 0.000_000_1)
        #expect(BookloreBookMapper.fraction(fromReadProgress: 0.683333) == 0.683333)
        #expect(BookloreBookMapper.fraction(fromReadProgress: 35.0) == 0.35)
        #expect(BookloreBookMapper.fraction(fromPercent: nil) == nil)
    }

    @Test func catalogSummariesMapProgressAndAudiobookCover() throws {
        let context = BookloreCatalogMapper.Context(
            providerId: UUID(),
            libraryId: "3",
            source: .booklore,
            serverURL: "http://books.example:6060/"
        )
        let ebook = try JSONDecoder().decode(BookloreBookSummary.self, from: Data(
            #"""
            {"id":30280,"title":"Enve Synthetic EPUB","authors":["Enve Test Lab"],"thumbnailUrl":"/api/books/30280/cover",
             "readStatus":"READING","libraryId":3,"addedOn":"2026-09-19T21:46:41Z","lastReadTime":"2026-09-20T01:21:15Z",
             "readProgress":0.683333,"primaryFileId":30283,"primaryFileType":"EPUB","primaryFileName":"Enve Dual Ebook Primary.epub",
             "isPhysical":false,"categories":[],"tags":[],"moods":[],"language":"en"}
            """#.utf8))
        let audiobook = try JSONDecoder().decode(BookloreBookSummary.self, from: Data(
            #"""
            {"id":13,"title":"Alice in Wonderland (Drama)","authors":["Alice Gerstenberg"],"thumbnailUrl":"/api/books/13/cover",
             "readStatus":"READING","libraryId":3,"addedOn":"2026-08-12T04:13:35Z","lastReadTime":"2026-09-14T16:14:24Z",
             "readProgress":0.0,"primaryFileId":13,"primaryFileType":"AUDIOBOOK","primaryFileName":"Alice in Wonderland (LibriVox Drama)",
             "audiobookCoverUpdatedOn":"2026-08-12T04:13:35Z","isPhysical":false,"categories":["BLOB"],"tags":[],"moods":[],"language":"en"}
            """#.utf8))

        let mappedEbook = BookloreCatalogMapper.book(from: ebook, context: context)
        let mappedAudiobook = BookloreCatalogMapper.book(from: audiobook, context: context)

        #expect(mappedEbook.ebookProgress == 0.683333)
        #expect(mappedEbook.coverURL?.path == "/api/v1/media/book/30280/cover")
        #expect(mappedAudiobook.mediaType == .audiobook)
        #expect(mappedAudiobook.coverURL?.path == "/api/v1/media/book/13/audiobook-thumbnail")
    }
}

@MainActor
struct StorytellerResponseFixtureTests {
    private static let bookJSON = #"""
        {"uuid":"5d1cd022-a0d1-4458-92f9-1a63f7c23190","id":906801410195636,"title":"Enve Synthetic EPUB","subtitle":null,
         "description":null,"language":"en","rating":null,"createdAt":"2026-08-12 04:17:25","updatedAt":"2026-08-21 07:13:42",
         "publicationDate":null,
         "authors":[{"uuid":"50c93687-8094-4a7f-b5f0-afbc982625ac","id":null,"name":"Enve Test Lab","fileAs":"Enve Test Lab"}],
         "narrators":[],"series":[],"tags":[],"collections":[],
         "status":{"uuid":"4aea2da5-d4e2-4251-8b3a-b7a85b8dcac3","name":"Read","createdAt":"2026-08-12 02:30:48","updatedAt":"2026-08-21 07:04:43"},
         "position":{"uuid":"5919c456-ade5-4109-b6d3-1855802942d3",
                     "locator":{"type":"application/xhtml+xml","locations":{"totalProgression":1},"href":""},
                     "timestamp":1789523022706,"createdAt":"2026-08-29 00:12:46","updatedAt":"2026-09-16 01:43:42"},
         "ebook":{"uuid":"1223fc2f-32d8-4588-bb28-98896347f4cd","filepath":"/data/assets/Enve Synthetic EPUB/text/Enve Synthetic EPUB.epub","missing":false},
         "audiobook":{"uuid":"4b352809-2344-4ea1-bd62-965045733eff","filepath":"/data/assets/Enve Synthetic EPUB/audio","missing":false,"duration":60},
         "readaloud":{"uuid":"0224ad3a-8f72-4f2a-bb86-096279e770d3","filepath":"/data/assets/Enve Synthetic EPUB/aligned/Enve Synthetic EPUB.epub",
                      "missing":false,"status":"ALIGNED","currentStage":"SYNC_CHAPTERS","stageProgress":1,"queuePosition":0,
                      "restartPending":null,"duration":60}}
        """#

    @Test func bookListEntryDecodesExactTypes() throws {
        let book = try JSONDecoder().decode(StorytellerBook.self, from: Data(Self.bookJSON.utf8))

        #expect(book.uuid == "5d1cd022-a0d1-4458-92f9-1a63f7c23190")
        #expect(book.authors.map(\.name) == ["Enve Test Lab"])
        #expect(book.status?.name == "Read")
        #expect(book.ebook?.missing == false)
        #expect(book.audiobook?.duration == 60)
        #expect(book.readaloud?.isReady == true)
        #expect(book.readaloud?.restartPending == nil)
        #expect(book.position?.timestamp == 1_789_523_022_706)
        #expect(book.position?.totalProgression == 1)
        #expect(book.position?.locatorComponents?.href == "")
    }

    @Test func queuedRestartModeIsAString() throws {
        let json = Self.bookJSON.replacingOccurrences(of: #""restartPending":null"#, with: #""restartPending":"sync""#)
        let book = try JSONDecoder().decode(StorytellerBook.self, from: Data(json.utf8))

        #expect(book.readaloud?.restartPending == "sync")
    }

    @Test func bookWithoutUUIDIsRejected() {
        let json = Self.bookJSON.replacingOccurrences(of: #""uuid":"5d1cd022-a0d1-4458-92f9-1a63f7c23190","#, with: "")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StorytellerBook.self, from: Data(json.utf8))
        }
    }

    @Test func positionEndpointDecodesTheLocatorObject() throws {
        let position = try JSONDecoder().decode(StorytellerPosition.self, from: Data(
            #"""
            {"userId":"00000000-0000-4000-8000-000000000000","bookUuid":"52dcb53d-1a6a-4c70-ac99-ceb6ecd650ae",
             "locator":{"locations":{"totalProgression":0,"progression":0,"fragments":["t=0.0"]},"href":"01 - Chapter 1.mp3","type":"audio/mpeg"},
             "timestamp":1789523022900}
            """#.utf8))

        let components = try #require(position.locatorComponents)
        #expect(position.timestamp == 1_789_523_022_900)
        #expect(components.href == "01 - Chapter 1.mp3")
        #expect(components.audioFragmentTime == 0)
        #expect(components.progression == 0)
        let locator = try JSONDecoder().decode(StorytellerLocator.self, from: Data(position.locatorJSONString.utf8))
        #expect(locator.type == "audio/mpeg")
        #expect(locator.locations?.fragments == ["t=0.0"])
    }

    @Test func listenManifestDecodesReadiumLinks() throws {
        let manifest = try JSONDecoder().decode(StorytellerAudioManifest.self, from: Data(
            #"""
            {"metadata":{"title":{"und":"Multi-file MP3 Book"}},
             "readingOrder":[{"href":"01 - Chapter 1.mp3","type":"audio/mpeg","title":"Track 1/3","rel":["chapter"],"size":100737,"duration":25.000249,"bitrate":32235},
                             {"href":"02 - Chapter 2.mp3","type":"audio/mpeg","title":"Track 2/3","rel":["chapter"],"size":100763,"duration":25.000249,"bitrate":32243}],
             "toc":[{"href":"01 - Chapter 1.mp3","type":"audio/mpeg","title":"Track 1/3","rel":["chapter"],"size":100737,"duration":25.000249,"bitrate":32235}]}
            """#.utf8))

        #expect(manifest.readingOrder.map(\.href) == ["01 - Chapter 1.mp3", "02 - Chapter 2.mp3"])
        #expect(manifest.readingOrder.first?.duration == 25.000249)
        #expect(manifest.toc?.first?.title == "Track 1/3")
        #expect(manifest.resources == nil)
    }

    @Test func userDecodesPermissionFlags() throws {
        let user = try JSONDecoder().decode(StorytellerUser.self, from: Data(
            #"""
            {"id":"00000000-0000-4000-8000-000000000000","name":"Fixture Admin","username":"fixture-admin","email":"fixture@local.invalid",
             "permissions":{"bookCreate":true,"bookDelete":true,"bookDownload":true,"bookList":true,"bookProcess":false,"bookRead":true}}
            """#.utf8))

        #expect(user.permissions.bookList)
        #expect(!user.permissions.bookProcess)
    }
}

@MainActor
struct AudiobookshelfResponseFixtureTests {
    private static let itemJSON = #"""
        {"id":"92377ae3-f9d6-4faa-bbf1-309d9b1bd7f5","libraryId":"e68f0320-7a57-4ad4-a13f-8bcc6ad7c3ec","mediaType":"book",
         "addedAt":1786507738119,"updatedAt":1786507738119,
         "media":{"metadata":{"title":"Alice in Wonderland (Drama)","titleIgnorePrefix":"Alice in Wonderland (Drama)","subtitle":null,
                              "authors":[{"id":"67b0377c-0b17-49a6-8c17-318814221a33","name":"Alice Gerstenberg"}],
                              "narrators":[],"series":[],"genres":[],"publishedYear":null,"language":null,
                              "authorName":"Alice Gerstenberg","narratorName":"","seriesName":""},
                  "coverPath":null,"duration":17921.830385999998,
                  "chapters":[{"start":0,"end":125.002472,"title":"00 - Credits","id":0},
                              {"start":125.002472,"end":2413.018821,"title":"01 - Act 1","id":1}],
                  "audioFiles":[{"index":1,"ino":"14155921","duration":6057.528889,
                                 "chapters":[{"start":0,"end":125.002472,"title":"00 - Credits","id":0}],
                                 "metadata":{"filename":"Alice in Wonderland - chaptered.m4b"}}],
                  "tags":[]}}
        """#

    @Test func expandedBookItemDecodesAuthorsAndChapters() throws {
        let item = try AudiobookshelfProvider.decodePodcastItem(Data(Self.itemJSON.utf8))

        #expect(item.title == "Alice in Wonderland (Drama)")
        #expect(item.author == "Alice Gerstenberg")
    }

    @Test func chapterWithoutTitleIsRejected() {
        let json = Self.itemJSON.replacingOccurrences(of: #""title":"01 - Act 1","#, with: "")
        #expect(throws: DecodingError.self) {
            try AudiobookshelfProvider.decodePodcastItem(Data(json.utf8))
        }
    }
}

nonisolated private final class BookOrbitCardProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.path == "/api/v1/libraries/1/books" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let body = Data(
            #"""
            {"items":[{"id":42,"status":"present","title":"Pride and Prejudice","seriesId":null,"seriesName":null,"seriesIndex":null,
                       "authors":["Jane Austen"],"files":[{"id":58,"format":"epub","role":"primary","sizeBytes":24835612}],
                       "publishedYear":1998,"language":"en","genres":[],"rating":null,"readingProgress":3.1977992,
                       "readStatus":{"status":"reading","source":"auto","startedAt":"2026-09-25T00:00:00.000Z","finishedAt":null,
                                     "updatedAt":"2026-09-25T23:28:33.130Z"},
                       "addedAt":"2026-09-20T06:36:20.770Z","hasCover":true,"narrators":[],"tags":[]}],
             "total":1,"page":0,"size":200}
            """#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
struct BookOrbitResponseFixtureTests {
    @Test func readingProgressIsAPercentage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BookOrbitCardProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = BookOrbitProvider(
            connection: ServerConnection(name: "Fixture", url: "https://bookorbit.invalid", type: .bookOrbit, token: "fixture-token"),
            session: session
        )

        let book = try #require(try await provider.fetchBooks(libraryId: "1").first)

        #expect(abs((book.ebookProgress ?? 0) - 0.031977992) < 0.000_000_1)
        #expect(book.serverReadStatus == "READING")
    }
}
