import AVFoundation
import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif

struct PlexProgressTarget: Equatable {
    let ratingKey: String
    let time: TimeInterval
    let duration: TimeInterval
}

func resolvePlexProgressTarget(book: Book, currentTime: TimeInterval) -> PlexProgressTarget {
    let globalTime = max(0, currentTime)
    let orderedTracks = (book.audioTracks ?? []).sorted {
        if $0.startOffset == $1.startOffset { return $0.index < $1.index }
        return $0.startOffset < $1.startOffset
    }

    if let track = orderedTracks.last(where: { globalTime >= $0.startOffset }) ?? orderedTracks.first {
        let localTime = min(max(0, globalTime - track.startOffset), max(0, track.duration))
        return PlexProgressTarget(
            ratingKey: track.id,
            time: localTime,
            duration: track.duration
        )
    }

    return PlexProgressTarget(
        ratingKey: book.id,
        time: globalTime,
        duration: book.duration ?? 0
    )
}

class PlexProvider: IncrementalCatalogProvider, PlaybackSessionProvider, AudiobookProgressPushing,
    @unchecked Sendable
{
    var connection: ServerConnection

    var capabilities: ProviderCapabilities {
        [
            .fullImport, .pagedImport,
            .recentBooks,
            .audiobookProgressPush,
            .downloads, .coverAuthQuery, .backgroundOperation,
        ]
    }

    init(connection: ServerConnection) {
        self.connection = connection
    }

    private static let maxTracksForMultiFileBook: Int = 200

    private static let minTracksForMultiFileBook: Int = 3

    private struct PlexTrackTimeline {
        let audioTracks: [AudioTrack]
        let chapters: [Chapter]
        let duration: TimeInterval
        let partKey: String?
    }

    private func durationMilliseconds(from metadata: PlexMetadata) -> Double {
        if let duration = metadata.duration { return duration }
        if let mediaDuration = metadata.media?.first?.duration { return mediaDuration }
        if let partDuration = metadata.media?.first?.part?.first?.duration { return partDuration }
        return 0
    }

    private func durationSeconds(from metadata: PlexMetadata) -> Double {
        let raw = durationMilliseconds(from: metadata)
        if raw <= 0 { return 0 }
        return raw / 1000.0
    }

    private func orderedTracks(_ tracks: [PlexMetadata]) -> [PlexMetadata] {
        tracks.sorted { lhs, rhs in
            let lhsDisc = lhs.parentIndex ?? 0
            let rhsDisc = rhs.parentIndex ?? 0
            if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }

            let lhsTrack = lhs.index ?? Int.max
            let rhsTrack = rhs.index ?? Int.max
            if lhsTrack != rhsTrack { return lhsTrack < rhsTrack }

            return lhs.ratingKey < rhs.ratingKey
        }
    }

    private func mimeType(from track: PlexMetadata) -> String {
        let format = track.media?.first?.container
            ?? track.media?.first?.audioCodec
            ?? track.media?.first?.part?.first?.container
            ?? track.media?.first?.part?.first?.file.map { URL(fileURLWithPath: $0).pathExtension }
            ?? ""

        switch format.lowercased() {
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "m4a", "m4b", "mp4": return "audio/mp4"
        case "ogg", "oga", "vorbis": return "audio/ogg"
        case "flac": return "audio/flac"
        case "wav", "wave": return "audio/wav"
        default: return "application/octet-stream"
        }
    }

    private func trackTimeline(from tracks: [PlexMetadata]) -> PlexTrackTimeline {
        let sorted = orderedTracks(tracks)
        var audioTracks: [AudioTrack] = []
        var chapters: [Chapter] = []
        var offset: TimeInterval = 0

        for (index, track) in sorted.enumerated() {
            let duration = durationSeconds(from: track)
            audioTracks.append(
                AudioTrack(
                    id: track.ratingKey,
                    index: index,
                    title: track.title,
                    contentUrl: track.media?.first?.part?.first?.key,
                    duration: duration,
                    startOffset: offset,
                    format: mimeType(from: track)
                )
            )
            chapters.append(
                Chapter(
                    id: track.ratingKey,
                    start: offset,
                    end: offset + duration,
                    title: track.title,
                    index: index
                )
            )
            offset += duration
        }

        return PlexTrackTimeline(
            audioTracks: audioTracks,
            chapters: normalizeChapters(chapters, bookDuration: offset),
            duration: offset,
            partKey: sorted.first?.media?.first?.part?.first?.key
        )
    }

    private func extractNarrator(from metadata: PlexMetadata, author: String?) -> String? {
        let authorLower = author?.lowercased() ?? ""
        let titleLower = metadata.title.lowercased()
        let candidates = [metadata.originalTitle].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }

        for candidate in candidates {
            let lower = candidate.lowercased()
            if candidate.isEmpty { continue }
            if !authorLower.isEmpty && lower == authorLower { continue }
            if lower == titleLower { continue }
            return candidate
        }

        if let summary = metadata.summary {
            let pattern = #"(?i)narrated\s+by\s+([^\n.,;]+)"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                let match = regex.firstMatch(in: summary, options: [], range: NSRange(summary.startIndex..., in: summary)),
                match.numberOfRanges >= 2,
                let range = Range(match.range(at: 1), in: summary)
            {
                let narrator = summary[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if !narrator.isEmpty {
                    return narrator
                }
            }
        }

        return nil
    }

    private func extractSeriesInfo(from metadata: PlexMetadata, author: String?) -> SeriesInfo? {
        if let fromTitle = parseSeriesFromTitle(metadata.title) {
            return fromTitle
        }
        if let filePath = metadata.media?.first?.part?.first?.file {
            if let fromPath = parseSeriesFromPath(filePath, author: author, title: metadata.title) {
                return fromPath
            }
        }
        return nil
    }

    private func parseSeriesFromTitle(_ title: String) -> SeriesInfo? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let patterns: [String] = [
            #"^(.*?)(?:\s*[-\x{2013}\x{2014}:,]\s*|\s+)(?:book|bk|vol(?:ume)?|part|#)\s*([0-9]+(?:\.[0-9]+)?)\s*$"#,
            #"^(.*?)(?:\s*\((?:book|vol(?:ume)?|part|#)\s*([0-9]+(?:\.[0-9]+)?)\))\s*$"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if let match = regex.firstMatch(in: trimmed, options: [], range: range),
                    match.numberOfRanges >= 3,
                    let nameRange = Range(match.range(at: 1), in: trimmed),
                    let seqRange = Range(match.range(at: 2), in: trimmed)
                {
                    let name = String(trimmed[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let sequence = String(trimmed[seqRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, !sequence.isEmpty {
                        return SeriesInfo(name: name, sequence: sequence)
                    }
                }
            }
        }

        return nil
    }

    private func parseSeriesFromPath(_ filePath: String, author: String?, title: String) -> SeriesInfo? {
        let url = URL(fileURLWithPath: filePath)
        let bookFolder = url.deletingLastPathComponent().lastPathComponent
        let seriesCandidate = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent

        let authorLower = author?.lowercased() ?? ""
        let titleLower = title.lowercased()

        func isUsableSeriesName(_ name: String) -> Bool {
            let lower = name.lowercased()
            if name.isEmpty { return false }
            if !authorLower.isEmpty && lower == authorLower { return false }
            if lower == titleLower { return false }
            if lower == bookFolder.lowercased() { return false }
            return true
        }

        let seriesName: String?
        if isUsableSeriesName(seriesCandidate) {
            seriesName = seriesCandidate
        } else if isUsableSeriesName(bookFolder) {
            seriesName = bookFolder
        } else {
            seriesName = nil
        }

        guard let name = seriesName else { return nil }

        let sequence = extractSequence(from: title) ?? extractSequence(from: bookFolder)
        return SeriesInfo(name: name, sequence: sequence)
    }

    private func extractSequence(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns: [String] = [
            #"(?:book|bk|vol(?:ume)?|part|#)\s*([0-9]+(?:\.[0-9]+)?)"#,
            #"^(\d{1,3}(?:\.\d+)?)\s*[-\x{2013}\x{2014}:.]"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if let match = regex.firstMatch(in: trimmed, options: [], range: range),
                    match.numberOfRanges >= 2,
                    let seqRange = Range(match.range(at: 1), in: trimmed)
                {
                    let sequence = String(trimmed[seqRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sequence.isEmpty { return sequence }
                }
            }
        }

        return nil
    }

    private func normalizeChapters(_ chapters: [Chapter], bookDuration: Double?) -> [Chapter] {
        guard !chapters.isEmpty else { return [] }
        let sorted = chapters.sorted { $0.start < $1.start }

        var normalized: [Chapter] = []
        normalized.reserveCapacity(sorted.count)

        var titles: [String] = []
        titles.reserveCapacity(sorted.count)

        var seenIds = Set<String>()

        for (index, chapter) in sorted.enumerated() {
            let nextStart = (index + 1 < sorted.count) ? sorted[index + 1].start : (bookDuration ?? chapter.end)

            var end = chapter.end
            if end <= chapter.start || end == 0 {
                if nextStart > chapter.start {
                    end = nextStart
                } else if let bookDuration, bookDuration > chapter.start {
                    end = bookDuration
                }
            }

            var title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty || title.lowercased() == "chapter" || title.lowercased() == "chapter 1" {
                title = "Chapter \(index + 1)"
            }

            var id = chapter.id.isEmpty ? "chapter_\(index + 1)_\(Int(chapter.start * 1000))" : chapter.id
            if seenIds.contains(id) {
                id = "chapter_\(index + 1)_\(Int(chapter.start * 1000))"
            }
            if seenIds.contains(id) {
                id = "chapter_\(index + 1)_\(UUID().uuidString)"
            }
            seenIds.insert(id)

            titles.append(title)
            normalized.append(Chapter(id: id, start: chapter.start, end: end, title: title))
        }

        if Set(titles).count <= 1 {
            normalized = normalized.enumerated().map { index, chapter in
                Chapter(id: chapter.id, start: chapter.start, end: chapter.end, title: "Chapter \(index + 1)")
            }
        }

        return normalized
    }

    private struct PlexMediaContainerResponse<T: Codable>: Codable {
        let mediaContainer: T

        enum CodingKeys: String, CodingKey {
            case mediaContainer = "MediaContainer"
        }
    }

    private struct PlexSectionsResponse: Codable {
        let directory: [PlexSection]?

        enum CodingKeys: String, CodingKey {
            case directory = "Directory"
        }
    }

    private struct PlexSection: Codable {
        let key: String
        let title: String
        let type: String
    }

    fileprivate struct PlexItemsResponse: Codable {
        let metadata: [PlexMetadata]?
        let totalSize: Int?
        let size: Int?
        let offset: Int?

        enum CodingKeys: String, CodingKey {
            case metadata = "Metadata"
            case totalSize, size, offset
        }
    }

    fileprivate struct PlexMetadata: Codable {
        let ratingKey: String
        let key: String
        let parentRatingKey: String?
        let parentTitle: String?
        let grandparentTitle: String?
        let title: String
        let originalTitle: String?
        let type: String
        let thumb: String?
        let duration: Double?
        let addedAt: Int64?
        let lastViewedAt: Int64?
        let summary: String?
        let viewOffset: Double?
        let index: Int?
        let parentIndex: Int?
        let media: [PlexMedia]?

        let leafCount: Int?
        let viewCount: Int?

        enum CodingKeys: String, CodingKey {
            case ratingKey, key, parentRatingKey, parentTitle, grandparentTitle, title, originalTitle, type, thumb, duration, addedAt,
                lastViewedAt, summary, viewOffset, index, parentIndex
            case media = "Media"
            case leafCount, viewCount
        }
    }

    fileprivate struct PlexMedia: Codable {
        let duration: Double?
        let container: String?
        let audioCodec: String?
        let part: [PlexPart]?

        enum CodingKeys: String, CodingKey {
            case duration, container, audioCodec
            case part = "Part"
        }
    }

    fileprivate struct PlexPart: Codable {
        let id: Int?
        let key: String
        let duration: Double?
        let file: String?
        let container: String?
    }

    private func decodeItemsContainer(from data: Data) throws -> PlexItemsResponse {
        if let container = try? JSONDecoder().decode(PlexMediaContainerResponse<PlexItemsResponse>.self, from: data) {
            return container.mediaContainer
        }

        if let container = try? parseItemsXML(data: data),
            container.metadata?.isEmpty == false || container.totalSize != nil || container.size != nil
        {
            AppLogger.network.info("[PlexProvider] Parsed metadata container via XML fallback")
            return container
        }

        AppLogger.network.error("[PlexProvider] Could not decode metadata container response")
        throw ProviderError.invalidResponse
    }

    private func parseItemsXML(data: Data) throws -> PlexItemsResponse {
        let parser = XMLParser(data: data)
        let delegate = PlexItemsXMLParserDelegate()
        parser.delegate = delegate
        let parsed = parser.parse()
        if let parseError = delegate.parseError {
            throw parseError
        }
        guard parsed else {
            throw ProviderError.invalidResponse
        }
        return delegate.response
    }

    private func buildRequest(path: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
        guard let baseURL = URL(string: connection.url) else {
            throw ProviderError.invalidURL
        }

        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw ProviderError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let requestURL = components.url else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: requestURL)

        var clientId = "Enve-App"
        #if canImport(UIKit)
        clientId = UIDevice.current.identifierForVendor?.uuidString ?? StorageService.shared.loadDeviceUUID()
        #else
        clientId = StorageService.shared.loadDeviceUUID()
        #endif

        if let token = connection.effectivePlexToken {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
        request.setValue("Enve", forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientId, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func validateConnection() async throws -> Bool {
        let request = try buildRequest(path: "identity")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        let session = URLSession(configuration: config, delegate: InsecureURLSession.delegateInstance, delegateQueue: nil)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw ProviderError.unauthorized
        }

        return httpResponse.statusCode == 200
    }

    func fetchLibraries() async throws -> [Library] {
        let request = try buildRequest(path: "library/sections")
        let (data, response) = try await performDataTask(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw ProviderError.unauthorized
            }
            AppLogger.library.error("[PlexProvider] library/sections failed with status \(httpResponse.statusCode)")
            throw ProviderError.invalidResponse
        }

        let allSections = try decodeLibrarySections(from: data)

        let matched = allSections.filter { $0.type == "artist" }
        if matched.isEmpty {
            AppLogger.library.warning(
                "[PlexProvider] No artist sections found among \(allSections.count) total Plex sections - no Plex audiobook libraries available."
            )
        } else {
            AppLogger.library.info("[PlexProvider] Found \(matched.count) audiobook section(s) out of \(allSections.count) total")
        }
        return matched.map { section in
            Library(
                id: section.key,
                name: section.title,
                type: "book",
                providerId: connection.id
            )
        }
    }

    private func decodeLibrarySections(from data: Data) throws -> [PlexSection] {
        if let container = try? JSONDecoder().decode(PlexMediaContainerResponse<PlexSectionsResponse>.self, from: data) {
            return container.mediaContainer.directory ?? []
        }

        if let sections = try? parseLibrarySectionsXML(data: data), !sections.isEmpty {
            AppLogger.library.info("[PlexProvider] Parsed library sections via XML fallback")
            return sections
        }

        AppLogger.library.error("[PlexProvider] Could not decode library sections response")
        throw ProviderError.invalidResponse
    }

    private func parseLibrarySectionsXML(data: Data) throws -> [PlexSection] {
        let parser = XMLParser(data: data)
        let delegate = PlexSectionsXMLParserDelegate()
        parser.delegate = delegate
        let parsed = parser.parse()
        if let parseError = delegate.parseError {
            throw parseError
        }
        guard parsed else {
            throw ProviderError.invalidResponse
        }
        return delegate.sections.map { PlexSection(key: $0.key, title: $0.title, type: $0.type) }
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        let pageSize = 500
        let pageConcurrency = 6

        let iterationCeiling = 2_000
        let startTime = Date()

        AppLogger.library.info("[PlexProvider] Starting paginated fetch for library \(libraryId), pageSize=\(pageSize)")

        let firstPage: PlexAlbumsPage
        do {
            firstPage = try await fetchPlexAlbumsPage(libraryId: libraryId, offset: 0, limit: pageSize)
        } catch let error as DecodingError {
            AppLogger.library.error("[PlexProvider] First page decode failed: \(error.localizedDescription). Falling back to track scan.")
            return try await fetchBooksViaTrackFallback(libraryId: libraryId, startTime: startTime)
        }

        var allAlbums: [PlexMetadata] = firstPage.metadata
        let total = firstPage.totalSize ?? allAlbums.count
        await publishPlexImportProgress(libraryId: libraryId, loaded: allAlbums.count, total: total, startTime: startTime)

        if let totalSize = firstPage.totalSize, totalSize > allAlbums.count, !firstPage.metadata.isEmpty {
            let cappedTotal = min(totalSize, iterationCeiling * pageSize)
            if cappedTotal < totalSize {
                AppLogger.library.error(
                    "[PlexProvider] Library has \(totalSize) items, exceeds \(iterationCeiling * pageSize)-item runaway guard. Server may be reporting an unbounded total."
                )
            }
            var pendingOffsets = Array(stride(from: pageSize, to: cappedTotal, by: pageSize))

            while !pendingOffsets.isEmpty {
                let chunkSize = min(pageConcurrency, pendingOffsets.count)
                let chunk = Array(pendingOffsets.prefix(chunkSize))
                pendingOffsets.removeFirst(chunkSize)

                let pages = try await withThrowingTaskGroup(of: (Int, [PlexMetadata]).self) { group in
                    for offset in chunk {
                        group.addTask { [self] in
                            do {
                                let page = try await fetchPlexAlbumsPage(libraryId: libraryId, offset: offset, limit: pageSize)
                                return (offset, page.metadata)
                            } catch let error as DecodingError {
                                AppLogger.library.error(
                                    "[PlexProvider] Decode error at offset \(offset): \(error.localizedDescription). Skipping page."
                                )
                                return (offset, [])
                            }
                        }
                    }
                    var collected: [(Int, [PlexMetadata])] = []
                    for try await result in group { collected.append(result) }
                    return collected.sorted { $0.0 < $1.0 }
                }

                for (_, metadata) in pages {
                    allAlbums.append(contentsOf: metadata)
                }
                await publishPlexImportProgress(libraryId: libraryId, loaded: allAlbums.count, total: totalSize, startTime: startTime)
                AppLogger.library.info("[PlexProvider] Progress: \(allAlbums.count)/\(totalSize) (chunk of \(chunkSize) pages done)")
            }
        } else if firstPage.totalSize == nil && firstPage.metadata.count >= pageSize {

            var offset = pageSize
            var iter = 1
            while iter < iterationCeiling {
                iter += 1
                do {
                    let page = try await fetchPlexAlbumsPage(libraryId: libraryId, offset: offset, limit: pageSize)
                    if page.metadata.isEmpty { break }
                    allAlbums.append(contentsOf: page.metadata)
                    await publishPlexImportProgress(
                        libraryId: libraryId,
                        loaded: allAlbums.count,
                        total: allAlbums.count,
                        startTime: startTime
                    )
                    offset += page.metadata.count
                } catch let error as DecodingError {
                    AppLogger.library.error("[PlexProvider] Decode error at offset \(offset): \(error.localizedDescription). Skipping.")
                    offset += pageSize
                }
            }
        }

        let indexDuration = Date().timeIntervalSince(startTime)
        AppLogger.library.info("[PlexProvider] Index complete: \(allAlbums.count) albums in \(String(format: "%.1f", indexDuration))s")

        if allAlbums.isEmpty {
            AppLogger.library.warning("[PlexProvider] Album scan returned 0 results. Attempting track-based fallback (type=10).")
            return try await fetchBooksViaTrackFallback(libraryId: libraryId, startTime: startTime)
        }

        let albums = Array(Dictionary(allAlbums.map { ($0.ratingKey, $0) }, uniquingKeysWith: { first, _ in first }).values)
            .sorted { $0.ratingKey < $1.ratingKey }
        AppLogger.library.info("[PlexProvider] Importing \(albums.count) Plex albums as logical books")

        var books: [Book] = []
        var errorCount = 0
        let totalAlbums = albums.count

        let albumProcessingConcurrency = 10

        for batchStart in stride(from: 0, to: totalAlbums, by: albumProcessingConcurrency) {
            let batchEnd = min(batchStart + albumProcessingConcurrency, totalAlbums)
            let batch = Array(albums[batchStart..<batchEnd])

            let batchResults = await withTaskGroup(of: Result<[Book], Error>.self) { group in
                for album in batch {
                    group.addTask {
                        do {
                            return .success(try await self.processPlexAlbum(album, libraryId: libraryId))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                var result: [Book] = []
                var batchErrors = 0
                for await outcome in group {
                    switch outcome {
                    case .success(let albumBooks):
                        result.append(contentsOf: albumBooks)
                    case .failure(let error):
                        batchErrors += 1
                        AppLogger.library.warning("[PlexProvider] Album processing error: \(error.localizedDescription)")
                    }
                }
                errorCount += batchErrors
                return result
            }

            books.append(contentsOf: batchResults)

            let processedGroups = batchEnd
            let progressPercent = totalAlbums > 0 ? (processedGroups * 100 / totalAlbums) : 100
            let prevPercent = totalAlbums > 0 ? ((processedGroups - albumProcessingConcurrency) * 100 / totalAlbums) : 0
            if progressPercent / 10 > prevPercent / 10 || processedGroups >= totalAlbums {
                let currentBookCount = books.count
                await MainActor.run {
                    AppState.shared.presentation.libraryImportProgress = LibraryImportProgress(
                        libraryId: libraryId,
                        libraryName: connection.name,
                        loadedCount: currentBookCount,
                        totalCount: totalAlbums,
                        isComplete: false,
                        phase: .indexing,
                        startTime: startTime
                    )
                }
            }
        }

        let validBooks = books.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let filteredCount = books.count - validBooks.count
        let totalDuration = Date().timeIntervalSince(startTime)

        if filteredCount > 0 {
            AppLogger.library.warning("[PlexProvider] Filtered out \(filteredCount) books with empty titles")
        }
        if errorCount > 0 {
            AppLogger.library.warning("[PlexProvider] \(errorCount)/\(totalAlbums) albums had processing errors (skipped, not fatal)")
        }

        AppLogger.library.info(
            "[PlexProvider] Import complete: \(validBooks.count) books from \(totalAlbums) Plex albums in \(String(format: "%.1f", totalDuration))s (errors: \(errorCount))"
        )
        return validBooks
    }

    func makeCatalogBatchSource(
        libraryId: String,
        resumeAfter: String?,
        expectedSnapshotIdentifier: String?
    ) async throws -> LibraryCatalogBatchSource {
        let firstPage = try await catalogPage(libraryId: libraryId, page: 0)
        return LibraryCatalogBatchSource.paged(
            firstPage: firstPage,
            pageSize: 500,
            pageConcurrency: 4,
            resumeAfter: resumeAfter,
            expectedSnapshotIdentifier: expectedSnapshotIdentifier,
            fetchPage: { try await self.catalogPage(libraryId: libraryId, page: $0) }
        )
    }

    private func catalogPage(libraryId: String, page: Int) async throws -> LibraryCatalogPage {
        let pageSize = 500
        let offset = page * pageSize
        let response = try await fetchPlexAlbumsPage(
            libraryId: libraryId,
            offset: offset,
            limit: pageSize
        )
        var books: [Book] = []
        for offset in stride(from: 0, to: response.metadata.count, by: 10) {
            let end = min(offset + 10, response.metadata.count)
            let albums = Array(response.metadata[offset..<end])
            let mapped = await withTaskGroup(of: [Book].self) { group in
                for album in albums {
                    group.addTask { (try? await self.processPlexAlbum(album, libraryId: libraryId)) ?? [] }
                }
                var result: [Book] = []
                for await books in group { result.append(contentsOf: books) }
                return result
            }
            books.append(contentsOf: mapped)
        }
        books.removeAll { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return LibraryCatalogPage(
            books: books,
            totalCount: response.totalSize,
            isLast: response.metadata.count < pageSize
                || response.totalSize.map { offset + response.metadata.count >= $0 } == true
        )
    }

    private struct PlexAlbumsPage: Sendable {
        let metadata: [PlexMetadata]
        let totalSize: Int?
    }

    private func fetchPlexAlbumsPage(libraryId: String, offset: Int, limit: Int) async throws -> PlexAlbumsPage {
        let request = try buildRequest(
            path: "library/sections/\(libraryId)/all",
            queryItems: [
                URLQueryItem(name: "type", value: "9"),
                URLQueryItem(name: "includeMedia", value: "1"),
                URLQueryItem(name: "X-Plex-Container-Start", value: String(offset)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(limit)),
            ]
        )
        let (data, response) = try await performDataTask(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProviderError.invalidResponse
        }
        let container = try decodeItemsContainer(from: data)
        return PlexAlbumsPage(
            metadata: container.metadata ?? [],
            totalSize: container.totalSize
        )
    }

    private func publishPlexImportProgress(libraryId: String, loaded: Int, total: Int, startTime: Date) async {
        await MainActor.run {
            AppState.shared.presentation.libraryImportProgress = LibraryImportProgress(
                libraryId: libraryId,
                libraryName: connection.name,
                loadedCount: loaded,
                totalCount: total,
                isComplete: false,
                phase: .indexing,
                startTime: startTime
            )
        }
    }

    private func fetchBooksViaTrackFallback(libraryId: String, startTime: Date) async throws -> [Book] {
        let pageSize = 200
        var allTracks: [PlexMetadata] = []
        var offset = 0
        var totalSize: Int? = nil

        let iterationCeiling = 10_000
        var iter = 0

        repeat {
            iter += 1
            if iter > iterationCeiling {
                AppLogger.library.error(
                    "[PlexProvider] fetchBooksViaTrackFallback hit \(iterationCeiling)-iteration runaway guard for library \(libraryId)"
                )
                break
            }
            let request = try buildRequest(
                path: "library/sections/\(libraryId)/all",
                queryItems: [
                    URLQueryItem(name: "type", value: "10"),
                    URLQueryItem(name: "includeMedia", value: "1"),
                    URLQueryItem(name: "X-Plex-Container-Start", value: String(offset)),
                    URLQueryItem(name: "X-Plex-Container-Size", value: String(pageSize)),
                ]
            )

            let (data, response) = try await performDataTask(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { break }

            guard let container = try? decodeItemsContainer(from: data) else {
                offset += pageSize
                continue
            }

            let page = container.metadata ?? []
            allTracks.append(contentsOf: page)
            if totalSize == nil { totalSize = container.totalSize }

            await MainActor.run {
                AppState.shared.presentation.libraryImportProgress = LibraryImportProgress(
                    libraryId: libraryId,
                    libraryName: connection.name,
                    loadedCount: allTracks.count,
                    totalCount: totalSize ?? allTracks.count,
                    isComplete: false,
                    phase: .indexing,
                    startTime: startTime
                )
            }

            if page.isEmpty { break }
            offset += page.count
            if let ts = totalSize, offset >= ts { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while true

        AppLogger.library.info("[PlexProvider] Track fallback: found \(allTracks.count) tracks. Grouping by Plex parent album...")

        let tracksByAlbum = Dictionary(grouping: allTracks) { track in
            track.parentRatingKey ?? "track:\(track.ratingKey)"
        }
        var books: [Book] = []

        for tracks in tracksByAlbum.values {
            let sorted = orderedTracks(tracks)
            guard let primary = sorted.first else { continue }

            guard let albumID = primary.parentRatingKey else {
                books.append(mapPlexMetadataToBook(primary, libraryId: libraryId))
                continue
            }

            let title = primary.parentTitle ?? primary.title
            let author = primary.grandparentTitle ?? primary.parentTitle ?? "Unknown Author"
            let timeline = trackTimeline(from: sorted)

            let coverURL = primary.thumb.flatMap { path -> URL? in
                var components = URLComponents(
                    string:
                        "\(connection.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
                )
                if let token = connection.effectivePlexToken {
                    components?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
                }
                return components?.url
            }

            books.append(
                Book(
                    id: albumID,
                    title: title,
                    author: author,
                    narrator: extractNarrator(from: primary, author: author),
                    seriesInfo: primary.media?.first?.part?.first?.file.flatMap { parseSeriesFromPath($0, author: author, title: title) }
                        ?? parseSeriesFromTitle(title),
                    duration: timeline.duration,
                    coverURL: coverURL,
                    partKey: timeline.partKey,
                    audioTracks: timeline.audioTracks,
                    dateAdded: Date(timeIntervalSince1970: TimeInterval(primary.addedAt ?? 0)),
                    releaseDate: nil,
                    description: primary.summary,
                    genres: [],
                    chapters: timeline.chapters,
                    publisher: nil,
                    currentTime: 0,
                    isFinished: false,
                    lastUpdate: Date(),
                    libraryId: libraryId,
                    providerId: connection.id,
                    backendId: connection.id.uuidString,
                    source: .plex,
                    rawMetadata: nil
                )
            )
        }

        AppLogger.library.info("[PlexProvider] Track fallback complete: \(books.count) books from \(allTracks.count) tracks")
        return books
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        let request = try buildRequest(
            path: "library/sections/\(libraryId)/all",
            queryItems: [
                URLQueryItem(name: "type", value: "9"),
                URLQueryItem(name: "includeMedia", value: "1"),
                URLQueryItem(name: "sort", value: "addedAt:desc"),
                URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(max(1, limit))),
            ]
        )

        let (data, response) = try await performDataTask(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProviderError.invalidResponse
        }

        let container = try decodeItemsContainer(from: data)
        let albums = container.metadata ?? []

        var books: [Book] = []
        for album in albums {
            let albumBooks = try await processPlexAlbum(album, libraryId: libraryId)
            books.append(contentsOf: albumBooks)
        }

        return books.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private func processPlexAlbum(_ album: PlexMetadata, libraryId: String) async throws -> [Book] {
        let trackRequest = try buildRequest(
            path: "library/metadata/\(album.ratingKey)/children",
            queryItems: [
                URLQueryItem(name: "includeMedia", value: "1")
            ]
        )

        do {
            let (trackData, _) = try await performDataTask(for: trackRequest)
            let trackContainer = try decodeItemsContainer(from: trackData)
            let tracks = orderedTracks(trackContainer.metadata ?? [])

            guard !tracks.isEmpty else {
                return [mapPlexMetadataToBook(album, libraryId: libraryId)]
            }

            let timeline = trackTimeline(from: tracks)
            return [
                mapPlexMetadataToBook(
                    album,
                    libraryId: libraryId,
                    overrideDuration: timeline.duration,
                    partKey: timeline.partKey,
                    audioTracks: timeline.audioTracks,
                    chapters: timeline.chapters
                )
            ]
        } catch {
            AppLogger.network.error(
                "Failed to fetch tracks albumDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: album.title)); using single item"
            )
            return [mapPlexMetadataToBook(album, libraryId: libraryId)]
        }
    }

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        AppLogger.network.info("[PlexProvider] Fetching full details for book: \(bookId) in library: \(libraryId)")

        let existingBook: Book? = await {
            let candidate = await AppState.shared.bookStore.book(byBookId: bookId)
            return candidate?.source == .plex ? candidate : nil
        }()
        if let existingBook, let audioTracks = existingBook.audioTracks, audioTracks.count > 1 {
            AppLogger.network.info("[PlexProvider] Book \(bookId) is a multi-album book with \(audioTracks.count) tracks")
            return existingBook
        }

        let metadataRequest = try buildRequest(
            path: "library/metadata/\(bookId)",
            queryItems: [
                URLQueryItem(name: "includeChapters", value: "1")
            ]
        )

        var request = metadataRequest
        request.timeoutInterval = 30

        let (metadataData, _) = try await performDataTask(for: request)
        let metadataContainer = try decodeItemsContainer(from: metadataData)

        guard let item = metadataContainer.metadata?.first else {
            throw ProviderError.invalidResponse
        }

        let isTrackBook = item.type == "track"

        if isTrackBook {
            AppLogger.network.info("[PlexProvider] Book \(bookId) is a track-based book (single audio file)")
            var book = mapTrackBookToFullBook(item, libraryId: libraryId)
            let bookDuration = book.duration ?? 0

            var chapters: [Chapter] = []
            if let embeddedChapters = try? await fetchEmbeddedChapters(bookId: bookId, bookDuration: bookDuration) {
                let normalized = normalizeChapters(embeddedChapters, bookDuration: bookDuration)
                chapters = normalized
                AppLogger.network.info("[PlexProvider] Found \(normalized.count) embedded chapters for track book from Plex")
            }

            if areChaptersInadequate(chapters, bookDuration: bookDuration),
                let media = item.media?.first,
                let part = media.part?.first,
                let streamURL = buildStreamingURL(partKey: part.key)
            {
                AppLogger.network.info("Inadequate chapters from Plex (\(chapters.count)), attempting extraction from audio file")

                do {
                    let extractedChapters = try await extractChaptersFromAudioFile(
                        streamURL: streamURL,
                        bookDuration: bookDuration
                    )

                    if !extractedChapters.isEmpty {
                        chapters = extractedChapters
                        AppLogger.network.warning("Fallback: Extracted \(chapters.count) chapters from audio file")
                    } else {
                        AppLogger.network.info("No chapters found in audio file, using Plex chapters")
                    }
                } catch {
                    AppLogger.network.error("Chapter extraction fallback failed: \(error.localizedDescription), using Plex chapters")
                }
            } else if !areChaptersInadequate(chapters, bookDuration: bookDuration) && !chapters.isEmpty {
                AppLogger.network.warning("Adequate Plex chapters (\(chapters.count)), skipping extraction")
            }

            book.chapters = chapters

            if (book.chapters ?? []).isEmpty, bookDuration > 0 {
                book.chapters = [Chapter(id: "full_book", start: 0, end: bookDuration, title: book.title)]
            }

            return book
        }

        let childrenRequest = try buildRequest(path: "library/metadata/\(bookId)/children")
        let (data, response) = try await performDataTask(for: childrenRequest)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProviderError.invalidResponse
        }

        let container = try decodeItemsContainer(from: data)
        let allTracks = orderedTracks(container.metadata ?? [])
        let timeline = trackTimeline(from: allTracks)
        let fallbackDuration = durationSeconds(from: item)
        let finalDuration = timeline.duration > 0 ? timeline.duration : fallbackDuration

        AppLogger.network.info("[PlexProvider] Total duration: \(finalDuration)s, Chapters: \(timeline.chapters.count)")

        var normalizedChapters = timeline.chapters
        if allTracks.count == 1,
            let onlyTrack = allTracks.first,
            let embeddedChapters = try? await fetchEmbeddedChapters(
                bookId: onlyTrack.ratingKey,
                bookDuration: finalDuration
            ),
            !areChaptersInadequate(embeddedChapters, bookDuration: finalDuration)
        {
            normalizedChapters = embeddedChapters
            AppLogger.network.info("[PlexProvider] Found \(embeddedChapters.count) embedded chapters on track \(onlyTrack.ratingKey)")
        }

        if areChaptersInadequate(normalizedChapters, bookDuration: finalDuration),
            let firstTrack = allTracks.first,
            let media = firstTrack.media?.first,
            let part = media.part?.first,
            let streamURL = buildStreamingURL(partKey: part.key)
        {
            AppLogger.network.info(
                "Inadequate chapters from Plex (\(normalizedChapters.count)), attempting extraction from first audio file"
            )

            do {
                let extractedChapters = try await extractChaptersFromAudioFile(
                    streamURL: streamURL,
                    bookDuration: finalDuration
                )

                if !extractedChapters.isEmpty {
                    normalizedChapters = extractedChapters
                    AppLogger.network.warning("Fallback: Extracted \(extractedChapters.count) chapters from audio file")
                } else {
                    AppLogger.network.info("No chapters found in audio file, using Plex chapters")
                }
            } catch {
                AppLogger.network.error("Chapter extraction fallback failed: \(error.localizedDescription), using Plex chapters")
            }
        } else if !areChaptersInadequate(normalizedChapters, bookDuration: finalDuration) && !normalizedChapters.isEmpty {
            AppLogger.network.warning("Adequate Plex chapters (\(normalizedChapters.count)), skipping extraction")
        }
        let safeDuration: Double
        if finalDuration > 0 {
            safeDuration = finalDuration
        } else if let last = normalizedChapters.last, last.end > 0 {
            safeDuration = last.end
        } else {
            safeDuration = 0
        }

        let fallbackChapters =
            normalizedChapters.isEmpty && safeDuration > 0
            ? [Chapter(id: "full_book", start: 0, end: safeDuration, title: item.title)]
            : normalizedChapters

        return mapPlexMetadataToBook(
            item,
            libraryId: libraryId,
            overrideDuration: safeDuration,
            partKey: timeline.partKey,
            audioTracks: timeline.audioTracks,
            chapters: fallbackChapters
        )
    }

    private func fetchEmbeddedChapters(bookId: String, bookDuration: Double?) async throws -> [Chapter] {
        guard let baseURL = URL(string: connection.url) else {
            throw ProviderError.invalidURL
        }

        guard
            var components = URLComponents(
                url: baseURL.appendingPathComponent("library/metadata/\(bookId)"),
                resolvingAgainstBaseURL: false
            )
        else {
            throw ProviderError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "includeChapters", value: "1")]

        guard let requestURL = components.url else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        if let token = connection.effectivePlexToken {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await performDataTask(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProviderError.invalidResponse
        }

        let chapters = parseChaptersFromXML(data)
        return normalizeChapters(chapters, bookDuration: bookDuration)
    }

    private func parseChaptersFromXML(_ data: Data) -> [Chapter] {
        let parser = XMLParser(data: data)
        let delegate = PlexChapterXMLParserDelegate()
        parser.delegate = delegate

        guard parser.parse() else {
            AppLogger.network.error("Failed to parse chapters XML")
            return []
        }

        return delegate.chapters
    }

    private func areChaptersInadequate(_ chapters: [Chapter], bookDuration: Double) -> Bool {
        if chapters.count == 1 && bookDuration > 1800 {
            return true
        }
        if chapters.isEmpty && bookDuration > 0 {
            return true
        }
        return false
    }

    private func buildStreamingURL(partKey: String) -> URL? {
        guard let baseURL = URL(string: connection.url) else { return nil }
        let cleanPartKey = partKey.hasPrefix("/") ? partKey : "/\(partKey)"
        let urlString = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + cleanPartKey

        var components = URLComponents(string: urlString)
        var queryItems = [URLQueryItem(name: "download", value: "1")]
        if let token = connection.effectivePlexToken {
            queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }
        components?.queryItems = queryItems

        return components?.url
    }

    private func extractChaptersFromAudioFile(streamURL: URL, bookDuration: Double) async throws -> [Chapter] {
        let asset = AVURLAsset(url: streamURL)

        let startTime = Date()
        let chapterLocales = try await asset.load(.availableChapterLocales)

        guard Date().timeIntervalSince(startTime) < 10 else {
            throw NSError(
                domain: "ChapterExtraction",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Timeout loading chapter locales"]
            )
        }

        var extractedChapters: [Chapter] = []

        for locale in chapterLocales {
            let chapterGroups = try await asset.loadChapterMetadataGroups(
                withTitleLocale: locale,
                containingItemsWithCommonKeys: [.commonKeyArtwork]
            )

            for (index, group) in chapterGroups.enumerated() {
                let chapterStartTime = CMTimeGetSeconds(group.timeRange.start)
                let duration = CMTimeGetSeconds(group.timeRange.duration)
                let chapterEndTime = chapterStartTime + duration

                var title = "Chapter \(index + 1)"
                if let titleItem = group.items.first(where: { $0.commonKey == .commonKeyTitle }),
                    let titleValue = try? await titleItem.load(.value) as? String
                {
                    title = titleValue
                }

                let chapter = Chapter(
                    id: String(index),
                    start: chapterStartTime,
                    end: chapterEndTime,
                    title: title
                )
                extractedChapters.append(chapter)
            }

            if !extractedChapters.isEmpty {
                break
            }
        }

        return extractedChapters
    }

    private func mapTrackBookToFullBook(_ track: PlexMetadata, libraryId: String) -> Book {
        let thumbUrl: URL? = track.thumb.flatMap { thumbPath in
            let baseUrlString = connection.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let pathString = thumbPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let fullString = "\(baseUrlString)/\(pathString)"

            var components = URLComponents(string: fullString)
            if let token = connection.effectivePlexToken {
                components?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
            }
            return components?.url
        }

        let duration = durationSeconds(from: track)
        let partKey = track.media?.first?.part?.first?.key
        let audioTracks = [
            AudioTrack(
                id: track.ratingKey,
                index: 0,
                title: track.title,
                contentUrl: partKey,
                duration: duration,
                startOffset: 0,
                format: mimeType(from: track)
            )
        ]

        let author = track.grandparentTitle ?? track.parentTitle ?? "Unknown Author"
        let bookTitle = track.title

        let narrator = extractNarrator(from: track, author: author)
        var seriesInfo = extractSeriesInfo(from: track, author: author)
        if seriesInfo == nil,
            let parentTitle = track.parentTitle,
            !parentTitle.isEmpty,
            parentTitle != track.title,
            parentTitle.lowercased() != author.lowercased()
        {
            seriesInfo = SeriesInfo(name: parentTitle, sequence: nil)
        }

        let chapters: [Chapter] = []

        return Book(
            id: track.ratingKey,
            title: bookTitle,
            author: author,
            narrator: narrator,
            seriesInfo: seriesInfo,
            duration: duration,
            coverURL: thumbUrl,
            partKey: partKey,
            audioTracks: audioTracks,
            dateAdded: Date(timeIntervalSince1970: TimeInterval(track.addedAt ?? 0)),
            releaseDate: nil,
            description: track.summary,
            genres: [],
            chapters: chapters,
            publisher: nil,
            currentTime: (track.viewOffset ?? 0) / 1000.0,
            isFinished: false,
            lastUpdate: Date(),
            libraryId: libraryId,
            providerId: connection.id,
            backendId: connection.id.uuidString,
            source: .plex,
            rawMetadata: ["isTrackBook": "true"]
        )
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] {
        guard let libId = libraryId else { return [] }

        let request = try buildRequest(path: "library/sections/\(libId)/collections")
        let (data, response) = try await performDataTask(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        let container = try JSONDecoder().decode(PlexMediaContainerResponse<PlexSectionsResponse>.self, from: data)
        return container.mediaContainer.directory?.map { collection in
            Collection(
                id: collection.key,
                name: collection.title,
                description: "",
                books: [],
                bookCount: 0,
                iconName: "square.grid.2x2",
                color: "blue",
                providerId: connection.id
            )
        } ?? []
    }

    func fetchSeries(libraryId: String) async throws -> [Series] {
        return []
    }

    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] {
        let request = try buildRequest(
            path: "library/sections/\(libraryId)/all",
            queryItems: [
                URLQueryItem(name: "type", value: "9")
            ]
        )

        let (data, response) = try await performDataTask(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProviderError.invalidResponse
        }

        let container = try decodeItemsContainer(from: data)
        return container.metadata?.compactMap { item -> UserMediaProgress? in
            guard let viewOffset = item.viewOffset, let duration = item.duration else { return nil }

            return UserMediaProgress(
                id: item.ratingKey,
                libraryItemId: item.ratingKey,
                providerId: connection.id,
                episodeId: nil,
                currentTime: viewOffset / 1000.0,
                progress: viewOffset / duration,
                isFinished: false,
                duration: duration / 1000.0,
                lastUpdate: item.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date.distantPast,
                ebookProgress: nil
            )
        } ?? []
    }

    func getAudioURL(for book: Book) -> URL? {
        return nil
    }

    func chapterExtractionURL(for book: Book) -> URL? {
        guard let partKey = book.partKey, !partKey.isEmpty else { return nil }
        return buildStreamingURL(partKey: partKey)
    }

    func getStreamingHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        if let token = connection.effectivePlexToken {
            headers["X-Plex-Token"] = token
        }
        return headers
    }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        guard let baseURL = URL(string: connection.url) else {
            throw ProviderError.invalidURL
        }

        let token = connection.effectivePlexToken ?? ""
        var audioTracks: [AudioTrackInfo] = []

        if let storedTracks = book.audioTracks, storedTracks.count > 1 {
            AppLogger.network.debug(
                "Starting multi-album playback bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) tracks=\(storedTracks.count)"
            )
            for track in storedTracks {
                guard let partKey = track.contentUrl else { continue }
                guard var components = URLComponents(url: baseURL.appendingPathComponent(partKey), resolvingAgainstBaseURL: false) else {
                    continue
                }
                components.queryItems = [
                    URLQueryItem(name: "X-Plex-Token", value: token),
                    URLQueryItem(name: "download", value: "1"),
                ]

                audioTracks.append(
                    AudioTrackInfo(
                        id: track.id,
                        index: track.index,
                        startOffset: track.startOffset,
                        duration: track.duration,
                        contentUrl: components.url?.absoluteString ?? partKey,
                        mimeType: track.format ?? "application/octet-stream",
                        title: track.title
                    )
                )
            }

            AppLogger.network.info("Playback session created with \(audioTracks.count) audio track(s)")
            return PlaybackSessionInfo(
                sessionId: UUID().uuidString,
                audioTracks: audioTracks,
                chapters: book.chapters ?? []
            )
        }

        let metadataRequest = try buildRequest(path: "library/metadata/\(book.id)")
        let (metadataData, _) = try await performDataTask(for: metadataRequest)
        let metadataContainer = try decodeItemsContainer(from: metadataData)

        guard let item = metadataContainer.metadata?.first else {
            throw ProviderError.invalidResponse
        }

        let isTrackBook = item.type == "track"

        if isTrackBook {
            AppLogger.network.debug(
                "Starting track playback bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )

            guard let media = item.media?.first, let part = media.part?.first else {
                throw ProviderError.invalidResponse
            }

            guard var components = URLComponents(url: baseURL.appendingPathComponent(part.key), resolvingAgainstBaseURL: false) else {
                throw ProviderError.invalidURL
            }
            components.queryItems = [
                URLQueryItem(name: "X-Plex-Token", value: token),
                URLQueryItem(name: "download", value: "1"),
            ]

            let trackInfo = AudioTrackInfo(
                id: item.ratingKey,
                index: 0,
                startOffset: 0,
                duration: (item.duration ?? 0) / 1000.0,
                contentUrl: components.url?.absoluteString ?? part.key,
                mimeType: mimeType(from: item),
                title: item.title
            )
            audioTracks.append(trackInfo)

        } else {
            AppLogger.network.debug(
                "Starting album playback bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )

            let request = try buildRequest(path: "library/metadata/\(book.id)/children")
            let (data, _) = try await performDataTask(for: request)
            let container = try decodeItemsContainer(from: data)
            let allTracks = orderedTracks(container.metadata ?? [])

            var cumulativeOffset: Double = 0

            for (index, track) in allTracks.enumerated() {
                guard let media = track.media?.first, let part = media.part?.first else { continue }

                guard var components = URLComponents(url: baseURL.appendingPathComponent(part.key), resolvingAgainstBaseURL: false) else {
                    continue
                }
                components.queryItems = [
                    URLQueryItem(name: "X-Plex-Token", value: token),
                    URLQueryItem(name: "download", value: "1"),
                ]

                let trackInfo = AudioTrackInfo(
                    id: track.ratingKey,
                    index: index,
                    startOffset: cumulativeOffset,
                    duration: (track.duration ?? 0) / 1000.0,
                    contentUrl: components.url?.absoluteString ?? part.key,
                    mimeType: mimeType(from: track),
                    title: track.title
                )
                audioTracks.append(trackInfo)
                cumulativeOffset += trackInfo.duration
            }
        }

        AppLogger.network.info("Playback session created with \(audioTracks.count) audio track(s)")

        return PlaybackSessionInfo(
            sessionId: UUID().uuidString,
            audioTracks: audioTracks,
            chapters: book.chapters ?? []
        )
    }

    func fetchAudiobookProgress(
        for book: Book
    ) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isAbandoned: Bool)? {
        let request = try buildRequest(path: "library/metadata/\(book.id)")
        let (data, response) = try await performDataTask(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        guard let container = try? decodeItemsContainer(from: data),
            let item = container.metadata?.first
        else { return nil }

        let durationMs = durationMilliseconds(from: item)
        let offsetMs = item.viewOffset ?? 0
        let positionSeconds = offsetMs / 1000.0
        let percentage = durationMs > 0 ? offsetMs / durationMs : 0
        let updatedAt = item.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let isFinished = (item.viewCount ?? 0) > 0 && offsetMs <= 0

        return (positionSeconds: positionSeconds, percentage: percentage, trackIndex: nil, updatedAt: updatedAt, isAbandoned: isFinished)
    }

    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
        let target = resolvePlexProgressTarget(book: book, currentTime: currentTime)
        let offsetMs = Int(target.time * 1000)
        let durationMs = Int(target.duration * 1000)

        let queryItems = [
            URLQueryItem(name: "key", value: "/library/metadata/\(target.ratingKey)"),
            URLQueryItem(name: "ratingKey", value: target.ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "state", value: isFinished ? "stopped" : "playing"),
            URLQueryItem(name: "time", value: "\(offsetMs)"),
            URLQueryItem(name: "duration", value: "\(durationMs)"),
        ]

        var request = try buildRequest(path: ":/timeline", queryItems: queryItems)
        request.httpMethod = "POST"
        if let sessionId, !sessionId.isEmpty {
            request.setValue(sessionId, forHTTPHeaderField: "X-Plex-Session-Identifier")
        }
        let (_, response) = try await performDataTask(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.invalidResponse
        }
    }

    private func performDataTask(for request: URLRequest, retryCount: Int = 3) async throws -> (Data, URLResponse) {
        var currentRetry = 0
        while true {
            do {
                if currentRetry > 0 {
                    AppLogger.network.warning(
                        "Executing request: \(request.url?.redacted.absoluteString ?? "unknown") (Attempt \(currentRetry + 1))"
                    )
                }
                return try await InsecureURLSession.shared.data(for: request)
            } catch {
                let nsError = error as NSError
                let retryableCodes = [-1001, -1003, -1005, -1009]

                if currentRetry < retryCount && retryableCodes.contains(nsError.code) {
                    currentRetry += 1
                    let delay = pow(2.0, Double(currentRetry))
                    AppLogger.network.error(
                        "Request failed with error \(nsError.code). Retrying in \(delay)s... (Attempt \(currentRetry + 1)/\(retryCount + 1))"
                    )
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
    }

    private func mapPlexMetadataToBook(
        _ item: PlexMetadata,
        libraryId: String,
        overrideDuration: Double? = nil,
        partKey: String? = nil,
        audioTracks: [AudioTrack]? = nil,
        chapters: [Chapter]? = nil
    ) -> Book {
        let thumbUrl: URL? = item.thumb.flatMap { thumbPath in
            let baseUrlString = connection.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let pathString = thumbPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let fullString = "\(baseUrlString)/\(pathString)"

            var components = URLComponents(string: fullString)
            if let token = connection.effectivePlexToken {
                components?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
            }
            return components?.url
        }

        if thumbUrl == nil {
            AppLogger.network.debug(
                "No cover URL itemDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: item.title)) hasThumb=\(item.thumb != nil)"
            )
        }

        let duration = overrideDuration ?? durationSeconds(from: item)
        let itemFilePath = item.media?.first?.part?.first?.file

        let bookTitle = item.title
        let author = item.grandparentTitle ?? item.parentTitle ?? "Unknown Author"
        let narrator = extractNarrator(from: item, author: author)
        let seriesInfo = extractSeriesInfo(from: item, author: author)

        let finalPartKey = partKey ?? item.media?.first?.part?.first?.key
        AppLogger.network.debug("Mapping book: ID=\(item.ratingKey), Title=\"\(bookTitle)\", partKey=\(finalPartKey ?? "nil")")

        return Book(
            id: item.ratingKey,
            title: bookTitle,
            author: author,
            narrator: narrator,
            seriesInfo: seriesInfo,
            duration: duration,
            coverURL: thumbUrl,
            partKey: finalPartKey,
            audioTracks: audioTracks,
            dateAdded: Date(timeIntervalSince1970: TimeInterval(item.addedAt ?? 0)),
            releaseDate: nil,
            description: item.summary,
            genres: [],
            chapters: chapters ?? [],
            publisher: nil,
            currentTime: (item.viewOffset ?? 0) / 1000.0,
            isFinished: (item.viewCount ?? 0) > 0 && (item.viewOffset ?? 0) <= 0,
            lastUpdate: Date(),
            libraryId: libraryId,

            providerId: connection.id,
            backendId: connection.id.uuidString,
            source: .plex,
            rawMetadata: nil,
            filePath: itemFilePath
        )
    }
}

private final class PlexItemsXMLParserDelegate: NSObject, XMLParserDelegate {
    private struct ParsedPart {
        var id: Int?
        var key = ""
        var duration: Double?
        var file: String?
        var container: String?

        func build() -> PlexProvider.PlexPart {
            PlexProvider.PlexPart(id: id, key: key, duration: duration, file: file, container: container)
        }
    }

    private struct ParsedMedia {
        var duration: Double?
        var container: String?
        var audioCodec: String?
        var parts: [PlexProvider.PlexPart] = []

        func build() -> PlexProvider.PlexMedia {
            PlexProvider.PlexMedia(
                duration: duration,
                container: container,
                audioCodec: audioCodec,
                part: parts.isEmpty ? nil : parts
            )
        }
    }

    private struct ParsedMetadata {
        var ratingKey = ""
        var key = ""
        var parentRatingKey: String?
        var parentTitle: String?
        var grandparentTitle: String?
        var title = ""
        var originalTitle: String?
        var type = ""
        var thumb: String?
        var duration: Double?
        var addedAt: Int64?
        var lastViewedAt: Int64?
        var summary: String?
        var viewOffset: Double?
        var index: Int?
        var parentIndex: Int?
        var media: [PlexProvider.PlexMedia] = []
        var leafCount: Int?
        var viewCount: Int?

        func build() -> PlexProvider.PlexMetadata {
            PlexProvider.PlexMetadata(
                ratingKey: ratingKey,
                key: key,
                parentRatingKey: parentRatingKey,
                parentTitle: parentTitle,
                grandparentTitle: grandparentTitle,
                title: title,
                originalTitle: originalTitle,
                type: type,
                thumb: thumb,
                duration: duration,
                addedAt: addedAt,
                lastViewedAt: lastViewedAt,
                summary: summary,
                viewOffset: viewOffset,
                index: index,
                parentIndex: parentIndex,
                media: media.isEmpty ? nil : media,
                leafCount: leafCount,
                viewCount: viewCount
            )
        }
    }

    private(set) var response = PlexProvider.PlexItemsResponse(metadata: nil, totalSize: nil, size: nil, offset: nil)
    private(set) var parseError: Error?

    private var metadata: [PlexProvider.PlexMetadata] = []
    private var currentMetadata: ParsedMetadata?
    private var currentMedia: ParsedMedia?
    private var currentPart: ParsedPart?
    private var currentItemElementName: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "MediaContainer":
            response = PlexProvider.PlexItemsResponse(
                metadata: nil,
                totalSize: Self.parseInt(attributeDict["totalSize"]),
                size: Self.parseInt(attributeDict["size"]),
                offset: Self.parseInt(attributeDict["offset"])
            )
        case "Directory", "Track", "Video", "Metadata":
            guard let type = attributeDict["type"], type == "album" || type == "track" else { return }
            currentItemElementName = elementName
            currentMetadata = ParsedMetadata(
                ratingKey: attributeDict["ratingKey"] ?? "",
                key: attributeDict["key"] ?? "",
                parentRatingKey: attributeDict["parentRatingKey"],
                parentTitle: attributeDict["parentTitle"],
                grandparentTitle: attributeDict["grandparentTitle"],
                title: attributeDict["title"] ?? "",
                originalTitle: attributeDict["originalTitle"],
                type: type,
                thumb: attributeDict["thumb"],
                duration: Self.parseDouble(attributeDict["duration"]),
                addedAt: Self.parseInt64(attributeDict["addedAt"]),
                lastViewedAt: Self.parseInt64(attributeDict["lastViewedAt"]),
                summary: attributeDict["summary"],
                viewOffset: Self.parseDouble(attributeDict["viewOffset"]),
                index: Self.parseInt(attributeDict["index"]),
                parentIndex: Self.parseInt(attributeDict["parentIndex"]),
                media: [],
                leafCount: Self.parseInt(attributeDict["leafCount"]),
                viewCount: Self.parseInt(attributeDict["viewCount"])
            )
        case "Media":
            currentMedia = ParsedMedia(
                duration: Self.parseDouble(attributeDict["duration"]),
                container: attributeDict["container"],
                audioCodec: attributeDict["audioCodec"],
                parts: []
            )
        case "Part":
            currentPart = ParsedPart(
                id: Self.parseInt(attributeDict["id"]),
                key: attributeDict["key"] ?? "",
                duration: Self.parseDouble(attributeDict["duration"]),
                file: attributeDict["file"],
                container: attributeDict["container"]
            )
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "Part":
            if let part = currentPart {
                currentMedia?.parts.append(part.build())
            }
            currentPart = nil
        case "Media":
            if let media = currentMedia {
                currentMetadata?.media.append(media.build())
            }
            currentMedia = nil
        case let name where name == currentItemElementName:
            if let item = currentMetadata?.build(), !item.ratingKey.isEmpty || !item.key.isEmpty {
                metadata.append(item)
            }
            currentMetadata = nil
            currentMedia = nil
            currentPart = nil
            currentItemElementName = nil
        default:
            break
        }
        response = PlexProvider.PlexItemsResponse(
            metadata: metadata.isEmpty ? nil : metadata,
            totalSize: response.totalSize,
            size: response.size,
            offset: response.offset
        )
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    private static func parseInt(_ value: String?) -> Int? {
        guard let value, !value.isEmpty else { return nil }
        return Int(value)
    }

    private static func parseInt64(_ value: String?) -> Int64? {
        guard let value, !value.isEmpty else { return nil }
        return Int64(value)
    }

    private static func parseDouble(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        return Double(value)
    }
}

private class PlexChapterXMLParserDelegate: NSObject, XMLParserDelegate {
    var chapters: [Chapter] = []
    private var chapterCount = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "Chapter" {
            chapterCount += 1

            var title =
                attributeDict["tag"]
                ?? attributeDict["title"]
                ?? attributeDict["name"]
                ?? ""

            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                title = "Chapter \(chapterCount)"
            }

            let startTimeMs = attributeDict["startTimeOffset"].flatMap { Int64($0) } ?? 0
            let endTimeMs = attributeDict["endTimeOffset"].flatMap { Int64($0) } ?? 0

            let startTime = TimeInterval(startTimeMs) / 1000.0
            let endTime = TimeInterval(endTimeMs) / 1000.0
            let duration = endTime - startTime

            guard startTime >= 0 else {
                AppLogger.network.error("Skipping invalid chapter: start=\(startTime), duration=\(duration)")
                return
            }

            let id = attributeDict["id"] ?? "chapter_\(chapterCount)_\(startTimeMs)"

            let chapter = Chapter(
                id: id,
                start: startTime,
                end: endTime,
                title: title
            )
            chapters.append(chapter)
            AppLogger.network.debug(
                "[PlexChapterParser] Parsed chapter \(chapterCount) start=\(startTime)s end=\(endTime)s"
            )
        }
    }
}

private final class PlexSectionsXMLParserDelegate: NSObject, XMLParserDelegate {
    struct SectionRecord {
        let key: String
        let title: String
        let type: String
    }

    var sections: [SectionRecord] = []
    var parseError: Error?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "Directory" else { return }
        guard let key = attributeDict["key"],
            let title = attributeDict["title"],
            let type = attributeDict["type"]
        else {
            return
        }

        sections.append(SectionRecord(key: key, title: title, type: type))
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}
