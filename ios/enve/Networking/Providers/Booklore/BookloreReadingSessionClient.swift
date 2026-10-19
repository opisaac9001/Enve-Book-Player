import Foundation
import Logging

@MainActor
final class BookloreReadingSessionClient {
    typealias RequestBuilder = (String) throws -> URLRequest
    typealias AuthorizedRequest = (URLRequest) async throws -> (Data, HTTPURLResponse)

    private struct EbookSessionRequest: Encodable {
        let bookId: Int
        let bookType: String
        let startTime: String
        let endTime: String
        let durationSeconds: Int
        let startProgress: Double
        let endProgress: Double
        let progressDelta: Double
        let startLocation: String?
        let endLocation: String?
    }

    private struct AudiobookSessionRequest: Encodable {
        let bookId: Int
        let bookType: String
        let startTime: String
        let endTime: String
        let durationSeconds: Int
        let durationFormatted: String
        let startProgress: Double
        let endProgress: Double
        let progressDelta: Double
        let startLocation: String
        let endLocation: String
    }

    private struct SessionPage: Decodable {
        let content: [GrimmoryReadingSessionEntry]
    }

    private let makeRequest: RequestBuilder
    private let performAuthorizedRequest: AuthorizedRequest
    private let now: () -> Date

    init(
        makeRequest: @escaping RequestBuilder,
        performAuthorizedRequest: @escaping AuthorizedRequest,
        now: @escaping () -> Date = Date.init
    ) {
        self.makeRequest = makeRequest
        self.performAuthorizedRequest = performAuthorizedRequest
        self.now = now
    }

