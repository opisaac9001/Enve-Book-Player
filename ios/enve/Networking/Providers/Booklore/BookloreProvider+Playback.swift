import AVFoundation
import Foundation
import Logging

extension BookloreProvider {
    private func mediaURL(path: String) -> URL? {
        let base = normalize(connection.url)
        guard var components = URLComponents(string: "\(base)\(path)") else {
            return nil
        }
        if let token = connection.token, !token.isEmpty {
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name == "token" }
            queryItems.append(URLQueryItem(name: "token", value: token))
            components.queryItems = queryItems
        }
        return components.url
    }

    func getAudioURL(for book: Book) -> URL? {
        mediaURL(path: "/api/v1/audiobooks/\(grimmoryNumericId(book))/stream")
    }

    func getAudioTrackURL(for book: Book, trackIndex: Int) -> URL? {
        mediaURL(path: "/api/v1/audiobooks/\(grimmoryNumericId(book))/track/\(trackIndex)/stream")
    }

    func getStreamingHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        if let customHeaders = connection.customHeaders {
            for (key, value) in customHeaders {
                headers[key] = value
            }
        }
        return headers
    }

    private func fetchBookDetailForPlayback(bookId: String) async -> BookloreBookDetail? {
        if let request = try? makeRequest(path: "/api/v1/app/books/\(bookId)"),
            let (data, response) = try? await performAuthorizedRequest(request),
            response.statusCode == 200,
            let detail = try? JSONDecoder().decode(BookloreBookDetail.self, from: data)
        {
            return detail
        }

        if let request = try? makeRequest(path: "/api/v1/books/\(bookId)"),
            let (data, response) = try? await performAuthorizedRequest(request),
            response.statusCode == 200,
            let detail = try? JSONDecoder().decode(BookloreBookDetail.self, from: data)
        {
            return detail
        }

        return nil
    }

    private func isLikelyAudioFile(_ file: BookloreBookFile) -> Bool {
        let ext = (file.fileExtension ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["mp3", "m4a", "m4b", "mp4", "aac", "flac", "ogg", "oga", "opus", "wav"].contains(ext) {
            return true
        }
        let type = (file.bookType ?? "").lowercased()
        return type.contains("audio") || type.contains("audiobook")
    }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        let mapping = try await playbackClient.fetchMapping(
            bookId: grimmoryNumericId(book)
        ) { index in
            getAudioTrackURL(for: book, trackIndex: index)
        }
        var tracks = mapping?.tracks ?? []
        var chapters = mapping?.chapters ?? []
        var serverDuration = mapping?.duration ?? 0
        let infoBookFileId = mapping?.bookFileId

        if tracks.count <= 1,
            let detail = await fetchBookDetailForPlayback(bookId: grimmoryNumericId(book))
        {
            if let fileId = (detail.files?.first(where: { $0.isPrimary == true }) ?? detail.files?.first)?.id?.stringValue,
                let intId = Int(fileId), intId > 0
            {
                progressClient.cacheAudiobookFileId(intId, for: book.id)
            }

            let detailDuration = detail.durationSeconds.map(Double.init) ?? detail.duration ?? 0
            let totalDuration = max(serverDuration, detailDuration)
            let audioFiles = (detail.files ?? []).filter { isLikelyAudioFile($0) }

            if audioFiles.count > 1 {
                let sortedFiles = audioFiles.sorted { lhs, rhs in
                    let l = lhs.fileName ?? ""
                    let r = rhs.fileName ?? ""
                    return l.localizedStandardCompare(r) == .orderedAscending
                }

                let fallbackPerTrackDuration =
                    totalDuration > 0
                    ? totalDuration / Double(sortedFiles.count)
                    : 3600

                var rebuiltTracks: [AudioTrackInfo] = []
                var rebuiltChapters: [Chapter] = []
                var offset: Double = 0

                for (index, file) in sortedFiles.enumerated() {
                    guard let streamURL = getAudioTrackURL(for: book, trackIndex: index)?.absoluteString,
                        !streamURL.isEmpty
                    else {
                        continue
                    }

                    let title =
                        file.fileName.map {
                            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                        } ?? "Chapter \(index + 1)"

                    rebuiltTracks.append(
                        AudioTrackInfo(
                            index: index,
                            startOffset: offset,
                            duration: fallbackPerTrackDuration,
                            contentUrl: streamURL,
                            mimeType: AudiobookFormat.streamingMimeType(forFileExtension: file.fileExtension),
                            title: title
                        )
                    )

                    if chapters.isEmpty {
                        rebuiltChapters.append(
                            Chapter(
                                id: "grimmory_file_\(index)",
                                start: offset,
                                end: offset + fallbackPerTrackDuration,
                                title: title,
                                index: index
                            )
                        )
                    }

                    offset += fallbackPerTrackDuration
                }

                if !rebuiltTracks.isEmpty {
                    tracks = rebuiltTracks
                    if chapters.isEmpty {
                        chapters = rebuiltChapters
                    }
                    if serverDuration <= 0 {
                        serverDuration = totalDuration
                    }
                }
            }

            let hasFolderBasedFile = (detail.files ?? []).contains { $0.folderBased == true }
            if tracks.count <= 1, hasFolderBasedFile,
                let probed = await probeMultiTrackURLs(for: book)
            {
                var probedTracks: [AudioTrackInfo] = []
                var probedChapters: [Chapter] = []
                var offset: Double = 0
                for (index, entry) in probed.enumerated() {
                    let title = "Track \(index + 1)"
                    probedTracks.append(
                        AudioTrackInfo(
                            index: index,
                            startOffset: offset,
                            duration: entry.duration,
                            contentUrl: entry.url.absoluteString,
                            mimeType: entry.mimeType,
                            title: title
                        )
                    )
                    if chapters.isEmpty {
                        probedChapters.append(
                            Chapter(
                                id: "grimmory_probe_\(index)",
                                start: offset,
                                end: offset + entry.duration,
                                title: title,
                                index: index
                            )
                        )
                    }
                    offset += entry.duration
                }
                if !probedTracks.isEmpty {
                    tracks = probedTracks
                    if chapters.isEmpty { chapters = probedChapters }
                    if serverDuration <= 0 { serverDuration = offset }
                }
            }
        }

        if tracks.isEmpty {
            let url = getAudioURL(for: book)?.absoluteString ?? ""
            tracks.append(
                AudioTrackInfo(
                    index: 0,
                    startOffset: 0,
                    duration: serverDuration,
                    contentUrl: url,
                    mimeType: "audio/mp4"
                )
            )
        }

        AppLogger.network.info(
            "[Booklore] Playback session: \(tracks.count) track(s), \(chapters.count) chapter(s), duration: \(serverDuration)s"
        )
        if let fileId = infoBookFileId, fileId > 0 {
            progressClient.cacheAudiobookFileId(fileId, for: book.id)
        }

        let resolvedBookFileId = progressClient.cachedAudiobookFileId(for: book.id) ?? Int(grimmoryNumericId(book)) ?? 0
        return PlaybackSessionInfo(
            sessionId: "grimmory_\(grimmoryNumericId(book))_\(resolvedBookFileId)",
            audioTracks: tracks,
            chapters: chapters,

            serverCurrentTime: nil
        )
    }

    func fetchAudiobookDownloadTracks(for book: Book) async -> [(url: URL, mimeType: String)]? {
        await playbackClient.fetchDownloadTracks(
            bookId: grimmoryNumericId(book)
        ) { index in
            getAudioTrackURL(for: book, trackIndex: index)
        }
    }

    func makeTrackProbeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        addAuthHeaders(&request)
        return request
    }

    private func probeMultiTrackURLs(for book: Book) async -> [(url: URL, mimeType: String, duration: TimeInterval)]? {
        var tracks: [(url: URL, mimeType: String, duration: TimeInterval)] = []
        let streamHeaders = getStreamingHeaders()
        // AVURLAsset cannot use the transport session, so headers have to ride on the asset options.
        let assetOptions: [String: Any]? = streamHeaders.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": streamHeaders]

        for index in 0..<300 {
            guard let trackURL = getAudioTrackURL(for: book, trackIndex: index),
                let (_, http) = try? await performAuthorizedRequest(makeTrackProbeRequest(url: trackURL)),
                (200...299).contains(http.statusCode)
            else {
                break
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "audio/mpeg"

            let asset = AVURLAsset(url: trackURL, options: assetOptions)
            let assetDuration: TimeInterval
            if let cmDuration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(cmDuration)
                assetDuration = seconds.isFinite && seconds > 0 ? seconds : 0
            } else {
                assetDuration = 0
            }
            tracks.append((url: trackURL, mimeType: contentType, duration: assetDuration))
        }

        AppLogger.network.info(
            "[Booklore] Probed \(tracks.count) track(s) bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
        )
        return tracks.count > 1 ? tracks : nil
    }

    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
        guard !useLegacyRestAPI, !useKomgaFallback else { return }

        guard let duration = book.duration, duration > 0 else { return }
        // Counted before the progress write so a failed write can't drop the listening time.
        if timeListened > 0 {
            var pending = pendingListening[book.stableId] ?? PendingListening(book: book, seconds: 0, position: currentTime, duration: duration)
            pending.seconds += timeListened
            pending.position = currentTime
            pending.duration = duration
            pendingListening[book.stableId] = pending
        }
        let progress = try await progressClient.updateAudiobookProgress(
            for: book,
            bookId: grimmoryNumericId(book),
            sessionId: sessionId,
            currentTime: currentTime,
            duration: duration,
            isFinished: isFinished
        )

        if (pendingListening[book.stableId]?.seconds ?? 0) >= maxPendingListening
            || pausedListeningBooks.contains(book.stableId)
        {
            await flushListeningSession(for: book.stableId)
        }

        AppLogger.network.debug(
            "[Booklore] Synced playback progress bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) percentage=\(Int(progress * 100))"
        )
    }

    func reportPlayback(_ event: ServerPlaybackEvent, book: Book, sessionId: String, position: TimeInterval) async {
        guard event == .paused || event == .stopped else {
            pausedListeningBooks.remove(book.stableId)
            return
        }
        pausedListeningBooks.insert(book.stableId)
        for stableId in pendingListening.keys {
            await flushListeningSession(for: stableId)
        }
    }

    // One Grimmory session per stretch of listening, sent on pause or stop, instead of one per progress sync.
    private func flushListeningSession(for stableId: String) async {
        guard let pending = pendingListening.removeValue(forKey: stableId), pending.seconds >= 1 else { return }
        do {
            try await uploadReadingSession(
                for: pending.book,
                currentTime: pending.position,
                duration: pending.duration,
                timeListened: pending.seconds
            )
        } catch {
            var retry = pendingListening[stableId] ?? PendingListening(book: pending.book, seconds: 0, position: pending.position, duration: pending.duration)
            retry.seconds += pending.seconds
            pendingListening[stableId] = retry
            AppLogger.network.error(
                "Failed to sync reading session bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: stableId)): \(error.localizedDescription)"
            )
        }
    }

    private func uploadReadingSession(
        for book: Book,
        currentTime: TimeInterval,
        duration: TimeInterval,
        timeListened: TimeInterval
    ) async throws {
        guard let bookId = Int(grimmoryNumericId(book)), bookId > 0 else { return }
        try await readingSessionClient.uploadAudiobookSession(
            for: book,
            bookId: bookId,
            currentTime: currentTime,
            duration: duration,
            timeListened: timeListened
        )
    }
}
