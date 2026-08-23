import AVFoundation
import Foundation
import Logging

final class PremiumizeProvider: WholeSnapshotCatalogProvider, PlaybackSessionProvider, @unchecked Sendable {
    var connection: ServerConnection

    var capabilities: ProviderCapabilities {
        [.fullImport, .downloads, .backgroundOperation]
    }

    private let libraryId = "premiumize-cloud"
    private let supportedAudioExtensions: Set<String> = ["mp3", "m4b", "m4a", "mp4", "aac", "flac", "ogg", "opus", "wav"]
    private let selfContainedExtensions: Set<String> = ["m4b", "m4a", "mp4"]

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func listRootEntries() async throws -> [CloudFolderItem] {
        guard let token = connection.token, !token.isEmpty else { return [] }
        let entries = try await listFolder(token: token, folderId: nil)
        return entries.map { entry in
            CloudFolderItem(
                id: entry.id ?? UUID().uuidString,
                name: entry.name,
                isFolder: isFolder(entry),
                path: entry.id ?? entry.name,
                size: entry.size,
                link: entry.link?.isEmpty == false ? entry.link : nil
            )
        }.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func listFolderEntries(folderId: String) async throws -> [CloudFolderItem] {
        guard let token = connection.token, !token.isEmpty else { return [] }
        let entries = try await listFolder(token: token, folderId: folderId)
        return entries.map { entry in
            CloudFolderItem(
                id: entry.id ?? UUID().uuidString,
                name: entry.name,
                isFolder: isFolder(entry),
                path: entry.id ?? entry.name,
                size: entry.size,
                link: entry.link?.isEmpty == false ? entry.link : nil
            )
        }.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func validateConnection() async throws -> Bool {
        guard let token = connection.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }

        let base = normalizedBaseURL()
        guard let url = URL(string: "\(base)/account/info") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderError.unauthorized
        }

        connection.isConnected = true
        connection.lastVerified = Date()
        return true
    }

    func fetchLibraries() async throws -> [Library] {
        [
            Library(
                id: libraryId,
                name: "Premiumize Cloud",
                type: "premiumize",
                providerId: connection.id
            )
        ]
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        guard libraryId == self.libraryId else { return [] }
        guard let token = connection.token, !token.isEmpty else { return [] }

        let files = try await fetchAllAudioFiles(token: token)
        let groupedBooks = groupFilesIntoBooks(files)
        return groupedBooks.map(makeBookSummary).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        let books = try await fetchBooks(libraryId: libraryId)
        return Array(books.prefix(max(0, limit)))
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] { [] }

    func fetchSeries(libraryId: String) async throws -> [Series] { [] }

    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { [] }

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        let books = try await fetchBooks(libraryId: libraryId)
        guard let baseBook = books.first(where: { $0.id == bookId }) else {
            throw ProviderError.invalidResponse
        }

        let resolvedTracks = await resolveTrackDurations(baseBook.audioTracks ?? [])
        let normalizedTracks = normalizeTrackOffsets(resolvedTracks)
        let totalDuration = normalizedTracks.totalDuration
        var chapters = buildChapters(from: normalizedTracks, fallbackTitle: baseBook.title)
        let clampedCurrentTime: TimeInterval
        if totalDuration > 0 {
            clampedCurrentTime = min(baseBook.currentTime, max(totalDuration - 1, 0))
        } else {
            clampedCurrentTime = 0
        }

        if areChaptersInadequate(chapters, bookDuration: totalDuration),
            let firstTrack = normalizedTracks.first,
            let contentUrl = firstTrack.contentUrl,
            let streamURL = URL(string: contentUrl)
        {
            AppLogger.network.info("[Premiumize] Inadequate chapters (\(chapters.count)), attempting embedded chapter extraction...")
            do {
                let extractedChapters = try await extractChaptersFromAudioFile(streamURL: streamURL, bookDuration: totalDuration)
                if !extractedChapters.isEmpty {
                    chapters = normalizeChapters(extractedChapters, bookDuration: totalDuration)
                    AppLogger.network.info("Extracted \(chapters.count) embedded chapters from audio file")
                } else {
                    AppLogger.network.info("No embedded chapters found, using track-based chapters")
                }
            } catch {
                AppLogger.network.error("Chapter extraction failed: \(error.localizedDescription), using track-based chapters")
            }
        }

