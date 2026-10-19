import Foundation
import Logging

extension BookloreProvider {
    nonisolated func grimmoryNumericId(_ book: Book) -> String {
        if book.id.hasPrefix(Self.companionAudiobookIDPrefix) {
            return String(book.id.dropFirst(Self.companionAudiobookIDPrefix.count))
        }
        return book.id
    }

    func resolveGrimmoryBookId(for book: Book) -> Int? {
        if let directId = Int(grimmoryNumericId(book)), directId > 0 {
            return directId
        }

        guard let sourceStableId = book.readAloudSourceStableId,
            let sourceIdPart = sourceStableId.split(separator: ":").last,
            let sourceBookId = Int(sourceIdPart),
            sourceBookId > 0
        else {
            return nil
        }

        AppLogger.network.debug(
            "[Booklore] Resolved Read Aloud source bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
        )
        return sourceBookId
    }

    func updateEbookProgress(for book: Book, progress: Double, epubLocator: String?) async throws {
        try await updateEbookProgress(
            for: book,
            progress: progress,
            epubLocator: epubLocator,
            sourceEngine: nil
        )
    }

    func updateEbookProgress(
        for book: Book,
        progress: Double,
        epubLocator: String?,
        sourceEngine: ReaderEngineKind?
    ) async throws {
        guard !useLegacyRestAPI, !useKomgaFallback else {
            AppLogger.network.debug(
                "[Booklore] Ebook progress push unsupported for active API tier bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
            throw ProviderError.notImplemented
        }

        if book.epub3Features?.hasMediaOverlay == true {
            AppLogger.network.debug(
                "[Booklore] Syncing reading position only for media-overlay bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
        }

        guard let bookId = resolveGrimmoryBookId(for: book) else {
            AppLogger.network.error(
                "[Booklore] Ebook progress push skipped; invalid bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
            throw ProviderError.invalidResponse
        }

        let resource = try await resolveGrimmoryEbookResource(for: book)
        try await progressClient.updateEbookProgress(
            for: book,
            bookId: bookId,
            resourceFileId: resource?.fileId,
            resourceFormat: resource?.format,
            progress: progress,
            epubLocator: epubLocator,
            sourceEngine: sourceEngine
        )
    }

    func uploadEbookReadingSession(
        for book: Book,
        startDate: Date,
        activeSeconds: Int,
        startProgress: Double,
        endProgress: Double,
        epubLocator: String?
    ) async throws {
        guard !useLegacyRestAPI, !useKomgaFallback else { return }
        guard let bookId = resolveGrimmoryBookId(for: book) else { return }
        try await readingSessionClient.uploadEbookSession(
            for: book,
            bookId: bookId,
            startDate: startDate,
            activeSeconds: activeSeconds,
            startProgress: startProgress,
            endProgress: endProgress,
            locator: epubLocator
        )
    }

    enum GrimmoryReadStatus: String {
        case reading = "READING"
        case abandoned = "ABANDONED"
    }

    func updateReadStatus(for book: Book, status: GrimmoryReadStatus) async throws {
        guard !useLegacyRestAPI, !useKomgaFallback else {
            throw ProviderError.notImplemented
        }

        struct StatusRequest: Encodable {
            let status: String
        }

        var request = try makeRequest(path: "/api/v1/app/books/\(grimmoryNumericId(book))/status", method: "PUT")
        request.httpBody = try JSONEncoder().encode(StatusRequest(status: status.rawValue))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await performAuthorizedRequest(request)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to update Grimmory read status (HTTP \(response.statusCode))")
        }

        AppLogger.network.info("Updated read status to \(status.rawValue) for \(book.title)")
    }

    func fetchEbookProgressState(for book: Book) async throws -> ProviderEbookProgress? {
        guard !useLegacyRestAPI, !useKomgaFallback else { return nil }

        guard let bookId = resolveGrimmoryBookId(for: book) else { return nil }
        let detail = try await fetchGrimmorySyncDetail(bookId: bookId)
        let resource = try selectedGrimmoryEbookResource(
            for: book,
            bookId: bookId,
            detail: detail
        )
        if let resource {
            cacheGrimmoryResource(resource, for: book)
        }
        return try await progressClient.fetchEbookProgress(
            for: book,
            bookId: bookId,
            context: BookloreProgressClient.EbookProgressContext(
                usesEpubProgress: resource.flatMap(\.format).map {
                    ![EbookFormat.pdf.rawValue, EbookFormat.cbz.rawValue, EbookFormat.cbr.rawValue,
                      EbookFormat.imagefolder.rawValue].contains($0)
                } ?? false,
                readProgress: detail.readProgress,
                readStatus: detail.readStatus,
                lastReadTime: detail.lastReadTime,
                pdfProgress: detail.pdfProgress.map {
                    BookloreProgressClient.EbookProgressContext.PageProgress(
                        page: $0.page,
                        percentage: $0.percentage,
                        updatedAt: $0.updatedAt
                    )
                },
                cbxProgress: detail.cbxProgress.map {
                    BookloreProgressClient.EbookProgressContext.PageProgress(
                        page: $0.page,
                        percentage: $0.percentage,
                        updatedAt: $0.updatedAt
                    )
                }
            )
        )
    }

    func fetchEbookProgress(for book: Book) async throws -> (progress: Double, locator: String?, updatedAt: Date?, isFinished: Bool)? {
        guard let result = try await fetchEbookProgressState(for: book) else { return nil }
        return (result.progress, result.locator, result.updatedAt, result.readState.isFinished)
    }

    func fetchAudiobookProgressState(for book: Book) async throws -> ProviderAudiobookProgress? {
        guard !useLegacyRestAPI, !useKomgaFallback else { return nil }
        return await progressClient.fetchAudiobookProgress(
            for: book,
            bookId: grimmoryNumericId(book)
        )
    }

    func fetchAudiobookProgress(
        for book: Book
    ) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isFinished: Bool)? {
        guard let result = try await fetchAudiobookProgressState(for: book) else { return nil }
        return (
            result.positionSeconds,
            result.percentage,
            result.trackIndex,
            result.updatedAt,
            result.readState.isFinished
        )
    }
}
