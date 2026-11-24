import Foundation
import Testing

@testable import enve

@MainActor
struct BookloreProgressClientTests {
    @Test func currentAppFixtureMapsTrackRelativePosition() throws {
        let fixture = Data(
            """
            {
              "readStatus": "READING",
              "readProgress": 35,
              "lastReadTime": "2026-08-21T12:30:45.123Z",
              "durationSeconds": 300,
              "audiobookProgress": {
                "positionMs": 25000,
                "trackIndex": 1,
                "percentage": 40,
                "updatedAt": "2026-08-21T12:29:00Z"
              }
            }
            """.utf8
        )
        let book = Book(
            id: "42",
            title: "Fixture",
            duration: 300,
            chapters: [
                Chapter(id: "one", start: 0, end: 100, title: "One", index: 0),
                Chapter(id: "two", start: 100, end: 300, title: "Two", index: 1),
            ],
            source: .booklore,
            providerId: UUID(),
            libraryId: "tests"
        )

        let progress = BookloreProgressClient.decodeAudiobookProgress(fixture, for: book)

        #expect(progress?.positionSeconds == 125)
        #expect(progress?.percentage == 0.4)
        #expect(progress?.trackIndex == 1)
        #expect(progress?.readState == .reading)
        #expect(progress?.updatedAt == BookloreProgressClient.parseTimestamp("2026-08-21T12:29:00Z"))
    }

    @Test func audiobookProgressReadsTheAppProgressEndpoint() async {
        let fixture = Data(
            """
            {
              "readStatus": "READING",
              "lastReadTime": "2026-08-21T12:30:45Z",
              "audiobookProgress": {
                "positionMs": 40000,
                "percentage": 40,
                "updatedAt": "2026-08-21T12:29:00Z"
              }
            }
            """.utf8
        )
        let (client, paths) = Self.client(status: 200, body: fixture)
        let book = Book(id: "42", title: "Audio", duration: 100, source: .booklore, providerId: UUID(), libraryId: "tests")

        let progress = await client.fetchAudiobookProgress(for: book, bookId: "42")
        let percentage = await client.fetchAudiobookPercentage(bookId: "42")

        #expect(paths() == ["/api/v1/app/books/42/progress", "/api/v1/app/books/42/progress"])
        #expect(progress?.positionSeconds == 40)
        #expect(progress?.percentage == 0.4)
        #expect(percentage == 40)
    }

    @Test func unavailableAudiobookProgressDoesNotFallBackToTheBookResponse() async {
        let (client, paths) = Self.client(status: 404, body: Data())
        let book = Book(id: "42", title: "Audio", source: .booklore, providerId: UUID(), libraryId: "tests")

        let progress = await client.fetchAudiobookProgress(for: book, bookId: "42")

        #expect(progress == nil)
        #expect(paths() == ["/api/v1/app/books/42/progress"])
    }

