import Foundation
import Logging

@MainActor
final class BookloreProgressClient {
    typealias RequestBuilder = (String) throws -> URLRequest
    typealias AuthorizedRequest = (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias ResponseValidator = (Data, HTTPURLResponse, String) throws -> Void

    struct EbookProgressContext {
        struct PageProgress {
            let page: Int?
            let percentage: Double?
            let updatedAt: String?
        }

        let usesEpubProgress: Bool
        let readProgress: Double?
        let readStatus: String?
        let lastReadTime: String?
        let pdfProgress: PageProgress?
        let cbxProgress: PageProgress?
    }

    private struct AudiobookProgressPayload: Decodable {
        struct Position: Decodable {
            let positionMs: Double?
            let trackIndex: Int?
            let percentage: Double?
            let updatedAt: String?
        }

        let audiobookProgress: Position?
        let readStatus: String?
        let readProgress: Double?
        let lastReadTime: String?
        let duration: Double?
        let durationSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case audiobookProgress
            case readStatus
            case readProgress
            case lastReadTime
            case duration
            case durationMs
            case durationSeconds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            audiobookProgress = try container.decodeIfPresent(Position.self, forKey: .audiobookProgress)
            readStatus = try container.decodeIfPresent(String.self, forKey: .readStatus)
            readProgress = try container.decodeIfPresent(Double.self, forKey: .readProgress)
            lastReadTime = try container.decodeIfPresent(String.self, forKey: .lastReadTime)
            let durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
            let durationValue = try container.decodeIfPresent(Double.self, forKey: .duration)
            duration = durationMs.map { $0 / 1_000 }
                ?? durationValue.map { $0 > 10_000 ? $0 / 1_000 : $0 }
            durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
        }
    }

    private struct AppEbookProgressPayload: Decodable {
        struct EpubPosition: Decodable {
            let percentage: Double?
            let cfi: String?
            let href: String?
            let contentSourceProgressPercent: Double?
            let updatedAt: String?
        }

        struct PagePosition: Decodable {
            let percentage: Double?
            let page: Int?
            let updatedAt: String?
        }

        let readProgress: Double?
        let readStatus: String?
        let lastReadTime: String?
        let epubProgress: EpubPosition?
        let pdfProgress: PagePosition?
        let cbxProgress: PagePosition?
    }

    struct EbookProgressRequest: Encodable {
        struct FileProgress: Encodable {
            let bookFileId: Int
            let positionData: String?
            let positionHref: String?
            let progressPercent: Double
            let ttsPositionCfi: String?
            let contentSourceProgressPercent: Double?
        }

        let fileProgress: FileProgress
    }

    private struct BookDetailEpubProgressPayload: Decodable {
        let epubProgress: AppEbookProgressPayload.EpubPosition?
    }

    private struct AudiobookInfo: Decodable {
        let bookFileId: Int?
    }

    private struct AudiobookProgressRequest: Encodable {
        struct FileProgress: Encodable {
            let bookFileId: Int
            let positionData: String?
            let positionHref: String?
            let progressPercent: Double
        }

        let bookId: Int
        let fileProgress: FileProgress
        let dateFinished: String?
    }

    private let makeRequest: RequestBuilder
    private let performAuthorizedRequest: AuthorizedRequest
    private let validateResponse: ResponseValidator
    private var audiobookFileIds: [String: Int] = [:]

    init(
        makeRequest: @escaping RequestBuilder,
        performAuthorizedRequest: @escaping AuthorizedRequest,
        validateResponse: @escaping ResponseValidator = { _, _, _ in }
    ) {
        self.makeRequest = makeRequest
        self.performAuthorizedRequest = performAuthorizedRequest
        self.validateResponse = validateResponse
    }

    func fetchAudiobookProgress(
        for book: Book,
        bookId: String
    ) async -> ProviderAudiobookProgress? {
        let primaryData: Data
        let primaryResponse: HTTPURLResponse
        do {
            (primaryData, primaryResponse) = try await performAuthorizedRequest(
                try makeRequest("/api/v1/app/books/\(bookId)")
            )
        } catch {
            return nil
        }

        if primaryResponse.statusCode == 200,
            let progress = Self.decodeAudiobookProgress(primaryData, for: book)
        {
            return progress
        }

        guard
            let fallback = try? await performAuthorizedRequest(
                try makeRequest("/api/v1/books/\(bookId)")
            ),
            fallback.1.statusCode == 200
        else {
            return nil
        }
        return Self.decodeAudiobookProgress(fallback.0, for: book)
    }

