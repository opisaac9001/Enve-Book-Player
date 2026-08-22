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
        #expect(progress?.updatedAt == BookloreProgressClient.parseTimestamp("2026-08-21T12:30:45.123Z"))
    }

    @Test func legacyFallbackFixtureUsesServerDuration() async {
        let fixture = Data(
            """
            {
              "readStatus": "READING",
              "readProgress": 50,
              "durationMs": 200000,
              "audiobookProgress": {
                "trackIndex": 2,
                "percentage": 50
              }
            }
            """.utf8
        )
        var requestedPaths: [String] = []
        let client = BookloreProgressClient(
            makeRequest: { path in
                URLRequest(url: URL(string: "https://example.invalid\(path)")!)
            },
            performAuthorizedRequest: { request in
                let path = request.url!.path
                requestedPaths.append(path)
                let statusCode = path.contains("/app/") ? 500 : 200
                let data = statusCode == 200 ? fixture : Data()
                return (
                    data,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: statusCode,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )
        let book = Book(
            id: "42",
            title: "Legacy Fixture",
            source: .booklore,
            providerId: UUID(),
            libraryId: "tests"
        )

        let progress = await client.fetchAudiobookProgress(for: book, bookId: "42")

        #expect(requestedPaths == ["/api/v1/app/books/42", "/api/v1/books/42"])
        #expect(progress?.positionSeconds == 100)
        #expect(progress?.percentage == 0.5)
        #expect(progress?.trackIndex == 2)
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

    @Test func appEbookFixtureMapsExactCFI() async throws {
        let fixture = Data(
            """
            {
              "readProgress": 35,
              "readStatus": "READING",
              "lastReadTime": "2026-08-21T12:00:00Z",
              "epubProgress": {
                "percentage": 40,
                "cfi": "epubcfi(/6/2[chapter]!/4/2/2:0)",
                "href": "chapter.xhtml",
                "updatedAt": "2026-08-21T12:30:00Z"
              }
            }
            """.utf8
        )
        let client = BookloreProgressClient(
            makeRequest: { path in
                URLRequest(url: URL(string: "https://example.invalid\(path)")!)
            },
            performAuthorizedRequest: { request in
                (
                    fixture,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                )
            }
        )
        let book = Book(
            id: "42",
            title: "EPUB Fixture",
            source: .booklore,
            mediaType: .ebook,
            providerId: UUID(),
            libraryId: "tests"
        )
        let context = BookloreProgressClient.EbookProgressContext(
            hasEpubResource: true,
            readProgress: nil,
            readStatus: nil,
            lastReadTime: nil,
            pdfProgress: nil,
            cbxProgress: nil
        )

        let progress = try await client.fetchEbookProgress(
            for: book,
            bookId: 42,
            context: context
        )

        #expect(progress?.progress == 0.4)
        #expect(progress?.readState == .reading)
        #expect(EpubLocationBridge.epubCFI(from: progress?.locator) == "epubcfi(/6/2[chapter]!/4/2/2:0)")
        #expect(progress?.updatedAt == BookloreProgressClient.parseTimestamp("2026-08-21T12:30:00Z"))
    }

    @Test func missingAppProgressFallsBackToPDFContext() async throws {
        let client = BookloreProgressClient(
            makeRequest: { path in
                URLRequest(url: URL(string: "https://example.invalid\(path)")!)
            },
            performAuthorizedRequest: { request in
                (
                    Data(),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )
        let book = Book(
            id: "42",
            title: "PDF Fixture",
            source: .booklore,
            mediaType: .ebook,
            providerId: UUID(),
            libraryId: "tests"
        )
        let context = BookloreProgressClient.EbookProgressContext(
            hasEpubResource: false,
            readProgress: nil,
            readStatus: "READING",
            lastReadTime: nil,
            pdfProgress: .init(
                page: 7,
                percentage: 30,
                updatedAt: "2026-08-21 12:30:00"
            ),
            cbxProgress: nil
        )

        let progress = try await client.fetchEbookProgress(
            for: book,
            bookId: 42,
            context: context
        )

        #expect(progress?.progress == 0.3)
        #expect(progress?.locator == "{\"page\":7}")
        #expect(progress?.updatedAt == BookloreProgressClient.parseTimestamp("2026-08-21 12:30:00"))
    }

    @Test func updateEbookProgressUsesAppCFIContractForEPUBResource() async throws {
        var capturedRequest: URLRequest?
        let client = BookloreProgressClient(
            makeRequest: { path in
                URLRequest(url: URL(string: "https://example.invalid\(path)")!)
            },
            performAuthorizedRequest: { request in
                capturedRequest = request
                return (
                    Data(),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 204,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )
        let book = Book(
            id: "42",
            title: "EPUB Push Fixture",
            source: .booklore,
            mediaType: .ebook,
            providerId: UUID(),
            libraryId: "tests"
        )
        let locator = EpubLocationBridge.readiumLocator(
            href: "chapter.xhtml",
            epubCFI: "epubcfi(/6/2[chapter]!/4/2/2:0)",
            fraction: 0.4,
            resourceProgression: 0.4,
            sourceEngine: .foliate
        )

        try await client.updateEbookProgress(
            for: book,
            bookId: 42,
            resourceFileId: 107,
            progress: 0.4,
            epubLocator: locator,
            sourceEngine: .foliate
        )

        let request = try #require(capturedRequest)
        #expect(request.url?.path == "/api/v1/app/books/42/progress")
        #expect(request.httpMethod == "PUT")
        let body = try #require(request.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let fileProgress = try #require(root["fileProgress"] as? [String: Any])
        #expect(fileProgress["bookFileId"] as? Int == 107)
        #expect(fileProgress["positionData"] as? String == "epubcfi(/6/2[chapter]!/4/2/2:0)")
        #expect(fileProgress["positionHref"] as? String == "chapter.xhtml")
        #expect(fileProgress["progressPercent"] as? Double == 40)
        #expect(fileProgress["contentSourceProgressPercent"] as? Double == 40)
    }

    @Test func updateEbookProgressUsesLegacyProgressContractWithoutResource() async throws {
        var capturedRequest: URLRequest?
        let client = BookloreProgressClient(
            makeRequest: { path in
                URLRequest(url: URL(string: "https://example.invalid\(path)")!)
            },
            performAuthorizedRequest: { request in
                capturedRequest = request
                return (
                    Data(),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
        )
        let book = Book(
            id: "42",
            title: "PDF Push Fixture",
            source: .booklore,
            mediaType: .ebook,
            providerId: UUID(),
            libraryId: "tests"
        )

        try await client.updateEbookProgress(
            for: book,
            bookId: 42,
            resourceFileId: nil,
            progress: 0.3,
            epubLocator: "{\"page\":7}",
            sourceEngine: nil
        )

        let request = try #require(capturedRequest)
        #expect(request.url?.path == "/api/v1/books/progress")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let fileProgress = try #require(root["fileProgress"] as? [String: Any])
        #expect(root["bookId"] as? Int == 42)
        #expect(fileProgress["bookFileId"] as? Int == 42)
        #expect(fileProgress["progressPercent"] as? Double == 30)
    }
}