        var enrichedTitle = baseBook.title
        var enrichedAuthor = baseBook.author
        var enrichedNarrator = baseBook.narrator
        var enrichedDescription = baseBook.description
        var enrichedSeries = baseBook.series
        var enrichedSeriesNumber = baseBook.seriesNumber
        var enrichedPublishedYear = baseBook.publishedYear
        var enrichedGenres = baseBook.genres
        var enrichedPublisher = baseBook.publisher
        var enrichedIsbn = baseBook.isbn
        var enrichedAsin = baseBook.asin

        if enrichedAuthor == nil || enrichedNarrator == nil {
            if let firstTrack = normalizedTracks.first,
                let contentUrl = firstTrack.contentUrl,
                let streamURL = URL(string: contentUrl)
            {
                AppLogger.network.info("[Premiumize] Attempting to extract embedded metadata...")
                do {
                    let embedded = try await FileMetadataExtractor.shared.extractMetadataFromRemoteStream(
                        streamURL: streamURL,
                        timeout: 15.0
                    )
                    if let t = embedded.title, !t.isEmpty, enrichedTitle == baseBook.title { enrichedTitle = t }
                    if let a = embedded.author, !a.isEmpty, enrichedAuthor == nil { enrichedAuthor = a }
                    if let n = embedded.narrator, !n.isEmpty, enrichedNarrator == nil { enrichedNarrator = n }
                    if let d = embedded.description, !d.isEmpty, enrichedDescription == nil { enrichedDescription = d }
                    if let s = embedded.series, !s.isEmpty, enrichedSeries == nil { enrichedSeries = s }
                    if let sn = embedded.seriesNumber, enrichedSeriesNumber == nil { enrichedSeriesNumber = sn }
                    if let y = embedded.year, enrichedPublishedYear == nil { enrichedPublishedYear = y }
                    if let g = embedded.genres, !g.isEmpty, enrichedGenres == nil { enrichedGenres = g }
                    if let p = embedded.publisher, !p.isEmpty, enrichedPublisher == nil { enrichedPublisher = p }
                    if let i = embedded.isbn, !i.isEmpty, enrichedIsbn == nil { enrichedIsbn = i }
                    if let a = embedded.asin, !a.isEmpty, enrichedAsin == nil { enrichedAsin = a }
                    AppLogger.network.info(
                        "Extracted embedded metadata (author=\(enrichedAuthor ?? "nil"), narrator=\(enrichedNarrator ?? "nil"))"
                    )
                } catch {
                    AppLogger.network.error("Metadata extraction failed: \(error.localizedDescription)")
                }
            }
        }