    func fetchEbookProgress(
        for book: Book,
        bookId: Int,
        context: EbookProgressContext
    ) async throws -> ProviderEbookProgress? {
        let (data, response) = try await performAuthorizedRequest(
            try makeRequest("/api/v1/app/books/\(bookId)/progress")
        )
        let appProgress: AppEbookProgressPayload?
        switch response.statusCode {
        case 200:
            try validateResponse(data, response, "/api/v1/app/books/{bookId}/progress")
            appProgress = try JSONDecoder().decode(AppEbookProgressPayload.self, from: data)
        case 404:
            appProgress = nil
        case 401, 403:
            throw ProviderError.unauthorized
        default:
            throw ProviderError.serverError(
                "Failed to fetch Booklore app progress (HTTP \(response.statusCode))"
            )
        }

        let epubProgress = context.usesEpubProgress ? appProgress?.epubProgress : nil
        let appCFI = EpubLocationBridge.canonicalFullEPUBCFI(epubProgress?.cfi)
        let readiumLocator: String? = {
            guard appCFI == nil,
                let value = epubProgress?.cfi,
                let data = value.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["locations"] is [String: Any]
            else { return nil }
            return value
        }()
        let filePosition: AppEbookProgressPayload.EpubPosition? =
            if let epubProgress, appCFI == nil, readiumLocator == nil {
                await fetchLatestFileEpubPosition(bookId: bookId, appHref: epubProgress.href)
            } else {
                nil
            }
        let exactCFI = appCFI ?? EpubLocationBridge.canonicalFullEPUBCFI(filePosition?.cfi)
        let positionHref = filePosition?.href ?? epubProgress?.href
        let readState = ProviderReadState(
            serverValue: appProgress?.readStatus ?? context.readStatus
        )
        let fraction =
            BookloreBookMapper.fraction(
                fromPercent: epubProgress?.percentage
                    ?? appProgress?.pdfProgress?.percentage
                    ?? appProgress?.cbxProgress?.percentage
            )
            ?? BookloreBookMapper.fraction(fromReadProgress: appProgress?.readProgress ?? context.readProgress)
            ?? BookloreBookMapper.fraction(fromPercent: context.pdfProgress?.percentage ?? context.cbxProgress?.percentage)
            ?? (readState.isFinished ? book.canonicalEbookProgress : 0)

        let locator: String? = {
            if let readiumLocator {
                return readiumLocator
            }
            if let exactCFI {
                return EpubLocationBridge.readiumLocator(
                    href: positionHref,
                    epubCFI: exactCFI,
                    fraction: fraction,
                    sourceEngine: .foliate
                )
            }
            if let positionHref,
                let chapterProgress = BookloreBookMapper.fraction(fromPercent: filePosition?.contentSourceProgressPercent)
            {
                return EpubLocationBridge.readiumLocator(
                    href: positionHref,
                    fraction: fraction,
                    resourceProgression: chapterProgress
                )
            }
            if context.usesEpubProgress {
                return nil
            }
            if let page = appProgress?.pdfProgress?.page ?? context.pdfProgress?.page {
                return "{\"page\":\(max(page - 1, 0))}"
            }
            if let page = appProgress?.cbxProgress?.page ?? context.cbxProgress?.page {
                return "cbz-page:\(max(page - 1, 0))"
            }
            return nil
        }()

        guard
            fraction > 0
                || locator != nil
                || readState.isFinished
                || readState.isAbandoned
                || readState == .notReading
        else {
            return nil
        }

        if exactCFI != nil {
            AppLogger.network.debug(
                "[Booklore] Received exact EPUB position bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
        }
        return ProviderEbookProgress(
            progress: fraction,
            locator: locator,
            updatedAt: Self.parseTimestamp(
                epubProgress?.updatedAt
                    ?? appProgress?.pdfProgress?.updatedAt
                    ?? appProgress?.cbxProgress?.updatedAt
                    ?? appProgress?.lastReadTime
                    ?? context.lastReadTime
                    ?? context.pdfProgress?.updatedAt
                    ?? context.cbxProgress?.updatedAt
            ),
            readState: readState
        )
    }

    // The app endpoint reports book-level progress only; chapter progress from Kobo and other file-level writers is on the book detail.
    private func fetchLatestFileEpubPosition(
        bookId: Int,
        appHref: String?
    ) async -> AppEbookProgressPayload.EpubPosition? {
        guard let request = try? makeRequest("/api/v1/books/\(bookId)"),
            let (data, response) = try? await performAuthorizedRequest(request),
            response.statusCode == 200,
            let detail = try? JSONDecoder().decode(BookDetailEpubProgressPayload.self, from: data).epubProgress,
            let href = detail.href, !href.isEmpty
        else { return nil }
        if let appHref, !appHref.isEmpty,
            EpubLocationBridge.normalizedHref(appHref) != EpubLocationBridge.normalizedHref(href)
        {
            return nil
        }
        guard EpubLocationBridge.canonicalFullEPUBCFI(detail.cfi) != nil
            || detail.contentSourceProgressPercent != nil
        else { return nil }
        return detail
    }

    func cacheAudiobookFileId(_ fileId: Int, for bookId: String) {
        guard fileId > 0 else { return }
        audiobookFileIds[bookId] = fileId
    }

    func cachedAudiobookFileId(for bookId: String) -> Int? {
        audiobookFileIds[bookId]
    }

    func updateEbookProgress(
        for book: Book,
        bookId: Int,
        resourceFileId: Int?,
        resourceFormat: String?,
        progress: Double,
        epubLocator: String?,
        sourceEngine: ReaderEngineKind?
    ) async throws {
        guard let resourceFileId else {
            throw ProviderError.serverError("No matching ebook file is available for this Grimmory book")
        }
        let progressPercent = min(max(progress, 0), 1) * 100
        let provenanceLocator = sourceEngine.flatMap {
            EpubLocationBridge.markingSourceEngine($0, in: epubLocator)
        } ?? epubLocator
        let location = EpubLocationBridge.extractGrimmoryLocation(from: provenanceLocator)
        let format = BookloreBookMapper.normalizedEbookFormat(resourceFormat ?? book.ebookFormat)
        let fullCFI: String? = {
            if let format,
                [EbookFormat.pdf.rawValue, EbookFormat.cbz.rawValue, EbookFormat.cbr.rawValue, EbookFormat.imagefolder.rawValue]
                    .contains(format)
            {
                return nil
            }
            if sourceEngine == .foliate {
                return EpubLocationBridge.canonicalFullEPUBCFI(
                    EpubLocationBridge.epubCFI(from: epubLocator)
                )
            }
            return EpubLocationBridge.canonicalFullEPUBCFI(location.epubCFI)
        }()
        let pagePosition: String? = {
            switch format {
            case EbookFormat.pdf.rawValue:
                return Self.pdfPageIndex(from: epubLocator).map { String($0 + 1) }
            case EbookFormat.cbz.rawValue, EbookFormat.cbr.rawValue, EbookFormat.imagefolder.rawValue:
                return Self.comicPageIndex(from: epubLocator).map { String($0 + 1) }
            default:
                return nil
            }
        }()
        let resourcePercentage = Self.resourcePercentage(from: provenanceLocator)
        let locatorPositionData = pagePosition ?? fullCFI ?? (format == EbookFormat.epub.rawValue ? provenanceLocator : nil)
        var request = try makeRequest("/api/v1/app/books/\(bookId)/progress")
        request.httpMethod = "PUT"
        request.httpBody = try JSONEncoder().encode(
            EbookProgressRequest(
                fileProgress: .init(
                    bookFileId: resourceFileId,
                    positionData: locatorPositionData,
                    positionHref: locatorPositionData == nil ? nil : location.href,
                    progressPercent: progressPercent,
                    ttsPositionCfi: nil,
                    contentSourceProgressPercent: locatorPositionData == nil ? nil : resourcePercentage
                )
            )
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await performAuthorizedRequest(request)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError(
                "Failed to sync Booklore ebook position (HTTP \(response.statusCode))"
            )
        }
        AppLogger.network.debug(
            "[Booklore] Pushed ebook position bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) percentage=\(progressPercent)"
        )
    }

    func updateAudiobookProgress(
        for book: Book,
        bookId: String,
        sessionId: String?,
        currentTime: TimeInterval,
        duration: TimeInterval,
        isFinished: Bool
    ) async throws -> Double {
        let fraction = min(max(currentTime / duration, 0), 1)
        let progressPercent = fraction * 100
        guard let fileId = await resolveAudiobookFileId(
            for: book,
            bookId: bookId,
            sessionId: sessionId
        ) else {
            AppLogger.network.warning(
                "[Booklore] Audiobook position push skipped; missing file ID bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
            return fraction
        }

        let positionData: String?
        let positionHref: String?
        if book.isMultiFile, let localPosition = book.localPosition(for: currentTime) {
            positionData = String(Int((localPosition.localOffset * 1_000).rounded()))
            positionHref = String(localPosition.trackIndex)
        } else {
            positionData = String(Int((currentTime * 1_000).rounded()))
            positionHref = nil
        }

        let body = AudiobookProgressRequest(
            bookId: Int(bookId) ?? 0,
            fileProgress: AudiobookProgressRequest.FileProgress(
                bookFileId: fileId,
                positionData: positionData,
                positionHref: positionHref,
                progressPercent: progressPercent
            ),
            dateFinished: isFinished ? ISO8601DateFormatter().string(from: Date()) : nil
        )
        var request = try makeRequest("/api/v1/books/progress")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await performAuthorizedRequest(request)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError(
                "Failed to sync Booklore progress (HTTP \(response.statusCode))"
            )
        }
        AppLogger.network.debug(
            "[Booklore] Pushed audiobook progress bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) percentage=\(progressPercent)"
        )
        return fraction
    }

    static func audiobookFileId(from sessionId: String?) -> Int? {
        guard let sessionId, sessionId.hasPrefix("grimmory_") else { return nil }
        let parts = sessionId.split(separator: "_")
        guard parts.count >= 3, let fileId = Int(parts[2]), fileId > 0 else { return nil }
        return fileId
    }

    private static func resourcePercentage(from locator: String?) -> Double? {
        guard let data = locator?.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let locations = object["locations"] as? [String: Any],
            let progression = (locations["progression"] as? NSNumber)?.doubleValue
        else {
            return nil
        }
        return min(max(progression, 0), 1) * 100
    }

    private static func comicPageIndex(from locator: String?) -> Int? {
        guard let locator, locator.hasPrefix("cbz-page:") else { return nil }
        return Int(locator.dropFirst("cbz-page:".count))
    }

    private static func pdfPageIndex(from locator: String?) -> Int? {
        guard let locator, !locator.isEmpty else { return nil }
        if locator.hasPrefix("pdf-page:") {
            return Int(locator.dropFirst("pdf-page:".count))
        }
        guard let data = locator.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["page"] as? Int
    }

    static func decodeAudiobookProgress(
        _ data: Data,
        for book: Book
    ) -> ProviderAudiobookProgress? {
        guard let payload = try? JSONDecoder().decode(AudiobookProgressPayload.self, from: data) else {
            return nil
        }

        let progress = payload.audiobookProgress
        let readState = ProviderReadState(serverValue: payload.readStatus)
        let fraction =
            BookloreBookMapper.fraction(fromPercent: progress?.percentage)
            ?? BookloreBookMapper.fraction(fromReadProgress: payload.readProgress)
            ?? (readState.isFinished ? 1 : 0)
        guard fraction > 0 || readState.isFinished || readState.isAbandoned || readState == .notReading else {
            return nil
        }

        let trackIndex = progress?.trackIndex
        let positionMilliseconds = progress?.positionMs ?? 0
        let serverDuration = payload.durationSeconds.map(Double.init) ?? payload.duration
        let positionSeconds: TimeInterval
        if let trackIndex, trackIndex > 0 {
            if let chapters = book.chapters, trackIndex < chapters.count {
                positionSeconds = chapters[trackIndex].start + positionMilliseconds / 1_000
            } else if let duration = book.duration, duration > 0 {
                positionSeconds = fraction * duration
            } else if let serverDuration, serverDuration > 0 {
                positionSeconds = fraction * serverDuration
            } else {
                positionSeconds = 0
            }
        } else if positionMilliseconds > 0 {
            positionSeconds = positionMilliseconds / 1_000
        } else if let serverDuration, serverDuration > 0 {
            positionSeconds = fraction * serverDuration
        } else if let duration = book.duration, duration > 0 {
            positionSeconds = fraction * duration
        } else {
            positionSeconds = 0
        }

        AppLogger.network.debug(
            "[Booklore] Received audiobook progress bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) fraction=\(fraction) positionSeconds=\(positionSeconds)"
        )
        return ProviderAudiobookProgress(
            positionSeconds: positionSeconds,
            percentage: fraction,
            trackIndex: trackIndex,
            updatedAt: parseTimestamp(payload.lastReadTime ?? progress?.updatedAt),
            readState: readState
        )
    }

    static func parseTimestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = ISO8601Timestamp.parse(value) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }

        if let epoch = Double(value) {
            return Date(timeIntervalSince1970: epoch > 1_000_000_000_000 ? epoch / 1_000 : epoch)
        }
        return nil
    }

    private func resolveAudiobookFileId(
        for book: Book,
        bookId: String,
        sessionId: String?
    ) async -> Int? {
        if let fileId = Self.audiobookFileId(from: sessionId) {
            cacheAudiobookFileId(fileId, for: book.id)
            return fileId
        }
        if let fileId = audiobookFileIds[book.id], fileId > 0 {
            return fileId
        }

        guard let result = try? await performAuthorizedRequest(
            try makeRequest("/api/v1/audiobooks/\(bookId)/info")
        ),
            result.1.statusCode == 200,
            let info = try? JSONDecoder().decode(AudiobookInfo.self, from: result.0),
            let fileId = info.bookFileId,
            fileId > 0
        else {
            return nil
        }
        cacheAudiobookFileId(fileId, for: book.id)
        return fileId
    }
}
