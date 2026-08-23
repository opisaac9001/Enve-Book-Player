import Foundation
import Testing

@testable import enve

@MainActor
struct BooklorePlaybackMapperTests {
    @Test func currentFixtureMapsTracksChaptersAndMilliseconds() throws {
        let info = try JSONDecoder().decode(
            BookloreAudiobookInfo.self,
            from: Data(
                """
                {
                  "bookId": 42,
                  "bookFileId": 77,
                  "durationMs": 300000,
                  "tracks": [
                    {
                      "index": 0,
                      "filename": "Part One.m4b",
                      "durationMs": 100000,
                      "cumulativeStartMs": 0,
                      "contentType": "audio/mp4"
                    },
                    {
                      "trackIndex": 1,
                      "title": "Part Two",
                      "duration": 200,
                      "startOffset": 100,
                      "mimeType": "audio/mpeg"
                    }
                  ],
                  "chapters": [
                    {"title":"One","startTimeMs":0,"endTimeMs":100000},
                    {"title":"Two","startTimeMs":100000,"endTimeMs":300000}
                  ]
                }
                """.utf8
            )
        )

        let mapping = BooklorePlaybackMapper.map(info) { index in
            URL(string: "https://example.invalid/track/\(index)")
        }

        #expect(mapping.duration == 300)
        #expect(mapping.bookFileId == 77)
        #expect(mapping.tracks.count == 2)
        #expect(mapping.tracks[0].title == "Part One")
        #expect(mapping.tracks[0].duration == 100)
        #expect(mapping.tracks[1].startOffset == 100)
        #expect(mapping.tracks[1].contentUrl == "https://example.invalid/track/1")
        #expect(mapping.chapters.map(\.start) == [0, 100])
        #expect(mapping.chapters.map(\.end) == [100, 300])
    }

    @Test func zeroBasedChapterFixtureUsesTrackBoundaries() throws {
        let info = try JSONDecoder().decode(
            BookloreAudiobookInfo.self,
            from: Data(
                """
                {
                  "duration": 120,
                  "tracks": [
                    {"index":0,"duration":60,"cumulativeStart":0},
                    {"index":1,"duration":60,"cumulativeStart":60}
                  ],
                  "chapters": [
                    {"title":"One","start":0},
                    {"title":"Two","start":0}
                  ]
                }
                """.utf8
            )
        )

        let mapping = BooklorePlaybackMapper.map(info) { _ in nil }

        #expect(mapping.chapters.map(\.start) == [0, 60])
        #expect(mapping.chapters.map(\.end) == [60, 120])
        #expect(mapping.chapters.map(\.title) == ["One", "Two"])
    }
}
