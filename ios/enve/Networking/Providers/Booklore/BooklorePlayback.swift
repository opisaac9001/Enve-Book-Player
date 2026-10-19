import Foundation

struct BooklorePlaybackMapping {
    let tracks: [AudioTrackInfo]
    let chapters: [Chapter]
    let duration: TimeInterval
    let bookFileId: Int?
}

enum BooklorePlaybackMapper {
    static func map(
        _ info: BookloreAudiobookInfo,
        trackURL: (Int) -> URL?
    ) -> BooklorePlaybackMapping {
        var tracks: [AudioTrackInfo] = []
        var chapters: [Chapter] = []
        let serverDuration = info.duration ?? 0

        if let infoTracks = info.tracks {
            var offset: Double = 0
            for (position, track) in infoTracks.enumerated() {
                let index = track.index ?? position
                let duration = track.duration ?? 0
                let startOffset = track.cumulativeStart ?? offset
                let title = track.title
                    ?? track.fileName.map {
                        URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                    }
                tracks.append(
                    AudioTrackInfo(
                        index: index,
                        startOffset: startOffset,
                        duration: duration,
                        contentUrl: trackURL(index)?.absoluteString ?? "",
                        mimeType: track.mimeType ?? "audio/mp4",
                        title: title
                    )
                )
                offset = max(offset, startOffset + duration)
            }
        }

        if let infoChapters = info.chapters {
            let trackBackedDuration = tracks.reduce(0) { $0 + max($1.duration, 0) }
            let totalDuration = max(serverDuration, trackBackedDuration)
            let shouldMapChaptersToTracks =
                infoChapters.count == tracks.count
                && infoChapters.allSatisfy { chapter in
                    guard let start = chapter.start else { return true }
                    return start <= 0
                }

            for (position, chapter) in infoChapters.enumerated() {
                let fallbackTrack = tracks.indices.contains(position) ? tracks[position] : nil
                let start: Double
                if shouldMapChaptersToTracks, let fallbackTrack {
                    start = fallbackTrack.startOffset
                } else if let explicitStart = chapter.start, explicitStart >= 0 {
                    start = explicitStart
                } else if let fallbackTrack {
                    start = fallbackTrack.startOffset
                } else if let previousChapter = chapters.last {
                    start = previousChapter.end
                } else {
                    start = 0
                }

                let nextExplicitStart = infoChapters.dropFirst(position + 1)
                    .compactMap(\.start)
                    .first(where: { $0 > start })
                let trackEnd = fallbackTrack.map { $0.startOffset + max($0.duration, 0) }
                let fallbackEnd = nextExplicitStart ?? trackEnd ?? totalDuration
                let explicitEnd = chapter.end.flatMap { $0 > start ? $0 : nil }
                chapters.append(
                    Chapter(
                        id: "grimmory_ch_\(position)",
                        start: start,
                        end: max(explicitEnd ?? fallbackEnd, start),
                        title: chapter.title ?? "Chapter \(position + 1)"
                    )
                )
            }

            if totalDuration > 0, !chapters.isEmpty {
                for index in chapters.indices {
                    let nextStart = chapters.indices.contains(index + 1)
                        ? chapters[index + 1].start
                        : totalDuration
                    let normalizedEnd = max(
                        chapters[index].end,
                        nextStart,
                        chapters[index].start
                    )
                    if normalizedEnd != chapters[index].end {
                        chapters[index] = Chapter(
                            id: chapters[index].id,
                            start: chapters[index].start,
                            end: normalizedEnd,
                            title: chapters[index].title,
                            index: chapters[index].index
                        )
                    }
                }
            }
        }

        return BooklorePlaybackMapping(
            tracks: tracks,
            chapters: chapters,
            duration: serverDuration,
            bookFileId: info.bookFileId
        )
    }
}

@MainActor
final class BooklorePlaybackClient {
    typealias RequestBuilder = (String) throws -> URLRequest
    typealias AuthorizedRequest = (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let makeRequest: RequestBuilder
    private let performAuthorizedRequest: AuthorizedRequest

    init(
        makeRequest: @escaping RequestBuilder,
        performAuthorizedRequest: @escaping AuthorizedRequest
    ) {
        self.makeRequest = makeRequest
        self.performAuthorizedRequest = performAuthorizedRequest
    }

    func fetchInfo(bookId: String) async throws -> BookloreAudiobookInfo? {
        let request = try makeRequest("/api/v1/audiobooks/\(bookId)/info")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(BookloreAudiobookInfo.self, from: data)
    }

    func fetchMapping(
        bookId: String,
        trackURL: (Int) -> URL?
    ) async throws -> BooklorePlaybackMapping? {
        guard let info = try await fetchInfo(bookId: bookId) else { return nil }
        return BooklorePlaybackMapper.map(info, trackURL: trackURL)
    }

    func fetchDownloadTracks(
        bookId: String,
        trackURL: (Int) -> URL?
    ) async -> [(url: URL, mimeType: String)]? {
        guard let info = try? await fetchInfo(bookId: bookId),
            let tracks = info.tracks,
            tracks.count > 1
        else {
            return nil
        }

        let resolvedTracks = tracks
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            .compactMap { track -> (url: URL, mimeType: String)? in
                let index = track.index ?? 0
                guard let url = trackURL(index) else { return nil }
                return (url, track.mimeType ?? "audio/mpeg")
            }
        return resolvedTracks.count > 1 ? resolvedTracks : nil
    }
}
