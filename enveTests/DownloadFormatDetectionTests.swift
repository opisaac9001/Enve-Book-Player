import Foundation
import Testing

@testable import enve

@MainActor
struct DownloadFormatDetectionTests {
    @Test func downloadMimeTypesCoverTheLooseArchiveAliases() {
        #expect(EbookFormat.from(downloadMimeType: "application/epub+zip") == .epub)
        #expect(EbookFormat.from(downloadMimeType: "APPLICATION/PDF") == .pdf)
        #expect(EbookFormat.from(downloadMimeType: "application/zip") == .cbz)
        #expect(EbookFormat.from(downloadMimeType: "application/vnd.comicbook+zip") == .cbz)
        #expect(EbookFormat.from(downloadMimeType: "application/vnd.rar") == .cbr)
        #expect(EbookFormat.from(downloadMimeType: "application/fb2+xml") == .fb2)
        #expect(EbookFormat.from(downloadMimeType: "application/octet-stream") == nil)
    }

    @Test func contentTypeWinsOverTheSuggestedFilename() {
        let response = Self.response(
            url: "https://books.example.invalid/api/v1/books/1/download/book.pdf",
            headers: ["Content-Type": "application/epub+zip"]
        )

        #expect(EbookFormat.detectedExtension(inDownloadResponse: response) == "epub")
    }

    @Test func suggestedFilenameResolvesUnknownContentTypes() {
        let response = Self.response(
            url: "https://books.example.invalid/api/v1/books/1/download/book.cbz",
            headers: ["Content-Type": "application/octet-stream"]
        )

        #expect(EbookFormat.detectedExtension(inDownloadResponse: response) == "cbz")
    }

    @Test func contentDispositionIsTheLastResort() {
        let response = Self.response(
            url: "https://books.example.invalid/api/v1/books/1/download",
            headers: [
                "Content-Type": "application/octet-stream",
                "Content-Disposition": "attachment; filename*=UTF-8''Some%20Title.AZW3",
            ]
        )

        #expect(EbookFormat.detectedExtension(inDownloadResponse: response) == "azw3")
    }

    @Test func anUnrecognisableDownloadYieldsNoExtension() {
        let response = Self.response(
            url: "https://books.example.invalid/api/v1/books/1/download",
            headers: ["Content-Type": "application/octet-stream"]
        )

        #expect(EbookFormat.detectedExtension(inDownloadResponse: response) == nil)
    }

    @Test func streamingMimeTypeNormalisesTheExtensionAndFallsBackToMP3() {
        #expect(AudiobookFormat.streamingMimeType(forFileExtension: "mp3") == "audio/mpeg")
        #expect(AudiobookFormat.streamingMimeType(forFileExtension: "m4b") == "audio/mp4")
        #expect(AudiobookFormat.streamingMimeType(forFileExtension: " FLAC ") == "audio/flac")
        #expect(AudiobookFormat.streamingMimeType(forFileExtension: "opus") == "audio/opus")
        #expect(AudiobookFormat.streamingMimeType(forFileExtension: "oga") == "audio/ogg")
        #expect(AudiobookFormat.streamingMimeType(forFileExtension: nil) == "audio/mpeg")
        #expect(AudiobookFormat.streamingMimeType(forFileExtension: "epub") == "audio/mpeg")
    }

    private static func response(url: String, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