        return Book(
            id: baseBook.id,
            ratingKey: baseBook.ratingKey,
            title: enrichedTitle,
            author: enrichedAuthor,
            narrator: enrichedNarrator,
            thumb: baseBook.thumb,
            partKey: baseBook.partKey,
            duration: totalDuration > 0 ? totalDuration : nil,
            chapters: chapters.isEmpty ? nil : chapters,
            currentChapterIndex: nil,
            source: baseBook.source,
            backendId: baseBook.backendId,
            trackIndex: baseBook.trackIndex,
            filePath: baseBook.filePath,
            audioFileIno: baseBook.audioFileIno,
            audioFileInos: baseBook.audioFileInos,
            audioTracks: normalizedTracks,
            description: enrichedDescription,
            series: enrichedSeries,
            seriesNumber: enrichedSeriesNumber,
            publishedYear: enrichedPublishedYear,
            genres: enrichedGenres,
            publisher: enrichedPublisher,
            isbn: enrichedIsbn,
            asin: enrichedAsin,
            addedAt: baseBook.addedAt,
            libraryName: baseBook.libraryName,
            backendName: baseBook.backendName,
            currentTime: clampedCurrentTime,
            isFinished: baseBook.isFinished,
            lastUpdate: Date(),
            providerId: baseBook.providerId,
            libraryId: baseBook.libraryId
        )
    }

    func getAudioURL(for book: Book) -> URL? {
        if let part = book.partKey, let url = URL(string: part) {
            return url
        }
        return nil
    }

    func getStreamingHeaders() -> [String: String] {
        [:]
    }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        let detailedBook = try await fetchFullBookDetails(bookId: book.id, libraryId: book.libraryId)
        let tracks = (detailedBook.audioTracks ?? []).compactMap { track -> AudioTrackInfo? in
            let content = track.contentUrl ?? detailedBook.partKey
            guard let content else { return nil }
            return AudioTrackInfo(
                index: track.index,
                startOffset: track.startOffset,
                duration: track.duration,
                contentUrl: content,
                mimeType: mimeType(for: content)
            )
        }

        guard !tracks.isEmpty else {
            throw ProviderError.invalidURL
        }

        let chapters =
            detailedBook.chapters ?? [
                Chapter(id: "full_book", start: 0, end: max(tracks.totalDuration, 1), title: detailedBook.title, index: 0)
            ]

        return PlaybackSessionInfo(sessionId: UUID().uuidString, audioTracks: tracks, chapters: chapters)
    }

    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
        AppLogger.sync.debug(
            "Progress sync not supported for Premiumize bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)); progress is local-only"
        )
    }

    private func normalizedBaseURL() -> String {
        let trimmed = connection.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "https://www.premiumize.me/api" }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func fetchAllAudioFiles(token: String) async throws -> [PremiumizeFile] {
        let startFolderId: String? = connection.rootPath
        var queue: [(id: String?, name: String)] = [(startFolderId, "")]
        var visitedFolderIds = Set<String>()
        var allAudioFiles: [PremiumizeFile] = []

        while !queue.isEmpty {
            let current = queue.removeLast()
            let entries = try await listFolder(token: token, folderId: current.id)

            for entry in entries {
                if isFolder(entry), let id = entry.id, !visitedFolderIds.contains(id) {
                    visitedFolderIds.insert(id)
                    queue.append((id: id, name: entry.name))
                    continue
                }

                guard let link = entry.link, !link.isEmpty, isAudioFile(named: entry.name) else { continue }
                let tagged = PremiumizeFile(
                    id: entry.id,
                    name: entry.name,
                    link: entry.link,
                    path: current.id.map { "folder/\($0)/\(entry.name)" } ?? entry.path,
                    parentFolderId: current.id,
                    parentFolderName: current.id != nil ? current.name : nil,
                    type: entry.type,
                    size: entry.size
                )
                allAudioFiles.append(tagged)
            }
        }

        return allAudioFiles
    }

    private func listFolder(token: String, folderId: String?) async throws -> [PremiumizeFile] {
        let base = normalizedBaseURL()
        guard var components = URLComponents(string: "\(base)/folder/list") else { return [] }
        if let folderId, !folderId.isEmpty {
            components.queryItems = [URLQueryItem(name: "id", value: folderId)]
        }

        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return []
        }

        let payload = try? JSONDecoder().decode(PremiumizeFolderResponse.self, from: data)
        return payload?.content ?? []
    }

    private func isFolder(_ file: PremiumizeFile) -> Bool {
        if let type = file.type?.lowercased(), type.contains("folder") {
            return true
        }
        return file.link == nil || file.link?.isEmpty == true
    }

    private func isAudioFile(named name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return supportedAudioExtensions.contains(ext)
    }

    private func isSelfContainedFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return selfContainedExtensions.contains(ext)
    }

    private func groupFilesIntoBooks(_ files: [PremiumizeFile]) -> [PremiumizeBookGroup] {
        var grouped: [String: [PremiumizeFile]] = [:]

        for file in files {
            let key = groupKey(for: file)
            grouped[key, default: []].append(file)
        }

        var results: [PremiumizeBookGroup] = []

        for (key, groupFiles) in grouped {
            let sortedFiles = groupFiles.sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

            let title = titleForGroup(key: key, files: sortedFiles)
            let folderPath = folderPathForGroup(key: key)

            let selfContainedFiles = sortedFiles.filter { isSelfContainedFile($0.name) }
            let partFiles = sortedFiles.filter { !isSelfContainedFile($0.name) }

            if selfContainedFiles.count > 1 && partFiles.isEmpty {
                for file in selfContainedFiles {
                    let singleKey = "\(key)|single:\(trackId(for: file, fallbackIndex: 0))"
                    results.append(
                        PremiumizeBookGroup(
                            key: singleKey,
                            title: trackTitle(from: file.name),
                            folderPath: file.path,
                            files: [file]
                        )
                    )
                }
            } else if !selfContainedFiles.isEmpty && !partFiles.isEmpty {
                for file in selfContainedFiles {
                    let singleKey = "\(key)|single:\(trackId(for: file, fallbackIndex: 0))"
                    results.append(
                        PremiumizeBookGroup(
                            key: singleKey,
                            title: trackTitle(from: file.name),
                            folderPath: file.path,
                            files: [file]
                        )
                    )
                }
                let partKey = "\(key)|parts"
                results.append(
                    PremiumizeBookGroup(
                        key: partKey,
                        title: title,
                        folderPath: folderPath,
                        files: partFiles
                    )
                )
            } else {
                results.append(
                    PremiumizeBookGroup(
                        key: key,
                        title: title,
                        folderPath: folderPath,
                        files: sortedFiles
                    )
                )
            }
        }

        return results
    }

    private func makeBookSummary(group: PremiumizeBookGroup) -> Book {
        let tracks = group.files.enumerated().map { index, file in
            AudioTrack(
                id: trackId(for: file, fallbackIndex: index),
                index: index,
                title: trackTitle(from: file.name),
                filePath: file.path,
                contentUrl: file.link ?? "",
                duration: 0,
                startOffset: 0,
                fileSize: file.size,
                format: (file.name as NSString).pathExtension.lowercased()
            )
        }

        let stableGroupId = stableKey("pm|\(connection.id.uuidString)|\(group.key)")
        let bookId = "premiumize-\(stableGroupId)"

        return Book(
            id: bookId,
            ratingKey: bookId,
            title: group.title,
            author: nil,
            narrator: nil,
            thumb: nil,
            partKey: group.files.first?.link ?? nil,
            duration: nil,
            chapters: nil,
            currentChapterIndex: nil,
            source: .webdav,
            backendId: connection.id.uuidString,
            trackIndex: 0,
            filePath: group.folderPath,
            audioFileIno: nil,
            audioFileInos: nil,
            audioTracks: tracks,
            description: nil,
            series: nil,
            seriesNumber: nil,
            publishedYear: nil,
            genres: nil,
            publisher: nil,
            isbn: nil,
            asin: nil,
            addedAt: nil,
            libraryName: "Premiumize Cloud",
            backendName: connection.name,
            currentTime: 0,
            isFinished: false,
            lastUpdate: Date(),
            providerId: connection.id,
            libraryId: self.libraryId
        )
    }

    private func resolveTrackDurations(_ tracks: [AudioTrack]) async -> [AudioTrack] {
        guard !tracks.isEmpty else { return [] }

        var resolved: [AudioTrack] = []
        resolved.reserveCapacity(tracks.count)

        for track in tracks.sorted(by: { $0.index < $1.index }) {
            let resolvedDuration: TimeInterval = await {
                guard let contentUrl = track.contentUrl,
                    let url = URL(string: contentUrl)
                else {
                    return track.duration
                }

                let asset = AVURLAsset(url: url)
                do {
                    let cmDuration = try await asset.load(.duration)
                    let seconds = CMTimeGetSeconds(cmDuration)
                    if seconds.isFinite, seconds > 0 {
                        return seconds
                    }
                } catch {
                    AppLogger.network.debug("Premiumize asset duration probe failed: \(error.localizedDescription)")
                }
                return track.duration
            }()

            resolved.append(
                AudioTrack(
                    id: track.id,
                    index: track.index,
                    title: track.title,
                    filePath: track.filePath,
                    contentUrl: track.contentUrl,
                    duration: resolvedDuration,
                    startOffset: track.startOffset,
                    fileSize: track.fileSize,
                    format: track.format,
                    bitrate: track.bitrate,
                    sampleRate: track.sampleRate,
                    channels: track.channels
                )
            )
        }

        return resolved
    }

    private func normalizeTrackOffsets(_ tracks: [AudioTrack]) -> [AudioTrack] {
        var cumulative: TimeInterval = 0
        return tracks.sorted(by: { $0.index < $1.index }).map { track in
            let normalized = AudioTrack(
                id: track.id,
                index: track.index,
                title: track.title,
                filePath: track.filePath,
                contentUrl: track.contentUrl,
                duration: track.duration,
                startOffset: cumulative,
                fileSize: track.fileSize,
                format: track.format,
                bitrate: track.bitrate,
                sampleRate: track.sampleRate,
                channels: track.channels
            )
            cumulative += max(track.duration, 0)
            return normalized
        }
    }

    private func buildChapters(from tracks: [AudioTrack], fallbackTitle: String) -> [Chapter] {
        guard !tracks.isEmpty else { return [] }

        return tracks.enumerated().map { index, track in
            let chapterTitle = track.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeTitle = chapterTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter \(index + 1)"
            let end = track.startOffset + max(track.duration, 1)
            return Chapter(
                id: "\(track.id)-chapter",
                start: track.startOffset,
                end: end,
                title: safeTitle == fallbackTitle ? "Chapter \(index + 1)" : safeTitle,
                index: index
            )
        }
    }

    private func areChaptersInadequate(_ chapters: [Chapter], bookDuration: Double) -> Bool {
        if chapters.isEmpty && bookDuration > 0 {
            return true
        }
        if chapters.count == 1 && bookDuration > 1800 {
            return true
        }
        return false
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
                    title: title,
                    index: index
                )
                extractedChapters.append(chapter)
            }

            if !extractedChapters.isEmpty {
                break
            }
        }

        return extractedChapters
    }

    private func normalizeChapters(_ chapters: [Chapter], bookDuration: Double?) -> [Chapter] {
        guard !chapters.isEmpty else { return [] }
        let sorted = chapters.sorted { $0.start < $1.start }

        var normalized: [Chapter] = []
        normalized.reserveCapacity(sorted.count)
        var seenIds = Set<String>()

        for (index, chapter) in sorted.enumerated() {
            let nextStart = (index + 1 < sorted.count) ? sorted[index + 1].start : (bookDuration ?? chapter.end)

            var end = chapter.end
            if end <= chapter.start || end == 0 {
                end = nextStart
            }

            var id = chapter.id
            if id.isEmpty || seenIds.contains(id) {
                id = "pm-ch-\(index)"
            }
            seenIds.insert(id)

            normalized.append(Chapter(id: id, start: chapter.start, end: end, title: chapter.title, index: index))
        }

        return normalized
    }

    private func groupKey(for file: PremiumizeFile) -> String {
        if let folderId = file.parentFolderId, !folderId.isEmpty {
            return "folder:\(folderId)"
        }

        if let path = file.path, !path.isEmpty {
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty, parent != ".", parent != "/" {
                return "folder:\(parent.lowercased())"
            }
        }

        let baseName = (file.name as NSString).deletingPathExtension
        if !baseName.isEmpty {
            return "file:\(baseName.lowercased())"
        }
        return "file:\(stableKey(file.link ?? file.name))"
    }

    private func titleForGroup(key: String, files: [PremiumizeFile]) -> String {
        if key.hasPrefix("folder:") {
            if let first = files.first, let folderName = first.parentFolderName, !folderName.isEmpty {
                return folderName
            }
            if let folder = folderPathForGroup(key: key), !folder.isEmpty {
                let name = (folder as NSString).lastPathComponent
                if !name.isEmpty { return name }
            }
        }

        if let first = files.first {
            let name = (first.name as NSString).deletingPathExtension
            if !name.isEmpty { return name }
            if !first.name.isEmpty { return first.name }
        }

        return "Premiumize Book"
    }

    private func folderPathForGroup(key: String) -> String? {
        guard key.hasPrefix("folder:") else { return nil }
        return String(key.dropFirst("folder:".count))
    }

    private func trackId(for file: PremiumizeFile, fallbackIndex: Int) -> String {
        if let id = file.id, !id.isEmpty { return "pm-track-\(id)" }
        if let path = file.path, !path.isEmpty { return "pm-track-\(stableKey(path))" }
        if let link = file.link, !link.isEmpty { return "pm-track-\(stableKey(link))" }
        return "pm-track-\(fallbackIndex)"
    }

    private func trackTitle(from fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? fileName : base
    }

    private func mimeType(for contentUrl: String) -> String {
        let ext = (URL(string: contentUrl)?.pathExtension.lowercased() ?? "")
        switch ext {
        case "m4b": return "audio/mp4"
        case "m4a": return "audio/mp4"
        case "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "opus": return "audio/ogg"
        case "wav": return "audio/wav"
        default: return "audio/mpeg"
        }
    }

    private func stableKey(_ input: String) -> String {
        var value: Int64 = 5381
        for scalar in input.unicodeScalars {
            value = ((value << 5) &+ value) &+ Int64(scalar.value)
        }
        return String(abs(value))
    }
}

private struct PremiumizeFolderResponse: Decodable {
    let content: [PremiumizeFile]?
}

private struct PremiumizeFile: Decodable {
    let id: String?
    let name: String
    let link: String?
    let path: String?
    let parentFolderId: String?
    let parentFolderName: String?
    let type: String?
    let size: Int64?

    init(
        id: String?,
        name: String,
        link: String?,
        path: String?,
        parentFolderId: String? = nil,
        parentFolderName: String? = nil,
        type: String?,
        size: Int64?
    ) {
        self.id = id
        self.name = name
        self.link = link
        self.path = path
        self.parentFolderId = parentFolderId
        self.parentFolderName = parentFolderName
        self.type = type
        self.size = size
    }

    enum CodingKeys: String, CodingKey {
        case id, name, link, path, type, size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.link = try container.decodeIfPresent(String.self, forKey: .link)
        self.path = try container.decodeIfPresent(String.self, forKey: .path)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.size = try container.decodeIfPresent(Int64.self, forKey: .size)
        self.parentFolderId = nil
        self.parentFolderName = nil
    }
}

private struct PremiumizeBookGroup {
    let key: String
    let title: String
    let folderPath: String?
    let files: [PremiumizeFile]
}