    func uploadEbookSession(
        for book: Book,
        bookId: Int,
        startDate: Date,
        activeSeconds: Int,
        startProgress: Double,
        endProgress: Double,
        locator: String?
    ) async throws {
        let endDate = now()
        let durationSeconds = activeSeconds
        guard durationSeconds >= 5 else { return }

        let startPercent = min(max(startProgress, 0), 1) * 100
        let endPercent = min(max(endProgress, 0), 1) * 100
        let progressDelta = endPercent - startPercent
        let endLocation = Self.locationValue(from: locator)
        let startLocation: Int? = {
            guard let endLocation else { return nil }
            if endPercent > 0 {
                return max(1, Int((Double(endLocation) * (startPercent / endPercent)).rounded()))
            }
            let estimated = endLocation - Int(
                (progressDelta / 100 * Double(max(endLocation, 1))).rounded()
            )
            return max(1, estimated)
        }()
        let body = EbookSessionRequest(
            bookId: bookId,
            bookType: Self.ebookType(for: book),
            startTime: Self.sessionFormatter.string(from: startDate),
            endTime: Self.sessionFormatter.string(from: endDate),
            durationSeconds: durationSeconds,
            startProgress: Self.roundedPercentage(startPercent),
            endProgress: Self.roundedPercentage(endPercent),
            progressDelta: Self.roundedPercentage(progressDelta),
            startLocation: startLocation.map(String.init),
            endLocation: endLocation.map(String.init)
        )

        var request = try makeRequest("/api/v1/reading-sessions")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await performAuthorizedRequest(request)
        let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)
        if (200...202).contains(response.statusCode) {
            AppLogger.network.debug(
                "[Booklore] Uploaded ebook reading session bookDiagnosticID=\(diagnosticID) durationSeconds=\(durationSeconds)"
            )
        } else {
            AppLogger.network.error(
                "[Booklore] Ebook reading session upload failed bookDiagnosticID=\(diagnosticID) status=\(response.statusCode)"
            )
        }
    }

    func uploadAudiobookSession(
        for book: Book,
        bookId: Int,
        currentTime: TimeInterval,
        duration: TimeInterval,
        timeListened: TimeInterval
    ) async throws {
        let listenedSeconds = max(1, Int(timeListened.rounded()))
        let clampedEndTime = min(max(currentTime, 0), duration)
        let startPosition = max(0, clampedEndTime - timeListened)
        let startProgress = Self.percentage(position: startPosition, duration: duration)
        let endProgress = Self.percentage(position: clampedEndTime, duration: duration)
        let endTime = now()
        let startTime = endTime.addingTimeInterval(-Double(listenedSeconds))
        let body = AudiobookSessionRequest(
            bookId: bookId,
            bookType: "AUDIOBOOK",
            startTime: Self.preciseFormatter.string(from: startTime),
            endTime: Self.preciseFormatter.string(from: endTime),
            durationSeconds: listenedSeconds,
            durationFormatted: Self.formattedDuration(listenedSeconds),
            startProgress: startProgress,
            endProgress: endProgress,
            progressDelta: endProgress - startProgress,
            startLocation: String(max(0, Int((startPosition * 1_000).rounded()))),
            endLocation: String(max(0, Int((clampedEndTime * 1_000).rounded())))
        )

        var request = try makeRequest("/api/v1/reading-sessions")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await performAuthorizedRequest(request)
        guard (200...202).contains(response.statusCode) else {
            throw ProviderError.serverError(
                "Failed to sync Booklore reading session (HTTP \(response.statusCode))"
            )
        }
        AppLogger.network.debug(
            "[Booklore] Uploaded audiobook reading session bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) durationSeconds=\(listenedSeconds)"
        )
    }

    func fetchSessions(bookIds: [Int], limit: Int) async -> [GrimmoryReadingSessionEntry] {
        let pageSize = min(max(limit, 1), 100)
        var entries: [GrimmoryReadingSessionEntry] = []

        // A few books at a time; one-by-one requests made the Stats Hub wait on every book in turn.
        for batch in stride(from: 0, to: bookIds.count, by: 6).map({ Array(bookIds[$0..<min($0 + 6, bookIds.count)]) }) {
            await withTaskGroup(of: [GrimmoryReadingSessionEntry].self) { group in
                for bookId in batch {
                    group.addTask { await self.fetchBookSessions(bookId: bookId, pageSize: pageSize) }
                }
                for await page in group {
                    entries.append(contentsOf: page)
                }
            }
        }

        return Array(
            entries.sorted { Self.date(from: $0.startTime) > Self.date(from: $1.startTime) }
                .prefix(limit)
        )
    }

    private func fetchBookSessions(bookId: Int, pageSize: Int) async -> [GrimmoryReadingSessionEntry] {
        guard var request = try? makeRequest("/api/v1/reading-sessions/book/\(bookId)") else { return [] }
        if var components = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "size", value: String(pageSize)),
            ]
            request.url = components.url
        }
        guard let (data, response) = try? await performAuthorizedRequest(request),
            response.statusCode == 200,
            let page = try? JSONDecoder().decode(SessionPage.self, from: data)
        else { return [] }
        return page.content
    }

    // Grimmory rejects any bookType outside its BookFileType enum with a 400.
    private static func ebookType(for book: Book) -> String {
        let fileExtension = (book.ebookFileURL ?? book.filePath.map { URL(fileURLWithPath: $0) })?.pathExtension.lowercased()
        switch fileExtension ?? book.ebookFormat?.lowercased() ?? "" {
        case "pdf": return "PDF"
        case "cbz", "cbr", "cb7", "cbt", "cbx", "zip": return "CBX"
        case "fb2": return "FB2"
        case "mobi": return "MOBI"
        case "azw", "azw3", "kfx": return "AZW3"
        default: return "EPUB"
        }
    }

    private static func locationValue(from locator: String?) -> Int? {
        guard let data = locator?.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let page = json["page"] as? Int {
            return page
        }
        return (json["locations"] as? [String: Any])?["position"] as? Int
    }

    private static func percentage(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return roundedPercentage(min(max(position / duration, 0), 1) * 100)
    }

    private static func roundedPercentage(_ percentage: Double) -> Double {
        (percentage * 10).rounded() / 10
    }

    private static func formattedDuration(_ durationSeconds: Int) -> String {
        let hours = durationSeconds / 3_600
        let minutes = (durationSeconds % 3_600) / 60
        let seconds = durationSeconds % 60
        var parts: [String] = []
        if hours > 0 {
            parts.append("\(hours)h")
        }
        if minutes > 0 || hours > 0 {
            parts.append("\(minutes)m")
        }
        parts.append("\(seconds)s")
        return parts.joined(separator: " ")
    }

    private static func date(from value: String) -> Date {
        ISO8601Timestamp.parse(value) ?? .distantPast
    }

    private static let preciseFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let sessionFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