    @Test func resolvesFileIdAndBuildsAudiobookProgressRequest() async throws {
        var requests: [URLRequest] = []
        let client = BookloreProgressClient(
            makeRequest: { path in
                URLRequest(url: URL(string: "https://example.invalid\(path)")!)
            },
            performAuthorizedRequest: { request in
                requests.append(request)
                let isInfoRequest = request.url!.path.hasSuffix("/info")
                let data = isInfoRequest ? Data(#"{"bookFileId":77}"#.utf8) : Data()
                return (
                    data,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: isInfoRequest ? 200 : 204,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )
        let book = Book(
            id: "42",
            title: "Push Fixture",
            duration: 100,
            source: .booklore,
            providerId: UUID(),
            libraryId: "tests"
        )

        let fraction = try await client.updateAudiobookProgress(
            for: book,
            bookId: "42",
            sessionId: nil,
            currentTime: 40,
            duration: 100,
            isFinished: false
        )

        #expect(requests.map { $0.url!.path } == [
            "/api/v1/audiobooks/42/info",
            "/api/v1/books/progress",
        ])
        #expect(requests.last?.httpMethod == "POST")
        let body = try #require(requests.last?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let fileProgress = try #require(json["fileProgress"] as? [String: Any])
        #expect(json["bookId"] as? Int == 42)
        #expect(fileProgress["bookFileId"] as? Int == 77)
        #expect(fileProgress["positionData"] as? String == "40000")
        #expect(fileProgress["positionHref"] == nil)
        #expect(fileProgress["progressPercent"] as? Double == 40)
        #expect(fraction == 0.4)
        #expect(BookloreProgressClient.audiobookFileId(from: "grimmory_42_88") == 88)
    }

    @Test func bookEpubProgressMapsExactCFIAndBookLevelTimestamp() throws {
        let progress = try Self.ebookProgress(
            """
            {"id":42,"readStatus":"READING","lastReadTime":"2026-08-21T12:30:00Z",
             "epubProgress":{"percentage":40,"cfi":"epubcfi(/6/2[chapter]!/4/2/2:0)","href":"chapter.xhtml"}}
            """,
            usesEpubProgress: true
        )

        #expect(progress?.progress == 0.4)
        #expect(progress?.readState == .reading)
        #expect(EpubLocationBridge.epubCFI(from: progress?.locator) == "epubcfi(/6/2[chapter]!/4/2/2:0)")
        #expect(progress?.updatedAt == BookloreProgressClient.parseTimestamp("2026-08-21T12:30:00Z"))
    }

    @Test func bookPdfProgressMapsServerPageToLocalPage() throws {
        let progress = try Self.ebookProgress(
            """
            {"id":42,"readStatus":"READING","lastReadTime":"2026-08-21 12:30:00",
             "pdfProgress":{"page":7,"percentage":30}}
            """,
            usesEpubProgress: false
        )

        #expect(progress?.progress == 0.3)
        #expect(progress?.locator == "{\"page\":6}")
        #expect(progress?.updatedAt == BookloreProgressClient.parseTimestamp("2026-08-21 12:30:00"))
    }

    @Test func bookEpubProgressPreservesReadAloudLocator() throws {
        let locator = "{\"href\":\"chapter.xhtml\",\"locations\":{\"totalProgression\":0.4,\"progression\":0.2,\"fragments\":[\"sentence-4\"]}}"
        let fixture = try JSONSerialization.data(withJSONObject: [
            "id": 42,
            "readStatus": "READING",
            "epubProgress": ["percentage": 40, "cfi": locator, "href": "chapter.xhtml"],
        ])
        let detail = try JSONDecoder().decode(BookloreLegacyBook.self, from: fixture)

        let progress = BookloreProgressClient.ebookProgress(for: Self.ebook, from: detail, usesEpubProgress: true)

        #expect(progress?.progress == 0.4)
        #expect(progress?.locator == locator)
    }

    @Test func fileChapterProgressRestoresTheChapterPosition() throws {
        let progress = try Self.ebookProgress(
            """
            {"id":42,"readStatus":"READING",
             "epubProgress":{"percentage":42,"href":"OEBPS/Text/chapter03.xhtml","contentSourceProgressPercent":37.5}}
            """,
            usesEpubProgress: true
        )

        #expect(progress?.progress == 0.42)
        #expect(EpubLocationBridge.href(from: progress?.locator) == "OEBPS/Text/chapter03.xhtml")
        #expect(EpubLocationBridge.totalProgression(from: progress?.locator) == 0.42)
        #expect(EpubLocationBridge.canRestoreDirectly(progress?.locator))
        let locations = try #require(Self.locations(progress?.locator))
        #expect(locations["progression"] as? Double == 0.375)
    }

    @Test func linkedTextEstimateRestoresAfterServerRounding() throws {
        let fixture = try JSONSerialization.data(withJSONObject: [
            "id": 42,
            "readStatus": "READING",
            "epubProgress": [
                "percentage": 46.2,
                "cfi": #"{"locations":{"totalProgression":0.46196038405835971}}"#,
            ],
        ])
        let detail = try JSONDecoder().decode(BookloreLegacyBook.self, from: fixture)
        let progress = try #require(BookloreProgressClient.ebookProgress(for: Self.ebook, from: detail, usesEpubProgress: true))
        #expect(SharedReadingLocator.object(progress.locator)?["enveSharedPosition"] as? Bool == true)
        #expect(Self.locations(progress.locator)?["totalProgression"] as? Double == progress.progress)
        #expect(EpubLocationBridge.href(from: progress.locator) == nil)
    }

    @Test func fileCFIWinsOverChapterProgression() throws {
        let progress = try Self.ebookProgress(
            """
            {"id":42,"readStatus":"READING",
             "epubProgress":{"percentage":10,"href":"chapter.xhtml","cfi":"epubcfi(/6/2!/4/2/2:0)","contentSourceProgressPercent":50}}
            """,
            usesEpubProgress: true
        )

        #expect(EpubLocationBridge.epubCFI(from: progress?.locator) == "epubcfi(/6/2!/4/2/2:0)")
        #expect(Self.locations(progress?.locator)?["progression"] == nil)
    }

    @Test func epubPercentageWithoutPositionHasNoLocator() throws {
        let progress = try Self.ebookProgress(
            #"{"id":42,"readStatus":"READING","epubProgress":{"percentage":10,"href":"chapter.xhtml"}}"#,
            usesEpubProgress: true
        )

        #expect(progress?.progress == 0.1)
        #expect(progress?.locator == nil)
    }

    @Test func bookComicProgressMapsServerPageToLocalPage() throws {
        let progress = try Self.ebookProgress(
            """
            {"id":42,"readStatus":"READING","lastReadTime":"2026-09-14T07:00:00Z",
             "cbxProgress":{"percentage":37,"page":4}}
            """,
            usesEpubProgress: false
        )

        #expect(progress?.progress == 0.37)
        #expect(progress?.locator == "cbz-page:3")
        #expect(progress?.updatedAt == BookloreProgressClient.parseTimestamp("2026-09-14T07:00:00Z"))
    }

    @Test func koreaderPercentageIsAlreadyScaledInBookResponses() throws {
        let progress = try Self.ebookProgress(
            #"{"id":42,"readStatus":"READING","koreaderProgress":{"percentage":25}}"#,
            usesEpubProgress: true
        )

        #expect(progress?.progress == 0.25)
    }

    @Test func audiobookProgressNeverBecomesEbookProgress() throws {
        let progress = try Self.ebookProgress(
            """
            {"id":42,"readStatus":"READING",
             "audiobookProgress":{"positionMs":60000,"trackIndex":2,"percentage":80}}
            """,
            usesEpubProgress: true
        )

        #expect(progress == nil)
    }

    @Test func updateEbookProgressPostsCanonicalFileProgressForEPUBResource() async throws {
        var capturedRequest: URLRequest?
        let client = Self.capturingClient { capturedRequest = $0 }
        let locator = EpubLocationBridge.readiumLocator(
            href: "chapter.xhtml",
            epubCFI: "epubcfi(/6/2[chapter]!/4/2/2:0)",
            fraction: 0.4,
            resourceProgression: 0.4,
            sourceEngine: .foliate
        )

        try await client.updateEbookProgress(
            for: Self.ebook,
            bookId: 42,
            resourceFileId: 107,
            resourceFormat: "epub",
            progress: 0.4,
            epubLocator: locator,
            sourceEngine: .foliate
        )

        let request = try #require(capturedRequest)
        #expect(request.url?.path == "/api/v1/books/progress")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["bookId"] as? Int == 42)
        #expect(root["epubProgress"] == nil)
        let fileProgress = try #require(root["fileProgress"] as? [String: Any])
        #expect(fileProgress["bookFileId"] as? Int == 107)
        #expect(fileProgress["positionData"] as? String == "epubcfi(/6/2[chapter]!/4/2/2:0)")
        #expect(fileProgress["positionHref"] as? String == "chapter.xhtml")
        #expect(fileProgress["progressPercent"] as? Double == 40)
        #expect(fileProgress["contentSourceProgressPercent"] as? Double == 40)
    }

    @Test func updateEbookProgressPreservesReadAloudLocatorForEPUBResource() async throws {
        var capturedRequest: URLRequest?
        let client = Self.capturingClient { capturedRequest = $0 }
        let locator = "{\"href\":\"chapter.xhtml\",\"type\":\"application/xhtml+xml\",\"locations\":{\"totalProgression\":0.4,\"progression\":0.2,\"fragments\":[\"sentence-4\"]}}"

        try await client.updateEbookProgress(
            for: Self.ebook,
            bookId: 42,
            resourceFileId: 107,
            resourceFormat: "epub",
            progress: 0.4,
            epubLocator: locator,
            sourceEngine: nil
        )

        let body = try #require(capturedRequest?.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let fileProgress = try #require(root["fileProgress"] as? [String: Any])
        #expect(fileProgress["positionData"] as? String == locator)
        #expect(fileProgress["positionHref"] as? String == "chapter.xhtml")
        #expect(fileProgress["contentSourceProgressPercent"] as? Double == 20)
    }

    @Test func updateEbookProgressUsesFileProgressContractForPDF() async throws {
        var capturedRequest: URLRequest?
        let client = Self.capturingClient { capturedRequest = $0 }

        try await client.updateEbookProgress(
            for: Self.ebook,
            bookId: 42,
            resourceFileId: 107,
            resourceFormat: "pdf",
            progress: 0.3,
            epubLocator: "{\"page\":7}",
            sourceEngine: nil
        )

        let request = try #require(capturedRequest)
        #expect(request.url?.path == "/api/v1/books/progress")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["bookId"] as? Int == 42)
        let fileProgress = try #require(root["fileProgress"] as? [String: Any])
        #expect(fileProgress["bookFileId"] as? Int == 107)
        #expect(fileProgress["positionData"] as? String == "8")
        #expect(fileProgress["progressPercent"] as? Double == 30)
    }

    @Test func updateEbookProgressUsesFileProgressContractForComic() async throws {
        var capturedRequest: URLRequest?
        let client = Self.capturingClient { capturedRequest = $0 }

        try await client.updateEbookProgress(
            for: Self.ebook,
            bookId: 42,
            resourceFileId: 108,
            resourceFormat: "cbz",
            progress: 0.5,
            epubLocator: "cbz-page:4",
            sourceEngine: nil
        )

        let body = try #require(capturedRequest?.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let fileProgress = try #require(root["fileProgress"] as? [String: Any])
        #expect(fileProgress["bookFileId"] as? Int == 108)
        #expect(fileProgress["positionData"] as? String == "5")
        #expect(fileProgress["progressPercent"] as? Double == 50)
    }

    private static let ebook = Book(
        id: "42",
        title: "Ebook Fixture",
        source: .booklore,
        mediaType: .ebook,
        providerId: UUID(),
        libraryId: "tests"
    )

    private static func ebookProgress(_ json: String, usesEpubProgress: Bool) throws -> ProviderEbookProgress? {
        let detail = try JSONDecoder().decode(BookloreLegacyBook.self, from: Data(json.utf8))
        return BookloreProgressClient.ebookProgress(for: ebook, from: detail, usesEpubProgress: usesEpubProgress)
    }

    private static func client(status: Int, body: Data) -> (BookloreProgressClient, () -> [String]) {
        var paths: [String] = []
        let client = BookloreProgressClient(
            makeRequest: { path in
                URLRequest(url: URL(string: "https://example.invalid\(path)")!)
            },
            performAuthorizedRequest: { request in
                paths.append(request.url!.path)
                return (
                    body,
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                )
            }
        )
        return (client, { paths })
    }

    private static func capturingClient(_ capture: @escaping (URLRequest) -> Void) -> BookloreProgressClient {
        BookloreProgressClient(
            makeRequest: { path in
                URLRequest(url: URL(string: "https://example.invalid\(path)")!)
            },
            performAuthorizedRequest: { request in
                capture(request)
                return (
                    Data(),
                    HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
                )
            }
        )
    }

    private static func locations(_ locator: String?) -> [String: Any]? {
        guard let data = locator?.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["locations"] as? [String: Any]
    }
}
