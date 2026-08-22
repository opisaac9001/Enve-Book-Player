import AVFoundation
import Foundation
import Logging

private struct CachedUnrestrictedLink {
    let link: RDUnrestrictedLink
    let cachedAt: Date
    var isExpired: Bool { Date().timeIntervalSince(cachedAt) > 86_400 }
}

final class RealDebridProvider: WholeSnapshotCatalogProvider, PlaybackSessionProvider, @unchecked Sendable {
    private var unrestrictedLinkCache: [String: CachedUnrestrictedLink] = [:]
    var connection: ServerConnection

    var capabilities: ProviderCapabilities {
        [.fullImport, .downloads, .backgroundOperation]
    }

    private let libraryId = "realdebrid-downloads"
    private let supportedAudioExtensions: Set<String> = ["mp3", "m4b", "m4a", "mp4", "aac", "flac", "ogg", "opus", "wav"]
    private let selfContainedExtensions: Set<String> = ["m4b", "m4a", "mp4"]
    private let archiveExtensions: Set<String> = ["rar", "zip", "7z"]

    init(connection: ServerConnection) {
        self.connection = connection
    }

    private func endpointURL(path: String) throws -> URL {
        let base = normalizedBaseURL()
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: base + normalizedPath) else {
            throw ProviderError.invalidURL
        }
        return url
    }

    private func authorizedRequest(url: URL) throws -> URLRequest {
        guard let token = connection.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    func validateConnection() async throws -> Bool {
        let request = try authorizedRequest(url: endpointURL(path: "/user"))

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
                name: "Real-Debrid Downloads",
                type: "realdebrid",
                providerId: connection.id
            )
        ]
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        guard libraryId == self.libraryId else { return [] }
        guard let token = connection.token, !token.isEmpty else { return [] }

        let allFiles = try await fetchAllAudioFiles()
        let groupedBooks = groupFilesIntoBooks(allFiles)
        return groupedBooks.map(makeBookSummary).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
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
            let streamURL = URL(string: contentUrl),
            !isArchiveURL(contentUrl)
        {
            AppLogger.network.info("[RealDebrid] Inadequate chapters (\(chapters.count)), attempting embedded chapter extraction...")
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
                let streamURL = URL(string: contentUrl),
                !isArchiveURL(contentUrl)
            {
                AppLogger.network.info("[RealDebrid] Attempting to extract embedded metadata...")
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
        let detailedBook =
            if canStartPlaybackDirectly(from: book) {
                book
            } else {
                try await fetchFullBookDetails(bookId: book.id, libraryId: book.libraryId)
            }

        let archiveTracks = (detailedBook.audioTracks ?? []).compactMap { track -> String? in
            guard let contentUrl = track.contentUrl,
                isArchiveURL(contentUrl)
            else { return nil }
            return contentUrl
        }

        if !archiveTracks.isEmpty {
            throw ProviderError.serverError("This Real-Debrid item is packaged in an archive and must be downloaded before playback.")
        }

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
            "Progress sync not supported for Real-Debrid bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)); progress is local-only"
        )
    }

    func listRootEntries() async throws -> [CloudFolderItem] {
        var items: [CloudFolderItem] = []

        let torrents = try await fetchTorrents()
        for torrent in torrents {
            items.append(
                CloudFolderItem(
                    id: "torrent-\(torrent.id)",
                    name: torrent.filename,
                    isFolder: true,
                    path: "/torrents/\(torrent.id)",
                    size: torrent.bytes,
                    link: nil
                )
            )
        }

        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func listFolderEntries(path: String) async throws -> [CloudFolderItem] {
        guard path.hasPrefix("/torrents/") else { return [] }
        let torrentId = String(path.dropFirst("/torrents/".count))

        let info = try await fetchTorrentInfo(id: torrentId)
        var items: [CloudFolderItem] = []

        var folderPaths = Set<String>()
        for file in info.files {
            let filePath = file.path
            let components = filePath.split(separator: "/").map(String.init)

            if components.count > 1 {
                let folderName = components[0]
                if !folderPaths.contains(folderName) {
                    folderPaths.insert(folderName)
                    items.append(
                        CloudFolderItem(
                            id: "folder-\(torrentId)-\(folderName)",
                            name: folderName,
                            isFolder: true,
                            path: "\(path)/\(folderName)",
                            size: nil,
                            link: nil
                        )
                    )
                }
            } else {
                let selectedLink = info.links.indices.contains(file.id - 1) ? info.links[file.id - 1] : nil
                items.append(
                    CloudFolderItem(
                        id: "file-\(torrentId)-\(file.id)",
                        name: (filePath as NSString).lastPathComponent,
                        isFolder: false,
                        path: "\(path)/\(filePath)",
                        size: file.bytes,
                        link: selectedLink
                    )
                )
            }
        }

        return items.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func fetchTorrents() async throws -> [RealDebridTorrent] {
        let request = try authorizedRequest(url: endpointURL(path: "/torrents"))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return []
        }
        return (try? JSONDecoder().decode([RealDebridTorrent].self, from: data)) ?? []
    }

    private func fetchTorrentInfo(id: String) async throws -> RealDebridTorrentInfo {
        let request = try authorizedRequest(url: endpointURL(path: "/torrents/info/\(id)"))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProviderError.invalidResponse
        }
        return try JSONDecoder().decode(RealDebridTorrentInfo.self, from: data)
    }

    private func fetchDownloads() async throws -> [RealDebridDownload] {
        let request = try authorizedRequest(url: endpointURL(path: "/downloads"))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return []
        }
        return (try? JSONDecoder().decode([RealDebridDownload].self, from: data)) ?? []
    }

    private func fetchAllAudioFiles() async throws -> [RDFileEntry] {
        var allAudioFiles: [RDFileEntry] = []
        let rootPath = connection.rootPath

        let torrents = try await fetchTorrents()
        for torrent in torrents {
            if let rootPath, rootPath.hasPrefix("/torrents/") {
                let selectedId = String(rootPath.dropFirst("/torrents/".count))
                if torrent.id != selectedId { continue }
            }

            do {
                let info = try await fetchTorrentInfo(id: torrent.id)

                let selectedFiles = info.files.filter { $0.selected == 1 }
                var audioEntries: [(file: RealDebridTorrentFile, entry: RDFileEntry)] = []

                for file in selectedFiles {
                    let fileName = (file.path as NSString).lastPathComponent
                    guard isAudioFile(named: fileName) else { continue }
                    let groupingFolder = groupingFolderName(for: file.path) ?? torrent.filename

                    audioEntries.append(
                        (
                            file: file,
                            entry: RDFileEntry(
                                id: "rd-\(torrent.id)-\(file.id)",
                                name: fileName,
                                path: "/torrents/\(torrent.id)/\(file.path)",
                                parentFolder: groupingFolder,
                                link: "",
                                size: file.bytes
                            )
                        )
                    )
                }

                guard !audioEntries.isEmpty else { continue }

                var resolvedAudioURLs: [String: String] = [:]
                var archiveURL: String? = nil

                for restrictedLink in info.links {
                    guard let resolved = await unrestrictLink(restrictedLink) else { continue }
                    let resolvedName = resolved.filename.lowercased()

                    if isAudioFile(named: resolved.filename) {
                        resolvedAudioURLs[resolvedName] = resolved.download
                        AppLogger.network.debug(
                            "Linked audio fileId=\(DiagnosticLogSanitizer.identifier(for: resolved.filename))"
                        )
                    } else {
                        let ext = (resolved.filename as NSString).pathExtension.lowercased()
                        if ext == "rar" || ext == "zip" || ext == "7z" {
                            AppLogger.network.debug(
                                "TorrentId=\(DiagnosticLogSanitizer.identifier(for: torrent.filename)) has archiveId=\(DiagnosticLogSanitizer.identifier(for: resolved.filename))"
                            )
                            archiveURL = resolved.download
                        }
                    }
                }

                for i in 0..<audioEntries.count {
                    let entry = audioEntries[i].entry
                    let lowered = entry.name.lowercased()

                    if let directURL = resolvedAudioURLs[lowered], !directURL.isEmpty {
                        audioEntries[i] = (
                            audioEntries[i].file,
                            RDFileEntry(
                                id: entry.id,
                                name: entry.name,
                                path: entry.path,
                                parentFolder: entry.parentFolder,
                                link: directURL,
                                size: entry.size
                            )
                        )
                    } else if let archiveURL {
                        audioEntries[i] = (
                            audioEntries[i].file,
                            RDFileEntry(
                                id: entry.id,
                                name: entry.name,
                                path: entry.path,
                                parentFolder: entry.parentFolder,
                                link: archiveURL,
                                size: entry.size
                            )
                        )
                    }
                }

                allAudioFiles.append(contentsOf: audioEntries.map(\.entry))

            } catch {
                continue
            }
        }

        if rootPath == nil {
            let downloads = try await fetchDownloads()
            for item in downloads {
                guard let link = item.download, !link.isEmpty else { continue }
                guard isAudioFile(named: item.filename) else { continue }

                allAudioFiles.append(
                    RDFileEntry(
                        id: "rd-dl-\(item.id)",
                        name: item.filename,
                        path: "/downloads/\(item.filename)",
                        parentFolder: nil,
                        link: link,
                        size: nil
                    )
                )
            }
        }

        AppLogger.network.info("Discovered \(allAudioFiles.count) audio files")
        return allAudioFiles
    }

    private func unrestrictLink(_ restrictedLink: String) async -> RDUnrestrictedLink? {
        if let cached = unrestrictedLinkCache[restrictedLink], !cached.isExpired {
            return cached.link
        }
        do {
            let url = try endpointURL(path: "/unrestrict/link")
            var request = try authorizedRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let encoded = restrictedLink.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? restrictedLink
            request.httpBody = "link=\(encoded)".data(using: .utf8)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let result = try JSONDecoder().decode(RDUnrestrictedLink.self, from: data)
            unrestrictedLinkCache[restrictedLink] = CachedUnrestrictedLink(link: result, cachedAt: Date())
            return result
        } catch {
            AppLogger.network.error("Failed to unrestrict link: \(error.localizedDescription)")
            return nil
        }
    }

    private func groupFilesIntoBooks(_ files: [RDFileEntry]) -> [RDBookGroup] {
        var grouped: [String: [RDFileEntry]] = [:]

        for file in files {
            let key = groupKey(for: file)
            grouped[key, default: []].append(file)
        }

        return grouped.map { key, groupFiles in
            let sortedFiles = groupFiles.sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            let title = titleForGroup(key: key, files: sortedFiles)
            let folderPath = folderPathForGroup(key: key)
            return RDBookGroup(key: key, title: title, folderPath: folderPath, files: sortedFiles)
        }
    }

    private func makeBookSummary(group: RDBookGroup) -> Book {
        let tracks = group.files.enumerated().map { index, file in
            AudioTrack(
                id: file.id,
                index: index,
                title: trackTitle(from: file.name),
                filePath: file.path,
                contentUrl: file.link,
                duration: 0,
                startOffset: 0,
                fileSize: file.size,
                format: (file.name as NSString).pathExtension.lowercased()
            )
        }

        let stableGroupId = stableKey("rd|\(connection.id.uuidString)|\(group.key)")
        let bookId = "realdebrid-\(stableGroupId)"

        return Book(
            id: bookId,
            ratingKey: bookId,
            title: group.title,
            author: nil,
            narrator: nil,
            thumb: nil,
            partKey: group.files.first?.link,
            duration: nil,
            chapters: nil,
            currentChapterIndex: nil,
            source: .realdebrid,
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
            libraryName: "Real-Debrid Downloads",
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
                    let url = URL(string: contentUrl),
                    !isArchiveURL(contentUrl)
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
                    AppLogger.network.debug("RealDebrid asset duration probe failed: \(error.localizedDescription)")
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
        if chapters.isEmpty && bookDuration > 0 { return true }
        if chapters.count == 1 && bookDuration > 1800 { return true }
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

                extractedChapters.append(
                    Chapter(
                        id: String(index),
                        start: chapterStartTime,
                        end: chapterEndTime,
                        title: title,
                        index: index
                    )
                )
            }

            if !extractedChapters.isEmpty { break }
        }

        return extractedChapters
    }

    private func normalizeChapters(_ chapters: [Chapter], bookDuration: Double?) -> [Chapter] {
        guard !chapters.isEmpty else { return [] }
        let sorted = chapters.sorted { $0.start < $1.start }
        return sorted.enumerated().map { index, chapter in
            let end: TimeInterval
            if chapter.end > chapter.start {
                end = chapter.end
            } else if index + 1 < sorted.count {
                end = sorted[index + 1].start
            } else {
                end = bookDuration ?? chapter.start + 1
            }
            return Chapter(
                id: chapter.id,
                start: chapter.start,
                end: end,
                title: chapter.title,
                index: index
            )
        }
    }

    private func isAudioFile(named name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return supportedAudioExtensions.contains(ext)
    }

    private func groupKey(for file: RDFileEntry) -> String {
        if let parent = file.parentFolder, !parent.isEmpty {
            return "folder:\(parent.lowercased())"
        }

        let baseName = (file.name as NSString).deletingPathExtension
        if !baseName.isEmpty {
            return "file:\(baseName.lowercased())"
        }
        return "file:\(stableKey(file.link))"
    }

    private func titleForGroup(key: String, files: [RDFileEntry]) -> String {
        if let folderName = files.first?.parentFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
            !folderName.isEmpty
        {
            return folderName
        }

        if let first = files.first {
            let name = (first.name as NSString).deletingPathExtension
            if !name.isEmpty { return name }
            if !first.name.isEmpty { return first.name }
        }

        return "Real-Debrid Book"
    }

    private func folderPathForGroup(key: String) -> String? {
        guard key.hasPrefix("folder:") else { return nil }
        return String(key.dropFirst("folder:".count))
    }

    private func groupingFolderName(for relativePath: String) -> String? {
        let normalized = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let directory = (normalized as NSString).deletingLastPathComponent
        guard !directory.isEmpty, directory != "." else { return nil }
        return (directory as NSString).lastPathComponent
    }

    private func isArchiveURL(_ contentUrl: String) -> Bool {
        guard let url = URL(string: contentUrl) else { return false }
        return archiveExtensions.contains(url.pathExtension.lowercased())
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
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "opus": return "audio/ogg"
        case "wav": return "audio/wav"
        default: return "audio/mpeg"
        }
    }

    private func canStartPlaybackDirectly(from book: Book) -> Bool {
        guard let tracks = book.audioTracks, !tracks.isEmpty else { return false }
        guard tracks.allSatisfy({ ($0.contentUrl?.isEmpty == false) }) else { return false }
        guard
            !tracks.contains(where: { track in
                guard let contentUrl = track.contentUrl else { return false }
                return isArchiveURL(contentUrl)
            })
        else { return false }
        guard let duration = book.duration, duration > 0 else { return false }
        guard let chapters = book.chapters, !chapters.isEmpty else { return false }
        return true
    }

    private func normalizedBaseURL() -> String {
        let trimmed = connection.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "https://api.real-debrid.com/rest/1.0" }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func stableKey(_ input: String) -> String {
        var value: Int64 = 5381
        for scalar in input.unicodeScalars {
            value = ((value << 5) &+ value) &+ Int64(scalar.value)
        }
        return String(abs(value))
    }
}

private struct RealDebridDownload: Decodable {
    let id: Int
    let filename: String
    let download: String?
}

private struct RDUnrestrictedLink: Decodable {
    let id: String
    let filename: String
    let download: String
    let filesize: Int64?
}

struct RealDebridTorrent: Decodable {
    let id: String
    let filename: String
    let bytes: Int64
    let status: String
    let links: [String]?
}

struct RealDebridTorrentInfo: Decodable {
    let id: String
    let filename: String
    let bytes: Int64
    let files: [RealDebridTorrentFile]
    let links: [String]
    let status: String
}

struct RealDebridTorrentFile: Decodable {
    let id: Int
    let path: String
    let bytes: Int64
    let selected: Int
}

struct CloudFolderItem: Identifiable {
    let id: String
    let name: String
    let isFolder: Bool
    let path: String
    let size: Int64?
    let link: String?
}

private struct RDFileEntry {
    let id: String
    let name: String
    let path: String
    let parentFolder: String?
    let link: String
    let size: Int64?
}

private struct RDBookGroup {
    let key: String
    let title: String
    let folderPath: String?
    let files: [RDFileEntry]
}
