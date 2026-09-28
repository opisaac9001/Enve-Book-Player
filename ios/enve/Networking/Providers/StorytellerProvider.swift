import Foundation
import Logging

class StorytellerProvider: WholeSnapshotCatalogProvider, PlaybackSessionProvider, AudiobookProgressProvider,
    EbookProgressProvider, EbookDownloadProvider, PersonalRatingProvider, @unchecked Sendable
{
    var connection: ServerConnection {
        didSet {
            clearAudioManifestCache()
            clearMirrorSnapshotCache()
        }
    }
    private let session: URLSession
    private let audioManifestCacheLock = NSLock()
    private var audioManifestCache: [String: (manifest: StorytellerAudioManifest, cachedAt: Date)] = [:]
    private static let audioManifestCacheTTL: TimeInterval = 300
    private let mirrorSnapshotCacheLock = NSLock()
    private var mirrorSnapshotCache:
        (
            books: [Book],
            membership: MirrorMembership,
            cachedAt: Date
        )?
    private static let mirrorSnapshotCacheTTL: TimeInterval = 15

    var capabilities: ProviderCapabilities {
        [
            .fullImport,
            .series, .collections,
            .audiobookProgressPull, .audiobookProgressPush,
            .ebookProgressPull, .ebookProgressPush,
            .downloads, .coverAuthHeader, .coverAuthQuery, .backgroundOperation,
        ]
    }

    var supportsPersonalRating: Bool { true }

    var onTokenUpdated: ((ServerConnection) -> Void)?

    init(connection: ServerConnection = ServerConnection(name: "Storyteller", url: "", type: .storyteller)) {
        self.connection = connection
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        if let customHeaders = connection.customHeaders {
            config.httpAdditionalHeaders = customHeaders
        }
        if connection.mtlsEnabled {
            self.session = MTLSManager.shared.makeSession(for: connection.id, configuration: config)
        } else {
            self.session = URLSession(configuration: config)
        }
        syncAuthCookie()
    }

    private func baseURL() -> String {
        var url = connection.url.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url = String(url.dropLast()) }
        return url
    }

    private func serverBookId(for book: Book) -> String {
        let prefix = "storyalign_"
        if book.id.hasPrefix(prefix) {
            return String(book.id.dropFirst(prefix.count))
        }
        return book.id
    }

    private static func date(fromServerTimestamp ms: Int) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    private func syncAuthCookie() {
        guard let token = connection.token, !token.isEmpty,
            let url = URL(string: baseURL()),
            let host = url.host
        else { return }

        let properties: [HTTPCookiePropertyKey: Any] = [
            .domain: host,
            .path: "/",
            .name: "st_token",
            .value: token,
            .secure: url.scheme?.lowercased() == "https",
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 30),
        ]

        if let cookie = HTTPCookie(properties: properties) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    private func makeRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        includeAuth: Bool = true
    ) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL())\(path)") else {
            throw ProviderError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let ct = contentType {
            request.setValue(ct, forHTTPHeaderField: "Content-Type")
        }
        if includeAuth {
            if let token = connection.token, !token.isEmpty {
                if token.hasPrefix("Bearer ") || token.hasPrefix("Basic ") {
                    request.setValue(token, forHTTPHeaderField: "Authorization")
                } else {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
            } else if connection.authMode == .usernamePassword || connection.authMode == .auto,
                let username = connection.username,
                let password = connection.password,
                !username.isEmpty,
                !password.isEmpty
            {
                let basic = Data("\(username):\(password)".utf8).base64EncodedString()
                request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
            }
        }
        if let customHeaders = connection.customHeaders {
            for (key, value) in customHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        return (data, http)
    }

    private func authorizedSend(
        _ request: URLRequest,
        refreshOnForbidden: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, http) = try await send(request)
        if Self.responseRequiresReauthentication(
            statusCode: http.statusCode,
            refreshOnForbidden: refreshOnForbidden
        ) {
            guard let username = connection.username, let password = connection.password,
                !username.isEmpty
            else {
                throw ProviderError.unauthorized
            }
            let newToken = try await loginWithCredentials(usernameOrEmail: username, password: password)
            connection.token = newToken
            syncAuthCookie()
            onTokenUpdated?(connection)
            var retry = request
            retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryHttp) = try await send(retry)
            guard retryHttp.statusCode != 401,
                !refreshOnForbidden || retryHttp.statusCode != 403
            else {
                throw ProviderError.unauthorized
            }
            return (retryData, retryHttp)
        }
        return (data, http)
    }

    nonisolated static func responseRequiresReauthentication(
        statusCode: Int,
        refreshOnForbidden: Bool = false
    ) -> Bool {
        statusCode == 401 || (refreshOnForbidden && statusCode == 403)
    }

    func loginWithCredentials(usernameOrEmail: String, password: String) async throws -> String {
        let boundary = UUID().uuidString
        var bodyData = Data()
        func appendField(_ name: String, _ value: String) {
            bodyData.append("--\(boundary)\r\n".data(using: .utf8)!)
            bodyData.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            bodyData.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("usernameOrEmail", usernameOrEmail)
        appendField("password", password)
        bodyData.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = try makeRequest(path: "/api/v2/token", method: "POST", includeAuth: false)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, http) = try await send(request)
        guard http.statusCode == 200 else {
            AppLogger.network.error("Login failed HTTP \(http.statusCode)")
            throw ProviderError.unauthorized
        }

        let tokenResp = try JSONDecoder().decode(StorytellerTokenResponse.self, from: data)
        connection.token = tokenResp.access_token
        syncAuthCookie()
        return tokenResp.access_token
    }

    func exchangeAppToken(_ shortToken: String) async throws -> String {
        let payload = ["token": shortToken]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)

        var request = try makeRequest(path: "/api/v2/token/app", method: "POST", includeAuth: false)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, http) = try await send(request)
        guard http.statusCode == 200 else {
            AppLogger.network.error("App token exchange failed HTTP \(http.statusCode)")
            throw ProviderError.unauthorized
        }

        let tokenResp = try JSONDecoder().decode(StorytellerTokenResponse.self, from: data)
        connection.token = tokenResp.access_token
        syncAuthCookie()
        return tokenResp.access_token
    }

    func validateConnection() async throws -> Bool {
        let request = try makeRequest(path: "/api/v2/user")
        let (_, http) = try await send(request)
        if http.statusCode == 200 {
            return true
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            guard let username = connection.username,
                let password = connection.password,
                !username.isEmpty,
                !password.isEmpty
            else {
                return false
            }
            let token = try await loginWithCredentials(usernameOrEmail: username, password: password)
            connection.token = token
            syncAuthCookie()
            onTokenUpdated?(connection)
            let retry = try makeRequest(path: "/api/v2/user")
            let (_, retryHttp) = try await send(retry)
            return retryHttp.statusCode == 200
        }
        return false
    }

    func fetchLibraries() async throws -> [Library] {
        return [
            Library(
                id: "storyteller-library",
                name: "Storyteller",
                type: "book",
                providerId: connection.id
            )
        ]
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        try await fetchMirrorSnapshot(forceRefresh: false)
    }

    func makeCatalogBatchSource(
        libraryId: String,
        resumeAfter: String?,
        expectedSnapshotIdentifier: String?
    ) async throws -> LibraryCatalogBatchSource {
        let result = try await fetchMirrorSnapshotResult(forceRefresh: false)
        return LibraryCatalogBatchSource.snapshot(
            books: result.books,
            isComplete: result.isComplete,
            resumeAfter: resumeAfter,
            expectedSnapshotIdentifier: expectedSnapshotIdentifier
        )
    }

    func fetchMirrorSnapshot(forceRefresh: Bool = true) async throws -> [Book] {
        try await fetchMirrorSnapshotResult(forceRefresh: forceRefresh).books
    }

    private func fetchMirrorSnapshotResult(forceRefresh: Bool) async throws -> (books: [Book], isComplete: Bool) {
        if !forceRefresh, let cached = cachedMirrorSnapshot() {
            return (cached, true)
        }
        let request = try makeRequest(path: "/api/v2/books")
        let (data, http) = try await authorizedSend(request)
        guard http.statusCode == 200 else {
            throw ProviderError.serverError("HTTP \(http.statusCode)")
        }

        let decoded = try JSONDecoder().decode(LenientArrayWrapper<StorytellerBook>.self, from: data)
        let stBooks = decoded.values
        var books: [Book] = []
        var mappingRejections: [RejectedContentCandidate] = []
        for (index, stBook) in stBooks.enumerated() {
            if let book = mapStorytellerBookToBook(stBook) {
                books.append(book)
            } else {
                mappingRejections.append(
                    RejectedContentCandidate(
                        itemIdentifier: stBook.uuid,
                        title: resolveBookTitle(stBook),
                        reason: "The item has no supported audio or ebook content.",
                        fallbackIdentifier: "mapped-item-\(index)"
                    )
                )
            }
        }
        let rejectedItems = decoded.rejectedItems + mappingRejections
        RejectedContentStore.shared.update(
            connection: connection,
            libraryId: "storyteller-library",
            acceptedItemIdentifiers: Set(books.map(\.id)),
            rejectedItems: rejectedItems,
            fallbackScope: "snapshot"
        )
        let isComplete = rejectedItems.isEmpty
        var membership = MirrorMembership()
        let importedBookIds = Set(books.map(\.id))
        for stBook in stBooks where importedBookIds.contains(stBook.uuid) {
            for collection in stBook.collections {
                membership.collections[collection.uuid, default: []].append(stBook.uuid)
            }
            for series in stBook.series {
                membership.series[series.uuid, default: []].append((stBook.uuid, series.position))
            }
        }

        if isComplete {
            cacheMirrorSnapshot(books, membership: membership)
        }
        AppLogger.network.info("Fetched \(books.count) Storyteller books from \(stBooks.count) decoded record(s)")
        return (books, isComplete)
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        try await fetchBooks(libraryId: libraryId)
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] {
        let request = try makeRequest(path: "/api/v2/collections")
        let (data, http) = try await authorizedSend(request)
        guard http.statusCode == 200 else {
            throw ProviderError.serverError("HTTP \(http.statusCode)")
        }

        let collections = try JSONDecoder().decode([StorytellerCollection].self, from: data)
        _ = try await fetchMirrorSnapshot(forceRefresh: false)
        guard let membership = cachedMembership() else {
            throw ProviderError.invalidResponse
        }
        return collections.map { col in
            let bookIds = membership.collections[col.uuid] ?? []
            return Collection(
                id: col.uuid,
                name: col.name,
                description: col.description,
                books: bookIds,
                bookCount: bookIds.count,
                iconName: "books.vertical",
                color: "blue",
                providerId: connection.id
            )
        }
    }

    func fetchSeries(libraryId: String) async throws -> [Series] {
        let request = try makeRequest(path: "/api/v2/series")
        let (data, http) = try await authorizedSend(request)
        guard http.statusCode == 200 else {
            throw ProviderError.serverError("HTTP \(http.statusCode)")
        }

        let series = try JSONDecoder().decode([StorytellerSeries].self, from: data)
        _ = try await fetchMirrorSnapshot(forceRefresh: false)
        guard let membership = cachedMembership() else {
            throw ProviderError.invalidResponse
        }
        return series.map { s in
            var bookIds: [String] = []
            var seqs: [String: String] = [:]
            for rel in membership.series[s.uuid] ?? [] {
                bookIds.append(rel.bookId)
                if let pos = rel.position {
                    seqs[rel.bookId] = String(pos)
                }
            }
            return Series(
                id: s.uuid,
                name: s.name,
                description: s.description,
                books: bookIds,
                bookSequences: seqs,
                bookCount: bookIds.count,
                libraryId: "storyteller-library",
                providerId: connection.id
            )
        }
    }

    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] {
        return []
    }

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        let resolvedId = bookId.hasPrefix("storyalign_") ? String(bookId.dropFirst("storyalign_".count)) : bookId
        let request = try makeRequest(path: "/api/v2/books/\(resolvedId)")
        let (data, http) = try await authorizedSend(request)
        guard http.statusCode == 200 else {
            throw ProviderError.serverError("HTTP \(http.statusCode)")
        }

        let stBook = try JSONDecoder().decode(StorytellerBook.self, from: data)
        guard var book = mapStorytellerBookToBook(stBook) else {
            throw ProviderError.decodingFailed
        }
        if book.mediaType == .audiobook, book.chapters?.isEmpty ?? true,
            let assets = try? await loadPlaybackAssets(for: book)
        {
            if !assets.chapters.isEmpty {
                book.chapters = assets.chapters
            } else if let trackURL = assets.tracks.first.flatMap({ URL(string: $0.contentUrl) }),
                let embedded = await MetadataLayeringManager.shared.extractEmbeddedChapters(
                    from: trackURL,
                    headers: getStreamingHeaders()
                ),
                !embedded.isEmpty
            {
                book.chapters = embedded
            } else {
                let synthesized = trackBasedChapters(from: assets.tracks)
                if !synthesized.isEmpty {
                    book.chapters = synthesized
                }
            }
            book.duration = book.duration ?? assets.duration
        }
        return book
    }

    func getAudioURL(for book: Book) -> URL? {
        return nil
    }

    func getStreamingHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        if let token = connection.token, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
            headers["Cookie"] = "st_token=\(token)"
        }
        if let custom = connection.customHeaders {
            for (k, v) in custom { headers[k] = v }
        }
        return headers
    }

    func fetchManifestChapters(for book: Book) async throws -> [Chapter] {
        let assets = try await loadPlaybackAssets(for: book)
        return assets.chapters
    }

    private struct PlaybackAudioResource {
        let href: String
        let mimeType: String
        let trackIndex: Int
        let startOffset: TimeInterval
        let duration: TimeInterval
    }

    private struct PlaybackManifestAssets {
        let tracks: [AudioTrackInfo]
        let resources: [PlaybackAudioResource]
        let chapters: [Chapter]
        let duration: TimeInterval
    }

    private struct ResolvedAudioPosition {
        let globalTime: TimeInterval
        let trackIndex: Int?
    }

    private func cachedAudioManifest(serverId: String) -> StorytellerAudioManifest? {
        audioManifestCacheLock.lock()
        defer { audioManifestCacheLock.unlock() }
        guard let entry = audioManifestCache[serverId] else { return nil }
        guard Date().timeIntervalSince(entry.cachedAt) < Self.audioManifestCacheTTL else {
            audioManifestCache.removeValue(forKey: serverId)
            return nil
        }
        return entry.manifest
    }

    private func cacheAudioManifest(_ manifest: StorytellerAudioManifest, serverId: String) {
        guard !manifest.readingOrder.isEmpty else { return }
        audioManifestCacheLock.lock()
        audioManifestCache[serverId] = (manifest, Date())
        audioManifestCacheLock.unlock()
    }

    private func clearAudioManifestCache() {
        audioManifestCacheLock.lock()
        audioManifestCache.removeAll()
        audioManifestCacheLock.unlock()
    }

    private func cachedMirrorSnapshot() -> [Book]? {
        mirrorSnapshotCacheLock.lock()
        defer { mirrorSnapshotCacheLock.unlock() }
        guard let snapshot = mirrorSnapshotCache,
            Date().timeIntervalSince(snapshot.cachedAt) < Self.mirrorSnapshotCacheTTL
        else {
            mirrorSnapshotCache = nil
            return nil
        }
        return snapshot.books
    }

    private struct MirrorMembership {
        var collections: [String: [String]] = [:]
        var series: [String: [(bookId: String, position: Double?)]] = [:]
    }

    private func cachedMembership() -> MirrorMembership? {
        mirrorSnapshotCacheLock.lock()
        defer { mirrorSnapshotCacheLock.unlock() }
        guard let snapshot = mirrorSnapshotCache,
            Date().timeIntervalSince(snapshot.cachedAt) < Self.mirrorSnapshotCacheTTL
        else {
            mirrorSnapshotCache = nil
            return nil
        }
        return snapshot.membership
    }

    private func cacheMirrorSnapshot(
        _ books: [Book],
        membership: MirrorMembership
    ) {
        mirrorSnapshotCacheLock.lock()
        mirrorSnapshotCache = (books, membership, Date())
        mirrorSnapshotCacheLock.unlock()
    }

    private func clearMirrorSnapshotCache() {
        mirrorSnapshotCacheLock.lock()
        mirrorSnapshotCache = nil
        mirrorSnapshotCacheLock.unlock()
    }

    private func fetchAudioManifest(serverId: String) async throws -> StorytellerAudioManifest {
        if let cached = cachedAudioManifest(serverId: serverId) {
            return cached
        }

        let request = try makeRequest(path: "/api/v2/books/\(serverId)/listen/manifest.json")
        let (data, http) = try await authorizedSend(request)
        guard http.statusCode == 200 else {
            AppLogger.network.error("Manifest fetch failed HTTP \(http.statusCode)")
            throw ProviderError.serverError("Manifest fetch failed: HTTP \(http.statusCode)")
        }

        let manifest: StorytellerAudioManifest
        do {
            manifest = try JSONDecoder().decode(StorytellerAudioManifest.self, from: data)
        } catch {
            AppLogger.network.error("Manifest decode failed: \(error)")
            throw ProviderError.decodingFailed
        }

        guard !manifest.readingOrder.isEmpty else {
            AppLogger.network.info("Manifest has empty readingOrder")
            throw ProviderError.serverError("Audiobook manifest has no audio tracks")
        }

        cacheAudioManifest(manifest, serverId: serverId)
        AppLogger.network.info(" [Storyteller] Manifest loaded: \(manifest.readingOrder.count) tracks")
        return manifest
    }

    private func loadPlaybackAssets(for book: Book) async throws -> PlaybackManifestAssets {
        let serverId = serverBookId(for: book)
        let manifest = try await fetchAudioManifest(serverId: serverId)
        return playbackAssets(from: manifest, serverId: serverId)
    }

    private func playbackAssets(from manifest: StorytellerAudioManifest, serverId: String) -> PlaybackManifestAssets {
        var tracks: [AudioTrackInfo] = []
        var resources: [PlaybackAudioResource] = []
        var cumulativeOffset: Double = 0
        let base = baseURL()

        var trackOffsetsByHref: [String: Double] = [:]
        for (index, item) in manifest.readingOrder.enumerated() {
            let trackHref = hrefPath(item.href)
            let contentUrl: String
            if trackHref.hasPrefix("http://") || trackHref.hasPrefix("https://") {
                contentUrl = trackHref
            } else {
                let encodedHref = trackHref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trackHref
                contentUrl = "\(base)/api/v2/books/\(serverId)/listen/\(encodedHref)"
            }
            let duration = item.duration ?? 0
            tracks.append(
                AudioTrackInfo(
                    index: index,
                    startOffset: cumulativeOffset,
                    duration: duration,
                    contentUrl: contentUrl,
                    mimeType: item.type ?? "audio/mpeg",
                    title: item.title
                )
            )
            resources.append(
                PlaybackAudioResource(
                    href: trackHref,
                    mimeType: item.type ?? "audio/mpeg",
                    trackIndex: index,
                    startOffset: cumulativeOffset,
                    duration: duration
                )
            )
            trackOffsetsByHref[trackHref] = cumulativeOffset
            if let decoded = trackHref.removingPercentEncoding {
                trackOffsetsByHref[decoded] = cumulativeOffset
            }
            cumulativeOffset += duration
        }

        func flattenedTOC(_ items: [StorytellerLink]) -> [StorytellerLink] {
            items.flatMap { item in
                [item] + flattenedTOC(item.children ?? [])
            }
        }

        func offsetForTOCHref(_ raw: String?) -> Double? {
            guard let raw, !raw.isEmpty else { return nil }
            let path = hrefPath(raw)
            guard let trackOffset = trackOffsetsByHref[path] ?? trackOffsetsByHref[path.removingPercentEncoding ?? path] else {
                return nil
            }
            return trackOffset + (timeFragmentSeconds(raw) ?? 0)
        }

        var chapters: [Chapter] = []
        if let manifestTOC = manifest.toc, !manifestTOC.isEmpty {
            let toc = flattenedTOC(manifestTOC)
            for (idx, tocItem) in toc.enumerated() {
                let title = tocItem.title ?? "Chapter \(idx + 1)"
                let hintedStart = offsetForTOCHref(tocItem.href)
                let previous = chapters.last
                let start =
                    if let hintedStart, let previous, hintedStart <= previous.start, tocItem.duration != nil {
                        previous.end
                    } else {
                        hintedStart ?? previous?.end ?? 0
                    }
                let hintedNextStart = (idx + 1 < toc.count) ? offsetForTOCHref(toc[idx + 1].href) : nil
                let fallbackEnd = tocItem.duration.map { start + $0 } ?? cumulativeOffset
                let nextStart =
                    hintedNextStart
                    ?? chapters.last?.end
                    ?? fallbackEnd
                let end = nextStart > start ? nextStart : fallbackEnd
                chapters.append(Chapter(id: "\(idx)", start: start, end: end, title: title, index: idx))
            }
        }

        let distinctStarts = Set(chapters.map { Int(($0.start * 1000).rounded()) })
        if (chapters.count < 2 && tracks.count > 1) || (chapters.count >= 2 && distinctStarts.count <= 1 && tracks.count > 1) {
            chapters = tracks.enumerated().map { idx, track in
                Chapter(
                    id: "\(idx)",
                    start: track.startOffset,
                    end: track.startOffset + track.duration,
                    title: "Chapter \(idx + 1)",
                    index: idx
                )
            }
        }

        return PlaybackManifestAssets(
            tracks: tracks,
            resources: resources,
            chapters: chapters,
            duration: cumulativeOffset
        )
    }

    private func readaloudChapters(from manifest: StorytellerAudioManifest?) -> [Chapter]? {
        guard let manifest else { return nil }

        var durationsByHref: [String: TimeInterval] = [:]
        for resource in manifest.resources ?? [] {
            guard let duration = resource.duration, duration > 0 else { continue }
            durationsByHref[normalizedAudioResourceHref(resource.href)] = duration
        }
        guard !durationsByHref.isEmpty else { return nil }

        let titlesByHref = Dictionary(
            (manifest.toc ?? []).compactMap { item -> (String, String)? in
                guard let title = item.title else { return nil }
                return (normalizedAudioResourceHref(item.href), title)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var chapters: [Chapter] = []
        var cumulative: TimeInterval = 0
        for item in manifest.readingOrder {
            let href = normalizedAudioResourceHref(item.href)
            guard let duration = durationsByHref[href] else { continue }
            let start = cumulative
            cumulative += duration
            chapters.append(
                Chapter(
                    id: "storyteller_readaloud_\(chapters.count)",
                    start: start,
                    end: cumulative,
                    title: titlesByHref[href] ?? item.title ?? "Chapter \(chapters.count + 1)",
                    index: chapters.count
                )
            )
        }
        return chapters.isEmpty ? nil : chapters
    }

    private func trackBasedChapters(from tracks: [AudioTrackInfo]) -> [Chapter] {
        guard tracks.count > 1 else { return [] }
        var offset: TimeInterval = 0
        return tracks.enumerated().compactMap { index, track in
            let start = track.startOffset > 0 ? track.startOffset : offset
            let end = start + max(track.duration, 0)
            offset = end
            guard end > start else { return nil }
            return Chapter(
                id: "storyteller_track_\(track.index)",
                start: start,
                end: end,
                title: track.title ?? "Track \(index + 1)",
                index: index
            )
        }
    }

    private func hrefPath(_ href: String) -> String {
        href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? href
    }

    private func timeFragmentSeconds(_ href: String) -> Double? {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let fragment = String(parts[1])
        guard fragment.hasPrefix("t=") else { return nil }
        let value = fragment.dropFirst(2).split { $0 == "," || $0 == "&" }.first.map(String.init)
        return value.flatMap(Double.init)
    }

    private func normalizedAudioResourceHref(_ rawHref: String) -> String {
        let path = hrefPath(rawHref)
        let withoutQuery =
            path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? path
        var normalized = withoutQuery.removingPercentEncoding ?? withoutQuery

        if let url = URL(string: normalized), url.scheme != nil {
            normalized = url.path.removingPercentEncoding ?? url.path
        }

        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }
        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }
        return normalized
    }

    private func audioResource(
        matching rawHref: String,
        in assets: PlaybackManifestAssets
    ) -> PlaybackAudioResource? {
        let target = normalizedAudioResourceHref(rawHref)
        guard !target.isEmpty else { return nil }

        if let exact = assets.resources.first(where: {
            normalizedAudioResourceHref($0.href) == target
        }) {
            return exact
        }

        let suffixMatches = assets.resources.filter {
            let candidate = normalizedAudioResourceHref($0.href)
            guard !candidate.isEmpty else { return false }
            return candidate.hasSuffix("/\(target)") || target.hasSuffix("/\(candidate)")
        }
        if suffixMatches.count == 1 {
            return suffixMatches[0]
        }

        let filename = (target as NSString).lastPathComponent
        guard !filename.isEmpty else { return nil }
        let filenameMatches = assets.resources.filter {
            (normalizedAudioResourceHref($0.href) as NSString).lastPathComponent == filename
        }
        return filenameMatches.count == 1 ? filenameMatches[0] : nil
    }

    private func audioResource(
        atGlobalTime globalTime: TimeInterval,
        in assets: PlaybackManifestAssets
    ) -> PlaybackAudioResource? {
        guard let first = assets.resources.first else { return nil }
        let boundedTime =
            assets.duration > 0
            ? min(max(globalTime, 0), assets.duration)
            : max(globalTime, 0)

        if boundedTime >= assets.duration, let last = assets.resources.last {
            return last
        }

        return assets.resources.first(where: { resource in
            resource.duration > 0 && boundedTime < resource.startOffset + resource.duration
        }) ?? first
    }

    private func resolvedAudioPosition(
        from position: StorytellerPosition?,
        assets: PlaybackManifestAssets
    ) -> ResolvedAudioPosition? {
        guard let position else { return nil }
        let components = position.locatorComponents
        let href = components?.href.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let fragmentTime = components?.audioFragmentTime {
            if href.isEmpty {
                let globalTime =
                    assets.duration > 0
                    ? min(max(fragmentTime, 0), assets.duration)
                    : max(fragmentTime, 0)
                return ResolvedAudioPosition(
                    globalTime: globalTime,
                    trackIndex: audioResource(atGlobalTime: globalTime, in: assets)?.trackIndex
                )
            }

            if let resource = audioResource(matching: href, in: assets) {
                let localTime = min(max(fragmentTime, 0), max(resource.duration, 0))
                return ResolvedAudioPosition(
                    globalTime: resource.startOffset + localTime,
                    trackIndex: resource.trackIndex
                )
            }
        }

        if let progression = components?.progression,
            let resource = audioResource(matching: href, in: assets)
        {
            let localTime = min(max(progression, 0), 1) * max(resource.duration, 0)
            return ResolvedAudioPosition(
                globalTime: resource.startOffset + localTime,
                trackIndex: resource.trackIndex
            )
        }

        guard let totalProgression = position.totalProgression else { return nil }
        let globalTime = min(max(totalProgression, 0), 1) * assets.duration
        return ResolvedAudioPosition(
            globalTime: globalTime,
            trackIndex: audioResource(atGlobalTime: globalTime, in: assets)?.trackIndex
        )
    }

    private func canonicalAudioLocator(
        currentTime: TimeInterval,
        assets: PlaybackManifestAssets
    ) -> [String: Any]? {
        guard assets.duration > 0,
            let resource = audioResource(atGlobalTime: currentTime, in: assets),
            resource.duration > 0
        else { return nil }

        let globalTime = min(max(currentTime, 0), assets.duration)
        let localTime = min(max(globalTime - resource.startOffset, 0), resource.duration)
        return [
            "href": resource.href,
            "type": resource.mimeType,
            "locations": [
                "fragments": ["t=\(localTime)"],
                "progression": localTime / resource.duration,
                "totalProgression": globalTime / assets.duration,
            ] as [String: Any],
        ]
    }

    nonisolated static func localAudioLocatorJSONString(
        for book: Book,
        progression: Double
    ) -> String? {
        let locator: [String: Any] = [
            "href": "audiobook://\(book.id)",
            "type": "audio",
            "locations": [
                "totalProgression": min(max(progression, 0), 1)
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: locator) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func readAloudBoundaryLocatorJSONString(
        progression: Double
    ) -> String? {
        let locator: [String: Any] = [
            "href": "",
            "type": "application/xhtml+xml",
            "locations": [
                "totalProgression": min(max(progression, 0), 1)
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: locator) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        let authoritative = await StorytellerPositionSyncService.shared.authoritativePosition(
            for: book,
            through: self
        )
        let assets = try await loadPlaybackAssets(for: book)
        let serverCurrentTime = authoritative.flatMap {
            resolvedAudioPosition(from: $0.position.storytellerPosition, assets: assets)?.globalTime
        }

        let proxiedTracks = try await StorytellerStreamingServer.shared.startStreaming(
            tracks: assets.tracks,
            headers: getStreamingHeaders()
        )

        return PlaybackSessionInfo(
            sessionId: "storyteller-\(book.id)",
            audioTracks: proxiedTracks,
            chapters: assets.chapters,
            serverCurrentTime: serverCurrentTime
        )
    }

    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
        try await updateAudiobookProgress(
            for: book,
            currentTime: currentTime,
            observedAt: Date()
        )
    }

    func updateAudiobookProgress(
        for book: Book,
        currentTime: TimeInterval,
        observedAt: Date
    ) async throws {
        _ = try await StorytellerPositionSyncService.shared.submitAudioPosition(
            book: book,
            currentTime: currentTime,
            observedAt: observedAt,
            through: self
        )
    }

    func audiobookDownloadRequest(for book: Book) throws -> URLRequest {
        let serverId = serverBookId(for: book)
        var request = try makeRequest(path: "/api/v2/books/\(serverId)/files?format=audiobook")
        request.setValue("application/audiobook+zip", forHTTPHeaderField: "Accept")
        return request
    }

    func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let serverId = serverBookId(for: book)
        let request = try makeRequest(path: "/api/v2/books/\(serverId)/files?format=ebook")

        let response: URLResponse
        let tempURL: URL
        if let onProgress {
            let delegate = URLSessionDownloadProgressDelegate(progressHandler: onProgress)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (url, http) = try await delegate.awaitResult {
                session.downloadTask(with: request)
            }
            tempURL = url
            response = http
        } else {
            (tempURL, response) = try await session.download(for: request)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ProviderError.serverError("Download failed HTTP \(code)")
        }

        let stableURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(book.id).epub")
        let atomicTemp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).epub")
        try FileManager.default.moveItem(at: tempURL, to: atomicTemp)
        _ = try? FileManager.default.replaceItemAt(stableURL, withItemAt: atomicTemp)
        return stableURL
    }

    func downloadReadaloud(for book: Book, onProgress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let serverId = serverBookId(for: book)
        let request = try makeRequest(path: "/api/v2/books/\(serverId)/files?format=readaloud")

        let response: URLResponse
        let tempURL: URL
        if let onProgress {
            let delegate = URLSessionDownloadProgressDelegate(progressHandler: onProgress)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (url, http) = try await delegate.awaitResult {
                session.downloadTask(with: request)
            }
            tempURL = url
            response = http
        } else {
            (tempURL, response) = try await session.download(for: request)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ProviderError.serverError("Read Aloud download failed HTTP \(code)")
        }

        #if !os(tvOS)
            do {
                try await StorytellerReadaloudOfflinePrep.validate(epubURL: tempURL)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }
        #endif
        let cachedURL = try LocalEbookImporter.shared.cacheReadaloudEpub(
            tempURL: tempURL,
            bookId: book.id
        )
        return cachedURL
    }

    func updateEbookProgress(for book: Book, progress: Double, epubLocator: String?) async throws {
        try await updateEbookProgress(
            for: book,
            progress: progress,
            epubLocator: epubLocator,
            observedAt: Date()
        )
    }

    func updateEbookProgress(
        for book: Book,
        progress: Double,
        epubLocator: String?,
        observedAt: Date
    ) async throws {
        var locatorDict: [String: Any]
        if let loc = epubLocator, !loc.isEmpty,
            let locData = loc.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: locData) as? [String: Any]
        {
            locatorDict = parsed
        } else {
            locatorDict = [
                "href": "",
                "type": "application/xhtml+xml",
                "locations": [:],
            ]
        }
        var locations = (locatorDict["locations"] as? [String: Any]) ?? [:]
        locations["totalProgression"] = progress
        locatorDict["locations"] = locations
        guard let data = try? JSONSerialization.data(withJSONObject: locatorDict),
            let locatorJSON = String(data: data, encoding: .utf8)
        else {
            throw ProviderError.invalidResponse
        }
        _ = try await StorytellerPositionSyncService.shared.submit(
            book: book,
            locatorJSON: locatorJSON,
            observedAt: observedAt,
            through: self
        )
    }

    func fetchEbookProgress(for book: Book) async throws -> (progress: Double, locator: String?, updatedAt: Date?, isFinished: Bool)? {
        guard
            let authoritative = await StorytellerPositionSyncService.shared.authoritativePosition(
                for: book,
                through: self
            )
        else { return nil }
        return (
            progress: authoritative.position.progression,
            locator: authoritative.position.locatorJSON,
            updatedAt: authoritative.position.observedAt,
            isFinished: false
        )
    }

    func fetchAudiobookProgress(
        for book: Book
    ) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isFinished: Bool)? {
        guard
            let authoritative = await StorytellerPositionSyncService.shared.authoritativePosition(
                for: book,
                through: self
            )
        else { return nil }
        return try await pipelineAudiobookProgress(from: authoritative.position, for: book)
    }

    func pipelineAudiobookProgress(
        from position: StorytellerSyncedPosition,
        for book: Book
    ) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isFinished: Bool) {
        let assets = try await loadPlaybackAssets(for: book)
        let resolved = resolvedAudioPosition(from: position.storytellerPosition, assets: assets)
        let progression =
            position.progression > 0
            ? position.progression
            : resolved.map { assets.duration > 0 ? $0.globalTime / assets.duration : 0 } ?? 0
        return (
            positionSeconds: resolved?.globalTime ?? progression * assets.duration,
            percentage: progression,
            trackIndex: resolved?.trackIndex,
            updatedAt: position.observedAt,
            isFinished: false
        )
    }

    private func coverQueryItems(audiobook: Bool) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "w", value: "209"),
            URLQueryItem(name: "h", value: audiobook ? "209" : "320"),
        ]
        if audiobook {
            items.append(URLQueryItem(name: "audio", value: "true"))
        }
        return items
    }

    func coverURL(for bookId: String, audiobook: Bool = false) -> URL? {
        var components = URLComponents(string: "\(baseURL())/api/v2/books/\(bookId)/cover")
        components?.queryItems = coverQueryItems(audiobook: audiobook)
        return components?.url
    }

    func fetchCoverImage(for book: Book) async throws -> Data? {
        try await fetchCoverImage(bookId: serverBookId(for: book), audiobook: coverNeedsAudioVariant(for: book))
    }

    private func coverNeedsAudioVariant(for book: Book) -> Bool {
        if book.mediaType == .audiobook || book.epub3Features?.hasMediaOverlay == true || book.readAloudSourceStableId != nil {
            return true
        }
        guard let components = book.coverURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return false
        }
        return components.queryItems?.contains { $0.name == "audio" && $0.value == "true" } == true
    }

    func fetchCoverImage(bookId: String, audiobook: Bool = false) async throws -> Data? {
        let variants = audiobook ? [true, false] : [false, true]
        for variant in variants {
            if let data = try await fetchCoverImageVariant(bookId: bookId, audiobook: variant) {
                return data
            }
        }
        return nil
    }

    private func fetchCoverImageVariant(bookId: String, audiobook: Bool) async throws -> Data? {
        var queryComponents = URLComponents()
        queryComponents.queryItems = coverQueryItems(audiobook: audiobook)
        let query = queryComponents.percentEncodedQuery.map { "?\($0)" } ?? ""
        var request = try makeRequest(path: "/api/v2/books/\(bookId)/cover\(query)")
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        let (data, http) = try await authorizedSend(request)
        switch http.statusCode {
        case 200..<300:
            return data
        case 304, 404:
            return nil
        default:
            throw ProviderError.serverError("HTTP \(http.statusCode)")
        }
    }

    func fetchCurrentUser() async throws -> StorytellerUser {
        let request = try makeRequest(path: "/api/v2/user")
        let (data, http) = try await authorizedSend(request)
        guard http.statusCode == 200 else {
            throw ProviderError.unauthorized
        }
        return try JSONDecoder().decode(StorytellerUser.self, from: data)
    }

    func fetchManagementPermissions() async throws -> StorytellerPermissions {
        let request = try makeRequest(path: "/api/v2/user")
        let (data, http) = try await authorizedSend(request, refreshOnForbidden: false)
        guard http.statusCode == 200 else {
            throw managementError(data: data, response: http, action: "load account permissions")
        }
        let permissions = try JSONDecoder().decode(StorytellerUser.self, from: data).permissions
        return StorytellerPermissions(
            canListBooks: permissions.bookList,
            canProcessBooks: permissions.bookProcess
        )
    }

    func fetchStorytellerShelves() async throws -> [StorytellerShelf] {
        let request = try makeRequest(path: "/api/v2/shelves")
        let (data, http) = try await authorizedSend(request, refreshOnForbidden: false)
        guard http.statusCode == 200 else {
            throw managementError(data: data, response: http, action: "load shelves")
        }
        return try JSONDecoder().decode(LenientArrayWrapper<StorytellerShelf>.self, from: data).values
    }

    func createStorytellerShelf(name: String) async throws -> StorytellerShelf {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        let request = try makeRequest(
            path: "/api/v2/shelves",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        let (data, http) = try await authorizedSend(request, refreshOnForbidden: false)
        guard (200..<300).contains(http.statusCode) else {
            throw managementError(data: data, response: http, action: "create the shelf")
        }
        return try JSONDecoder().decode(StorytellerShelf.self, from: data)
    }

    func renameStorytellerShelf(_ shelf: StorytellerShelf, name: String) async throws -> StorytellerShelf {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        let request = try makeRequest(
            path: "/api/v2/shelves/\(shelf.uuid)",
            method: "PUT",
            body: body,
            contentType: "application/json"
        )
        let (data, http) = try await authorizedSend(request, refreshOnForbidden: false)
        guard (200..<300).contains(http.statusCode) else {
            throw managementError(data: data, response: http, action: "rename the shelf")
        }
        return try JSONDecoder().decode(StorytellerShelf.self, from: data)
    }

    func deleteStorytellerShelf(_ shelf: StorytellerShelf) async throws {
        let request = try makeRequest(path: "/api/v2/shelves/\(shelf.uuid)", method: "DELETE")
        let (data, http) = try await authorizedSend(request, refreshOnForbidden: false)
        guard (200..<300).contains(http.statusCode) else {
            throw managementError(data: data, response: http, action: "delete the shelf")
        }
    }

    func fetchStorytellerManagementBooks() async throws -> [StorytellerManagementBook] {
        let request = try makeRequest(path: "/api/v2/books")
        let (data, http) = try await authorizedSend(request, refreshOnForbidden: false)
        guard http.statusCode == 200 else {
            throw managementError(data: data, response: http, action: "load shelf books")
        }
        let decoded = try JSONDecoder().decode(LenientArrayWrapper<StorytellerBook>.self, from: data)
        return decoded.values
            .map {
                StorytellerManagementBook(
                    id: $0.uuid,
                    title: resolveBookTitle($0),
                    author: $0.authors.first?.name
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func updateStorytellerShelfBooks(
        _ shelf: StorytellerShelf,
        bookIds: [String]
    ) async throws -> StorytellerShelf {
        let body = try JSONSerialization.data(withJSONObject: ["books": bookIds])
        let request = try makeRequest(
            path: "/api/v2/shelves/\(shelf.uuid)",
            method: "PUT",
            body: body,
            contentType: "application/json"
        )
        let (data, http) = try await authorizedSend(request, refreshOnForbidden: false)
        guard (200..<300).contains(http.statusCode) else {
            throw managementError(data: data, response: http, action: "update shelf books")
        }
        return try JSONDecoder().decode(StorytellerShelf.self, from: data)
    }

    func fetchStorytellerAlignmentFacets() async throws -> StorytellerAlignmentFacets {
        let request = try makeRequest(path: "/api/v2/books/alignment-facets")
        let (data, http) = try await authorizedSend(request, refreshOnForbidden: false)
        guard http.statusCode == 200 else {
            throw managementError(data: data, response: http, action: "load alignment quality")
        }
        return try JSONDecoder().decode(StorytellerAlignmentFacets.self, from: data)
    }

    func fetchStorytellerAlignmentReport(bookId: String) async throws -> StorytellerAlignmentReport? {
        let request = try makeRequest(path: "/api/v2/books/\(bookId)/alignment-report")
        let (data, http) = try await authorizedSend(request, refreshOnForbidden: false)
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else {
            throw managementError(data: data, response: http, action: "load the alignment report")
        }
        return try JSONDecoder().decode(StorytellerAlignmentReport.self, from: data)
    }

    func fetchStorytellerProcessingBooks() async throws -> [StorytellerProcessingBook] {
        let request = try makeRequest(path: "/api/v2/books")
        let (data, http) = try await authorizedSend(request, refreshOnForbidden: false)
        guard http.statusCode == 200 else {
            throw managementError(data: data, response: http, action: "load processing candidates")
        }
        let decoded = try JSONDecoder().decode(LenientArrayWrapper<StorytellerBook>.self, from: data)
        return decoded.values.compactMap { book in
            guard let ebook = book.ebook,
                !ebook.missing,
                let audiobook = book.audiobook,
                !audiobook.missing
            else {
                return nil
            }
            return StorytellerProcessingBook(
                id: book.uuid,
                title: resolveBookTitle(book),
                author: book.authors.first?.name,
                readaloudStatus: book.readaloud?.status,
                currentStage: book.readaloud?.currentStage,
                stageProgress: book.readaloud?.stageProgress,
                queuePosition: book.readaloud?.queuePosition,
                restartPending: book.readaloud?.restartPending != nil
            )
        }
        .sorted {
            if $0.isProcessing != $1.isProcessing { return $0.isProcessing }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func startStorytellerAlignment(
        bookId: String,
        restart: StorytellerAlignmentRestartMode
    ) async throws {
        let query = restart.queryValue.map { "?restart=\($0)" } ?? ""
        let body = try JSONSerialization.data(withJSONObject: [:])
        let request = try makeRequest(
            path: "/api/v2/books/\(bookId)/process\(query)",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        let (data, http) = try await authorizedSend(request, refreshOnForbidden: false)
        guard (200..<300).contains(http.statusCode) else {
            throw managementError(data: data, response: http, action: "start alignment")
        }
    }

    func cancelStorytellerAlignment(bookId: String) async throws {
        let request = try makeRequest(path: "/api/v2/books/\(bookId)/process", method: "DELETE")
        let (data, http) = try await authorizedSend(request, refreshOnForbidden: false)
        guard (200..<300).contains(http.statusCode) else {
            throw managementError(data: data, response: http, action: "cancel alignment")
        }
    }

    private func managementError(
        data: Data,
        response: HTTPURLResponse,
        action: String
    ) -> StorytellerManagementError {
        if response.statusCode == 403 { return .forbidden }
        if response.statusCode == 404 { return .unavailable }
        struct ErrorBody: Decodable { let message: String }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
        return .rejected(message ?? "Storyteller could not \(action) (HTTP \(response.statusCode)).")
    }

    func fetchStatuses() async throws -> [StorytellerStatus] {
        let request = try makeRequest(path: "/api/v2/statuses")
        let (data, http) = try await authorizedSend(request)
        guard http.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode([StorytellerStatus].self, from: data)) ?? []
    }

    func updateBookStatus(bookId: String, statusUUID: String) async throws {
        let payload: [String: String] = ["status": statusUUID]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = try makeRequest(
            path: "/api/v2/books/\(bookId)/status",
            method: "PUT",
            body: body,
            contentType: "application/json"
        )
        let (_, http) = try await authorizedSend(request)
        if http.statusCode != 204 && http.statusCode != 200 {
            AppLogger.network.info("updateBookStatus HTTP \(http.statusCode)")
        }
    }

    func updatePersonalRating(for book: Book, rating: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "rating": min(max(rating, 1), 5)
        ])
        let request = try makeRequest(
            path: "/api/v2/books/\(serverBookId(for: book))/rating",
            method: "PUT",
            body: body,
            contentType: "application/json"
        )
        let (_, http) = try await authorizedSend(request)
        guard (200...204).contains(http.statusCode) else {
            throw ProviderError.serverError("Failed to update Storyteller rating (HTTP \(http.statusCode))")
        }
    }

    func syncFinishedStatus(for book: Book) async {
        do {
            let statuses = try await fetchStatuses()
            let targetName = book.isFinished ? "Read" : "Reading"
            guard let statusUUID = statuses.first(where: { $0.name == targetName })?.uuid else { return }
            try await updateBookStatus(bookId: serverBookId(for: book), statusUUID: statusUUID)
        } catch {
            AppLogger.network.info("Failed to sync status: \(error)")
        }
    }

    private func fetchPosition(bookId: String) async throws -> StorytellerPosition? {
        let request = try makeRequest(path: "/api/v2/books/\(bookId)/positions")
        let (data, http) = try await authorizedSend(request)
        guard http.statusCode == 200 else { return nil }
        return try JSONDecoder().decode(StorytellerPosition.self, from: data)
    }

    func fetchPipelinePosition(for book: Book) async throws -> StorytellerSyncedPosition? {
        guard let position = try await fetchPosition(bookId: serverBookId(for: book)) else {
            return nil
        }
        return StorytellerSyncedPosition(
            key: StorytellerPositionKey(book: book),
            locatorJSON: position.locatorJSONString,
            timestampMilliseconds: position.timestamp
        )
    }

    func pipelineAudioLocatorJSONString(
        for book: Book,
        currentTime: TimeInterval
    ) async throws -> String {
        let assets = try await loadPlaybackAssets(for: book)
        guard let locator = canonicalAudioLocator(currentTime: currentTime, assets: assets),
            let data = try? JSONSerialization.data(withJSONObject: locator),
            let json = String(data: data, encoding: .utf8)
        else {
            throw ProviderError.invalidResponse
        }
        return json
    }

    func sendPipelinePosition(
        _ position: StorytellerSyncedPosition,
        for book: Book
    ) async throws -> StorytellerPositionSendResult {
        guard position.key == StorytellerPositionKey(book: book),
            let locatorData = position.locatorJSON.data(using: .utf8),
            let locator = try? JSONSerialization.jsonObject(with: locatorData) as? [String: Any]
        else {
            throw ProviderError.invalidResponse
        }
        let payload: [String: Any] = [
            "locator": locator,
            "timestamp": position.timestampMilliseconds,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = try makeRequest(
            path: "/api/v2/books/\(serverBookId(for: book))/positions",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        let (_, http) = try await authorizedSend(request)
        if http.statusCode == 409 {
            guard let server = try await fetchPipelinePosition(for: book) else {
                throw ProviderError.serverError("Storyteller position conflict could not be reconciled")
            }
            return .conflict(server)
        }
        guard http.statusCode == 204 || http.statusCode == 200 else {
            throw ProviderError.serverError(
                "Storyteller position sync failed HTTP \(http.statusCode)"
            )
        }
        return .accepted
    }

    private func mapStorytellerBookToBook(_ stBook: StorytellerBook) -> Book? {
        let hasAudiobook = stBook.audiobook != nil
        let hasEbook = stBook.ebook != nil
        let hasReadaloud = stBook.readaloud != nil

        let mediaType: AppMediaType
        if hasReadaloud || (hasEbook && !hasAudiobook) {
            mediaType = .ebook
        } else if hasAudiobook {
            mediaType = .audiobook
        } else {
            return nil
        }

        let authorName = stBook.authors.first?.name
        let narratorName = stBook.narrators.first?.name

        let resolvedTitle = resolveBookTitle(stBook)

        var seriesInfo: SeriesInfo?
        if let first = stBook.series.first {
            seriesInfo = SeriesInfo(name: first.name, sequence: first.position.map { String(format: "%.0f", $0) })
        } else {
            let parentFolder = parentFolderName(from: stBook)
            if let parentFolder, stBook.title == parentFolder, resolvedTitle != stBook.title {
                seriesInfo = SeriesInfo(name: stBook.title, sequence: nil)
            }
        }

        let coverURL = coverURL(for: stBook.uuid, audiobook: hasAudiobook || hasReadaloud)

        let serverReadStatus = normalizedReadStatus(stBook.status?.name)
        let reportedProgress =
            stBook.position?.totalProgression
            ?? Book.progressFromEbookLocator(stBook.position?.locatorJSONString)
            ?? 0
        let effectiveProgress = serverReadStatus == "READ" ? 1 : reportedProgress
        let ebookProgress =
            mediaType == .ebook && (stBook.position != nil || serverReadStatus == "READ")
            ? effectiveProgress
            : nil
        let epubLocator = stBook.position?.locatorJSONString
        let positionUpdate = stBook.position.map { Self.date(fromServerTimestamp: $0.timestamp) }
        let isFinished = serverReadStatus == "READ"

        let genres = stBook.tags.map(\.name)

        var publishedYear: Int?
        if let pubDate = stBook.publicationDate, !pubDate.isEmpty {
            let yearStr = String(pubDate.prefix(4))
            publishedYear = Int(yearStr)
        }

        var epub3Features: EPUB3Features?
        if let ra = stBook.readaloud, ra.isReady {
            epub3Features = EPUB3Features(
                hasMediaOverlay: true,
                hasFixedLayout: false,
                smilFileCount: 1
            )
        }

        let audioManifest = stBook.audiobook?.manifest
        if let audioManifest {
            cacheAudioManifest(audioManifest, serverId: stBook.uuid)
        }
        let manifestAssets = audioManifest.map { playbackAssets(from: $0, serverId: stBook.uuid) }
        let audioTracks = manifestAssets?.tracks.map { track in
            AudioTrack(
                index: track.index,
                title: track.title,
                contentUrl: track.contentUrl,
                duration: track.duration,
                startOffset: track.startOffset,
                format: track.mimeType,
                headers: getStreamingHeaders()
            )
        }
        let duration =
            stBook.audiobook?.duration
            ?? stBook.readaloud?.duration
            ?? manifestAssets?.duration
        let currentTime =
            mediaType == .audiobook
            ? (duration ?? 0) * effectiveProgress
            : 0
        let hideFromContinue = serverReadStatus == "TO_READ" || serverReadStatus == "READ"

        var book = Book(
            id: stBook.uuid,
            title: resolvedTitle,
            author: authorName,
            narrator: narratorName,
            seriesInfo: seriesInfo,
            duration: duration,
            coverURL: coverURL,
            audioTracks: audioTracks,
            mediaType: mediaType,
            epubLocator: epubLocator,
            ebookProgress: ebookProgress,
            hideFromContinue: hideFromContinue,
            dateAdded: Self.sqliteDateTimeFormatter.date(from: stBook.createdAt),
            description: stBook.description,
            genres: genres,
            chapters: manifestAssets?.chapters ?? readaloudChapters(from: stBook.readaloud?.manifest),
            currentTime: currentTime,
            isFinished: isFinished,
            lastUpdate: positionUpdate ?? .distantPast,
            libraryId: "storyteller-library",
            providerId: connection.id,
            backendId: connection.id.uuidString,
            source: .storyteller,
            epub3Features: epub3Features,
            publishedYear: publishedYear,
            personalRating: stBook.rating,
            language: stBook.language,
            hasAlternateFormat: (hasAudiobook && hasEbook) || (hasReadaloud && (hasAudiobook || hasEbook))
        )
        book.serverReadStatus = serverReadStatus
        return book
    }

    private func normalizedReadStatus(_ status: String?) -> String? {
        guard let status else { return nil }
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "to read": return "TO_READ"
        case "reading": return "READING"
        case "read": return "READ"
        default: return status.uppercased().replacingOccurrences(of: " ", with: "_")
        }
    }

    private func resolveBookTitle(_ stBook: StorytellerBook) -> String {
        guard let folderTitle = folderNameTitle(from: stBook) else {
            return stBook.title
        }
        if folderTitle == stBook.title {
            return stBook.title
        }
        let parentFolder = parentFolderName(from: stBook)
        if let parentFolder, stBook.title != parentFolder {
            return stBook.title
        }
        return folderTitle
    }

    private func parentFolderName(from stBook: StorytellerBook) -> String? {
        let filepath = stBook.audiobook?.filepath ?? stBook.ebook?.filepath
        guard let filepath, !filepath.isEmpty else { return nil }
        let parent = ((filepath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return parent.isEmpty ? nil : parent
    }

    private func folderNameTitle(from stBook: StorytellerBook) -> String? {
        let filepath = stBook.audiobook?.filepath ?? stBook.ebook?.filepath
        guard let filepath, !filepath.isEmpty else { return nil }
        let name = (filepath as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static let sqliteDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

struct StorytellerTokenResponse: Codable {
    let access_token: String
    let expires_in: Int64?
    let token_type: String?
}

struct StorytellerBook: Decodable {
    let uuid: String
    let title: String
    let description: String?
    let language: String?
    let rating: Double?
    let createdAt: String
    let publicationDate: String?
    let authors: [StorytellerCreator]
    let narrators: [StorytellerCreator]
    let series: [StorytellerSeriesRelation]
    let tags: [StorytellerTag]
    let collections: [StorytellerCollectionRef]
    let status: StorytellerStatus?
    let position: StorytellerPosition?
    let ebook: StorytellerFormat?
    let audiobook: StorytellerFormat?
    let readaloud: StorytellerReadaloud?
}

struct StorytellerCreator: Decodable {
    let uuid: String
    let name: String
}

struct StorytellerSeriesRelation: Decodable {
    let uuid: String
    let name: String
    let position: Double?
}

struct StorytellerTag: Decodable {
    let uuid: String
    let name: String
}

struct StorytellerCollectionRef: Decodable {
    let uuid: String
    let name: String
}

struct StorytellerStatus: Decodable {
    let uuid: String
    let name: String
}

struct StorytellerFormat: Decodable {
    let uuid: String
    let filepath: String
    let missing: Bool
    let duration: Double?
    let manifest: StorytellerAudioManifest?
}

struct StorytellerReadaloud: Decodable {
    let uuid: String
    let filepath: String?
    let status: String
    let missing: Bool
    let currentStage: String
    let stageProgress: Double
    let queuePosition: Int?
    // Storyteller's RestartMode: "full", "transcription" or "sync" while a restart is queued.
    let restartPending: String?
    let duration: Double?
    let manifest: StorytellerAudioManifest?

    var isReady: Bool {
        status == "ALIGNED" && filepath != nil && !missing
    }

    var isProcessing: Bool {
        status == "PROCESSING" || status == "QUEUED"
    }
}

struct StorytellerLocator: Codable, Equatable {
    struct Locations: Codable, Equatable {
        struct DOMRange: Codable, Equatable {
            struct Point: Codable, Equatable {
                let cssSelector: String
                let textNodeIndex: Int
                let charOffset: Int?
            }

            let start: Point
            let end: Point?
        }

        let fragments: [String]?
        let progression: Double?
        let position: Int?
        let totalProgression: Double?
        let cssSelector: String?
        let partialCfi: String?
        let domRange: DOMRange?
    }

    struct Text: Codable, Equatable {
        let after: String?
        let before: String?
        let highlight: String?
    }

    let href: String
    let type: String
    let title: String?
    let locations: Locations?
    let text: Text?
}

struct StorytellerPosition: Decodable {
    struct LocatorComponents {
        let href: String
        let progression: Double?
        let totalProgression: Double?
        let audioFragmentTime: TimeInterval?
    }

    let timestamp: Int
    let locatorJSONString: String

    enum CodingKeys: String, CodingKey {
        case timestamp, locator
    }

    init(locatorJSONString: String, timestamp: Int) {
        self.timestamp = timestamp
        self.locatorJSONString = locatorJSONString
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Int.self, forKey: .timestamp)
        let locator = try container.decode(StorytellerLocator.self, forKey: .locator)
        locatorJSONString = String(decoding: try JSONEncoder().encode(locator), as: UTF8.self)
    }

    var locatorComponents: LocatorComponents? {
        guard let locator = try? JSONDecoder().decode(StorytellerLocator.self, from: Data(locatorJSONString.utf8)),
            let locations = locator.locations
        else { return nil }

        let audioFragmentTime = (locations.fragments ?? []).lazy.compactMap { fragment -> TimeInterval? in
            guard fragment.hasPrefix("t=") else { return nil }
            let value = fragment.dropFirst(2).split { $0 == "," || $0 == "&" }.first.map(String.init)
            return value.flatMap(Double.init)
        }.first

        return LocatorComponents(
            href: locator.href,
            progression: locations.progression,
            totalProgression: locations.totalProgression,
            audioFragmentTime: audioFragmentTime
        )
    }

    var totalProgression: Double? {
        locatorComponents?.totalProgression
    }
}

private struct LenientArrayWrapper<T: Decodable>: Decodable {
    let values: [T]
    let rejectedItems: [RejectedContentCandidate]

    init(from decoder: Decoder) throws {
        let decoded = try LossyDecodableArray<T>(from: decoder)
        values = decoded.values
        rejectedItems = decoded.rejectedItems
    }
}

struct StorytellerUser: Decodable {
    struct Permissions: Decodable {
        let bookList: Bool
        let bookProcess: Bool
    }

    let id: String
    let name: String
    let username: String
    let email: String?
    let permissions: Permissions
}

struct StorytellerCollection: Decodable {
    let uuid: String
    let name: String
    let description: String?
}

struct StorytellerSeries: Decodable {
    let uuid: String
    let name: String
    let description: String?
}

struct StorytellerAudioManifest: Decodable {
    let readingOrder: [StorytellerLink]
    let resources: [StorytellerLink]?
    let toc: [StorytellerLink]?
}

struct StorytellerLink: Decodable {
    let href: String
    let type: String?
    let title: String?
    let duration: Double?
    let children: [StorytellerLink]?
}
