import Foundation
import Logging

final class EbookChapterSyncService: @unchecked Sendable {
    static let shared = EbookChapterSyncService()

    private init() {}

    func resolvedFileURL(for ebook: Book) -> URL? {
        guard ebook.mediaType == .ebook else { return nil }

        return LocalEbookImporter.shared.resolveExistingLocalEbookURL(
            bookIdentifier: ebook.id,
            ebookFileURL: ebook.ebookFileURL,
            filePath: ebook.filePath
        )
    }

    func extractEbookChapters(for ebook: Book) async -> [Chapter]? {
        guard let fileURL = resolvedFileURL(for: ebook) else { return nil }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let localChapters = try await LocalEbookImporter.shared.extractChapters(from: fileURL)
            guard !localChapters.isEmpty else { return nil }

            return localChapters.enumerated().map { index, chapter in
                Chapter(
                    id: chapter.id,
                    start: chapter.startTime,
                    end: chapter.endTime,
                    title: chapter.title,
                    index: index
                )
            }
        } catch {
            AppLogger.sync.error(
                "Failed to extract ebook chapters for bookId=\(DiagnosticLogSanitizer.identifier(for: ebook.stableId)): \(error)"
            )
            return nil
        }
    }

    func matchedChapterCount(ebookCount: Int, audiobookCount: Int, offset: Int = 0) -> Int {
        let ebookStartIndex = max(0, -offset)
        let audiobookStartIndex = max(0, offset)

        guard ebookCount > ebookStartIndex, audiobookCount > audiobookStartIndex else {
            return 0
        }

        return min(ebookCount - ebookStartIndex, audiobookCount - audiobookStartIndex)
    }

    func recommendedOffset(
        ebookChapters: [Chapter],
        audiobookChapters: [Chapter]?
    ) -> Int? {
        guard let audiobookChapters else { return nil }
        return LinkedBookChapterMapper.recommendedOffset(
            ebookTitles: ebookChapters.map(\.title),
            audiobookTitles: audiobookChapters.map(\.title)
        )
    }

    func syncChaptersIfPossible(ebookChapters: [Chapter], audiobookChapters: [Chapter]?, offset: Int = 0) -> [Chapter]? {
        guard let audiobookChapters, !ebookChapters.isEmpty, !audiobookChapters.isEmpty else {
            return nil
        }

        let ebookStartIndex = max(0, -offset)
        let audiobookStartIndex = max(0, offset)
        let matchCount = matchedChapterCount(
            ebookCount: ebookChapters.count,
            audiobookCount: audiobookChapters.count,
            offset: offset
        )

        guard matchCount > 0 else { return nil }

        var result = ebookChapters.enumerated().map { index, chapter in
            Chapter(
                id: chapter.id,
                start: chapter.start,
                end: chapter.end,
                title: chapter.title,
                index: index
            )
        }

        for relativeIndex in 0..<matchCount {
            let ebookIndex = ebookStartIndex + relativeIndex
            let audiobookIndex = audiobookStartIndex + relativeIndex
            let ebookChapter = ebookChapters[ebookIndex]
            let audiobookChapter = audiobookChapters[audiobookIndex]
            let trimmedTitle = ebookChapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmedTitle.isEmpty ? audiobookChapter.title : trimmedTitle

            result[ebookIndex] = Chapter(
                id: ebookChapter.id,
                start: audiobookChapter.start,
                end: audiobookChapter.end,
                title: title,
                index: ebookIndex
            )
        }

        return result
    }
}
