import Foundation
import Logging

enum ChapterMetadataCache {
    static func cache(_ book: Book) async {
        guard let chapters = book.chapters, !chapters.isEmpty else { return }

        ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.stableId, chapters: chapters)
        if book.id != book.stableId {
            ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.id, chapters: chapters)
        }

        do {
            try await MetadataStorage.shared.updateLayer(bookId: book.id, layer: .appCache) { metadata in
                var backend =
                    metadata.backend
                    ?? BackendMetadataLayer(
                        title: book.title,
                        author: book.author,
                        narrator: book.narrator,
                        series: book.series,
                        seriesNumber: book.seriesNumber,
                        year: book.publishedYear,
                        publisher: book.publisher,
                        genres: book.genres,
                        description: book.description,
                        duration: book.duration,
                        isbn: book.isbn,
                        asin: book.asin,
                        fileName: nil,
                        folderName: nil,
                        thumb: book.thumb
                    )
                backend.chapters = chapters
                metadata.backend = backend
            }
        } catch {
            AppLogger.general.error(
                "Failed to cache chapters bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error)"
            )
        }
    }
}
