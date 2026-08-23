import Foundation
import Testing

@testable import enve

struct BookloreBookMapperTests {
    @Test func currentAudiobookFixtureDecodesMillisecondFields() throws {
        let fixture = Data(
            """
            {
              "tracks": [
                {
                  "trackIndex": 2,
                  "filename": "part-03.m4b",
                  "durationMs": 123450,
                  "contentType": "audio/mp4",
                  "startOffsetMs": 456000
                }
              ],
              "chapters": [
                { "title": "Opening", "startTimeMs": 1500, "endTimeMs": 32000 }
              ]
            }
            """.utf8
        )
        let response = try JSONDecoder().decode(AudiobookFixture.self, from: fixture)

        #expect(response.tracks[0].index == 2)
        #expect(response.tracks[0].fileName == "part-03.m4b")
        #expect(response.tracks[0].duration == 123.45)
        #expect(response.tracks[0].mimeType == "audio/mp4")
        #expect(response.tracks[0].cumulativeStart == 456)
        #expect(response.chapters[0].start == 1.5)
        #expect(response.chapters[0].end == 32)
    }

    @Test func legacyAudiobookFixturePreservesSecondFields() throws {
        let fixture = Data(
            """
            {
              "tracks": [
                {
                  "index": 0,
                  "fileName": "legacy.mp3",
                  "duration": 900,
                  "mimeType": "audio/mpeg",
                  "cumulativeStart": 12
                }
              ],
              "chapters": [
                { "title": "Legacy", "start": 12, "end": 90 }
              ]
            }
            """.utf8
        )
        let response = try JSONDecoder().decode(AudiobookFixture.self, from: fixture)

        #expect(response.tracks[0].duration == 900)
        #expect(response.tracks[0].cumulativeStart == 12)
        #expect(response.chapters[0].start == 12)
        #expect(response.chapters[0].end == 90)
    }

    @Test func chapterMappingSortsAndRepairsMissingEnds() throws {
        let fixture = Data(
            """
            [
              { "title": "Second", "start": 10, "end": 10 },
              { "title": "First", "start": 0, "end": 0 }
            ]
            """.utf8
        )
        let raw = try JSONDecoder().decode([GrimmoryChapter].self, from: fixture)
        let chapters = BookloreBookMapper.chapters(from: raw, bookDuration: 20)

        #expect(chapters.map(\.title) == ["First", "Second"])
        #expect(chapters.map(\.index) == [0, 1])
        #expect(chapters[0].end == 10)
        #expect(chapters[1].end == 20)
    }

    @Test func normalizesFormatsAuthorsAndSeries() {
        #expect(BookloreBookMapper.normalizedFileType("application/epub+zip") == "epub")
        #expect(BookloreBookMapper.mediaType(from: ".m4b") == .audiobook)
        #expect(BookloreBookMapper.libraryType(from: ["EPUB"]) == "ebook")
        #expect(BookloreBookMapper.libraryType(from: ["AUDIOBOOK"]) == "audiobook")
        #expect(BookloreBookMapper.displayAuthor(from: [" Zed ", "amy", "amy"]) == "amy, Zed")
        #expect(BookloreBookMapper.title(fromPrimaryFileName: "  My Book.m4b ") == "My Book")
        #expect(BookloreBookMapper.publishedYear(from: "2024-05-12") == 2024)

        let series = BookloreBookMapper.normalizedSeriesInfo(name: "Saga Vol. 3", sequence: nil)
        #expect(series?.name == "Saga")
        #expect(series?.sequence == "3")
    }

    @Test func fileTypeResolutionSkipsAbsentCandidatesAndKeepsPrecedence() {
        #expect(BookloreBookMapper.resolvedFileType([nil, nil, "EPUB", "pdf"]) == "EPUB")
        #expect(BookloreBookMapper.resolvedFileType([nil, "audio/mp4"]) == "m4a")
        #expect(BookloreBookMapper.resolvedFileType([nil, nil]) == nil)
    }

    private struct AudiobookFixture: Decodable {
        let tracks: [GrimmoryTrack]
        let chapters: [GrimmoryChapter]
    }
}
