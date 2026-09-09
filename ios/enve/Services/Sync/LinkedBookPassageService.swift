import Foundation

enum LinkedBookPassageError: LocalizedError {
    case downloadRequired
    case noMatch

    var errorDescription: String? {
        switch self {
        case .downloadRequired:
            return "Download the audiobook and linked ebook before finding a passage."
        case .noMatch:
            return "No confident, unique match was found. Your position has not changed. Try a nearby passage with more spoken words."
        }
    }
}

@MainActor
enum LinkedBookPassageService {
    @available(iOS 26.0, *)
    static func find(ebook: Book, audiobook: Book, at position: TimeInterval) async throws -> LinkedBookSparseMatcher.Match {
        guard LocalStorageManager.shared.localAudiobookFilesIfExists(for: audiobook)?.isEmpty == false,
            UnifiedDownloadService.shared.existingReaderAsset(for: ebook) != nil
        else { throw LinkedBookPassageError.downloadRequired }

        try await EbookContextService.shared.prepareContext(for: ebook)
        try Task.checkCancellation()
        guard let context = EbookContextStore.shared.loadContext(bookStableId: ebook.stableId) else {
            throw LinkedBookPassageError.noMatch
        }
        let tracks = try await AudiobookAudioTimelineResolver.shared.localTracks(for: audiobook)
        guard tracks.totalDuration > 0, position.isFinite else { throw LinkedBookPassageError.noMatch }
        let center = min(max(position, 0), tracks.totalDuration)
        let segments = try await AudiobookTranscriptionService.shared.transcribeWindow(
            for: audiobook, startTime: max(0, center - 12), endTime: min(tracks.totalDuration, center + 12)
        )
        try Task.checkCancellation()
        guard let match = LinkedBookSparseMatcher.match(
            transcript: segments.sorted { $0.startTime < $1.startTime }.map(\.text).joined(separator: " "),
            expectedProgress: center / tracks.totalDuration,
            in: LinkedBookTextIndex(chunks: context.chunks),
            requiresUniquePassage: true
        ), match.href?.isEmpty == false else { throw LinkedBookPassageError.noMatch }
        return match
    }

    static func bookForOpening(_ ebook: Book, match: LinkedBookSparseMatcher.Match) throws -> Book {
        let data = try JSONSerialization.data(withJSONObject: [
            "href": match.href ?? "",
            "type": "application/xhtml+xml",
            "locations": ["totalProgression": match.ebookProgress],
            "text": ["highlight": match.quote],
        ])
        var target = ebook
        target.epubLocator = String(decoding: data, as: UTF8.self)
        return target
    }
}
