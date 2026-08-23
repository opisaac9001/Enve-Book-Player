import Foundation
import Logging

class OPDSProvider: WholeSnapshotCatalogProvider, EbookDownloadProvider, @unchecked Sendable {
    var connection: ServerConnection

    var capabilities: ProviderCapabilities {
        [.fullImport, .downloads, .backgroundOperation]
    }

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func validateConnection() async throws -> Bool {
        let url = feedURL()
        AppLogger.network.info("[OPDS] validateConnection at \(url.redacted)")
        let request = makeRequest(url: url)
        let (data, response) = try await sendWithAuth(request)
        let status = response.statusCode
        AppLogger.network.info("[OPDS] validateConnection status=\(status)")
        AppLogger.network.debug("[OPDS] Content-Type: \(response.value(forHTTPHeaderField: "Content-Type") ?? "none")")

        if status == 401 || status == 403 {
            throw ProviderError.unauthorized
        }
        guard status == 200 else {
            let preview =
                String(data: data.prefix(300), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message =
                !preview.isEmpty && !preview.hasPrefix("<")
                ? preview
                : "Server returned HTTP \(status)"
            AppLogger.network.error("[OPDS] validateConnection failed: \(message)")
            throw ProviderError.serverError(message)
        }

        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let preview = String(data: data.prefix(500), encoding: .utf8) ?? ""

        if isOPDSContentType(contentType) || isOPDSBody(preview) {
            return true
        }

        AppLogger.network.error("[OPDS] validateConnection: 200 but no OPDS feed. Content-Type=\(contentType)")
        throw ProviderError.serverError(
            "The URL responded but is not an OPDS feed. Make sure your URL points directly to the OPDS endpoint."
        )
    }

    func fetchLibraries() async throws -> [Library] {
        [Library(id: "opds-root", name: connection.name, type: "book", providerId: connection.id)]
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        try await fetchFeed(url: feedURL(), visitedURLs: [], depth: 0)
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        Array(try await fetchBooks(libraryId: libraryId).prefix(limit))
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] { [] }
    func fetchSeries(libraryId: String) async throws -> [Series] { [] }
    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { [] }

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        guard let book = try await fetchBooks(libraryId: libraryId).first(where: { $0.id == bookId }) else {
            throw ProviderError.serverError("Book not found in catalog")
        }
        return book
    }

    func getAudioURL(for book: Book) -> URL? { nil }

    func getStreamingHeaders() -> [String: String] { [:] }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        throw ProviderError.notImplemented
    }

    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
        AppLogger.sync.debug(
            "Progress sync not supported for OPDS bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)); progress is local-only"
        )
    }

    func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let cached = LocalEbookImporter.shared.cachedEbook(forBookId: book.id) {
            onProgress?(1)
            return cached
        }

        guard let downloadLink = book.partKey, let downloadURL = URL(string: downloadLink) else {
            throw ProviderError.serverError("No download link available for this book")
        }

        var request = URLRequest(url: downloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let credential: URLCredential? = {
            guard let u = connection.username, let p = connection.password, !u.isEmpty else { return nil }
            return URLCredential(user: u, password: p, persistence: .forSession)
        }()

        let response: HTTPURLResponse
        let data: Data

        if let onProgress {

            let delegate = URLSessionDownloadProgressDelegate(progressHandler: onProgress, credential: credential)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (tempURL, httpResp) = try await delegate.awaitResult {
                session.downloadTask(with: request)
            }
            response = httpResp
            data = try Data(contentsOf: tempURL)
            try? FileManager.default.removeItem(at: tempURL)
        } else {
            (data, response) = try await sendWithAuth(request)
        }

        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to download ebook (HTTP \(response.statusCode))")
        }

        let ext = detectEbookExtension(response: response, downloadURL: downloadURL) ?? "epub"
        let filename = "\(book.title.replacingOccurrences(of: "/", with: "-")).\(ext)"
        return try LocalEbookImporter.shared.cacheRemoteEbook(
            data: data,
            preferredFilename: filename,
            bookIdentifier: book.id
        )
    }

    func updateEbookProgress(for book: Book, progress: Double, epubLocator: String?) async throws {
        AppLogger.sync.debug(
            "Ebook progress sync not supported for OPDS bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)); progress is local-only"
        )
    }

    func fetchCoverImage(url: URL) async throws -> Data {
        let request = makeRequest(url: url)
        let (data, response) = try await sendWithAuth(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Cover fetch failed HTTP \(response.statusCode)")
        }
        return data
    }

    private let maximumTraversalDepth = 4
    private let maximumNavigationLinksPerFeed = 24

    private func fetchFeed(url: URL, visitedURLs: Set<String>, depth: Int) async throws -> [Book] {
        guard depth <= maximumTraversalDepth else { return [] }
        guard !visitedURLs.contains(url.absoluteString) else { return [] }

        let request = makeRequest(url: url)
        let (data, response) = try await sendWithAuth(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("OPDS feed returned HTTP \(response.statusCode)")
        }

        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let contents: FeedContents
        if isOPDS2ContentType(contentType) || isOPDS2Body(data) {
            contents = try parseOPDS2(data: data, feedURL: url)
        } else {
            contents = try parseOPDS1(data: data, feedURL: url)
        }

        var visited = visitedURLs
        visited.insert(url.absoluteString)

        if !contents.books.isEmpty {
            var allBooks = contents.books
            if let nextURL = contents.nextLink {
                let nextBooks = try await fetchFeed(url: nextURL, visitedURLs: visited, depth: depth + 1)
                allBooks.append(contentsOf: nextBooks)
            }
            return deduplicateBooks(allBooks)
        }

        var books: [Book] = []
        for navURL in contents.navigationLinks.prefix(maximumNavigationLinksPerFeed) {
            let nestedBooks = try await fetchFeed(url: navURL, visitedURLs: visited, depth: depth + 1)
            books.append(contentsOf: nestedBooks)
        }
        return deduplicateBooks(books)
    }

    private func parseOPDS1(data: Data, feedURL: URL) throws -> FeedContents {
        OPDSAtomParser(data: data, baseURL: feedURL, providerId: connection.id).parseFeed()
    }

    private func parseOPDS2(data: Data, feedURL: URL) throws -> FeedContents {
        let feed = try JSONDecoder().decode(OPDS2Feed.self, from: data)

        var books = feed.publications?.compactMap { buildBook(from: $0, baseURL: feedURL) } ?? []

        books.append(contentsOf: feed.catalogs?.compactMap { buildBook(from: $0, baseURL: feedURL) } ?? [])
        var navLinks = extractNavLinks(from: feed.navigation, baseURL: feedURL)
        navLinks.append(contentsOf: extractNavLinksFromFeedLinks(feed.links, baseURL: feedURL))

        for group in feed.groups ?? [] {
            books.append(contentsOf: group.publications?.compactMap { buildBook(from: $0, baseURL: feedURL) } ?? [])
            navLinks.append(contentsOf: extractNavLinks(from: group.navigation, baseURL: feedURL))
            navLinks.append(contentsOf: extractNavLinksFromFeedLinks(group.links, baseURL: feedURL))
        }

        let nextLink = feed.links?.first(where: { $0.rel == "next" })?.href.flatMap { resolveURL($0, baseURL: feedURL) }
        let searchLink = feed.links?.first(where: { $0.rel == "search" })?.href.flatMap { resolveURL($0, baseURL: feedURL)?.absoluteString }

        return FeedContents(
            books: deduplicateBooks(books),
            navigationLinks: Array(Set(navLinks)),
            nextLink: nextLink,
            searchTemplate: searchLink,
            facets: feed.facets
        )
    }

    private func buildBook(from pub: OPDS2Publication, baseURL: URL) -> Book? {
        let allLinks = (pub.links ?? []) + (pub.images ?? [])
        guard let acqLink = allLinks.first(where: { isAcquisitionRel($0.rel) || isAcquisitionType($0.type) }),
            let href = acqLink.href,
            let downloadURL = resolveURL(href, baseURL: baseURL)
        else { return nil }

        let coverURL = (pub.images ?? [])
            .first(where: { isImageRel($0.rel) || normalizeImageType($0.type)?.hasPrefix("image/") == true })
            .flatMap { $0.href.flatMap { resolveURL($0, baseURL: baseURL) } }

        var seriesInfo: SeriesInfo?
        if let s = pub.metadata.belongsTo?.series?.first {
            seriesInfo = SeriesInfo(name: s.name, sequence: s.position.map { String($0) })
        } else if let c = pub.metadata.belongsTo?.collection?.first {
            seriesInfo = SeriesInfo(name: c.name, sequence: c.position.map { String($0) })
        }

        let publishedYear: Int? = pub.metadata.published.flatMap {
            $0.split(separator: "-").first.flatMap { Int($0) }
        }

        let mediaType = OPDSMediaClassifier.mediaType(
            mimeType: acqLink.type,
            titleHint: acqLink.title,
            url: downloadURL
        )

        return Book(
            id: pub.metadata.identifier ?? downloadURL.absoluteString,
            title: pub.metadata.title,
            author: pub.metadata.author?.map(\.name).joined(separator: ", ")
                ?? pub.metadata.translator?.map(\.name).joined(separator: ", "),
            narrator: pub.metadata.narrator?.map(\.name).joined(separator: ", "),
            seriesInfo: seriesInfo,
            duration: 0,
            coverURL: coverURL,
            partKey: downloadURL.absoluteString,
            mediaType: mediaType,
            description: pub.metadata.description,
            genres: pub.metadata.subject?.map(\.name),
            chapters: [],
            publisher: pub.metadata.publisher,
            progress: 0,
            currentTime: 0,
            isFinished: false,
            lastUpdate: Date(),
            libraryId: "opds-root",
            providerId: connection.id,
            source: .opds,
            publishedYear: publishedYear,
            language: pub.metadata.language?.first
        )
    }

    private func extractNavLinks(from entries: [OPDS2Publication]?, baseURL: URL) -> [URL] {
        (entries ?? []).compactMap { pub in
            let allLinks = (pub.links ?? []) + (pub.images ?? [])
            return allLinks.first(where: { isNavigationLink(rel: $0.rel, type: $0.type) })
                .flatMap { $0.href.flatMap { resolveURL($0, baseURL: baseURL) } }
        }
    }

    private func extractNavLinksFromFeedLinks(_ links: [OPDS2Link]?, baseURL: URL) -> [URL] {
        (links ?? []).compactMap { link in
            guard isNavigationLink(rel: link.rel, type: link.type), let href = link.href else { return nil }
            return resolveURL(href, baseURL: baseURL)
        }
    }

    private func isImageRel(_ rel: String?) -> Bool {
        guard let rel else { return false }

        if rel.contains("http://opds-spec.org/image") { return true }

        if rel == "http://opds-spec.org/cover" { return true }
        if rel == "http://opds-spec.org/thumbnail" { return true }

        if rel == "x-stanza-cover-image" { return true }
        if rel == "x-stanza-cover-image-thumbnail" { return true }
        return false
    }

    private func normalizeImageType(_ type: String?) -> String? {
        guard let type else { return nil }
        return type == "image/jpg" ? "image/jpeg" : type
    }

    private func isAcquisitionRel(_ rel: String?) -> Bool {
        guard let rel else { return false }
        return rel.contains("opds-spec.org/acquisition")
    }

    private func isAcquisitionType(_ type: String?) -> Bool {
        guard let type else { return false }
        let t = type.lowercased()
        return [
            "application/epub+zip",
            "application/pdf",
            "application/x-cbz",
            "application/vnd.comicbook+zip",
            "application/x-cbr",
            "application/vnd.comicbook-rar",
            "application/x-mobipocket-ebook",
            "application/x-mobi8-ebook",
            "audio/mpeg",
            "audio/mp4",
            "audio/ogg",
        ].contains(t)
    }

    private func isNavigationLink(rel: String?, type: String?) -> Bool {
        guard !isAcquisitionRel(rel) && !isAcquisitionType(type) else { return false }
        let r = rel?.lowercased() ?? ""
        let t = type?.lowercased() ?? ""
        if t.hasPrefix("image/") { return false }
        if r.contains("navigation") || r.contains("subsection") || r.contains("collection") { return true }
        return t.contains("atom+xml") || t.contains("opds+json") || t.contains("application/json")
    }

    private func isOPDSContentType(_ ct: String) -> Bool {
        let t = ct.lowercased()
        return t.contains("application/atom+xml")
            || t.contains("application/xml")
            || t.contains("text/xml")
            || t.contains("application/opds+json")
            || t.contains("application/opds-publication+json")
            || t.contains("application/vnd.opds")
    }

    private func isOPDS2ContentType(_ ct: String) -> Bool {
        let t = ct.lowercased()
        return t.contains("application/opds+json")
            || t.contains("application/opds-publication+json")
    }

    private func isOPDSBody(_ preview: String) -> Bool {
        preview.contains("<feed") || preview.contains("\"metadata\"")
    }

    private func isOPDS2Body(_ data: Data) -> Bool {
        let preview = String(data: data.prefix(200), encoding: .utf8) ?? ""
        return preview.contains("\"metadata\"") || preview.contains("\"publications\"")
    }

    private func feedURL() -> URL {
        var str = connection.url.trimmingCharacters(in: .whitespacesAndNewlines)
        while str.hasSuffix("/") { str.removeLast() }
        if !str.hasPrefix("http") { str = "http://\(str)" }
        return URL(string: str) ?? URL(string: "http://invalid")!
    }

    private func resolveURL(_ href: String, baseURL: URL) -> URL? {
        let allowed: Set<String> = ["http", "https"]
        if let abs = URL(string: href), let scheme = abs.scheme?.lowercased(), allowed.contains(scheme) {
            return abs
        }
        guard let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL,
            let scheme = resolved.scheme?.lowercased(), allowed.contains(scheme)
        else { return nil }
        return resolved
    }

    private func deduplicateBooks(_ books: [Book]) -> [Book] {
        var seen = Set<String>()
        return books.filter { seen.insert($0.uniqueId).inserted }
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "application/atom+xml;q=0.9, application/opds+json;q=0.9, application/json;q=0.8, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )

        if let token = connection.token, !token.isEmpty,
            connection.username == nil || connection.username?.isEmpty == true
        {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func sendWithAuth(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let delegate = OPDSSessionDelegate(
            username: connection.username,
            password: connection.password,
            token: connection.token
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        return (data, http)
    }

    private func detectEbookExtension(response: HTTPURLResponse, downloadURL: URL) -> String? {
        if let mime = response.mimeType, let ext = mimeToExtension(mime) { return ext }
        if let suggested = response.suggestedFilename, let ext = fileExtension(from: suggested) { return ext }
        if let cd = response.value(forHTTPHeaderField: "Content-Disposition"),
            let ext = fileExtension(from: cd)
        {
            return ext
        }
        let urlExt = downloadURL.pathExtension.lowercased()
        return EbookFormat.from(fileExtension: urlExt) != nil ? urlExt : nil
    }

    private func mimeToExtension(_ mime: String) -> String? {
        switch mime.lowercased() {
        case "application/epub+zip": return "epub"
        case "application/pdf": return "pdf"
        case "application/x-cbz", "application/vnd.comicbook+zip",
            "application/zip", "application/x-zip-compressed":
            return "cbz"
        case "application/x-cbr", "application/vnd.comicbook-rar",
            "application/x-rar-compressed", "application/vnd.rar":
            return "cbr"
        default: return nil
        }
    }

    private func fileExtension(from value: String) -> String? {
        let normalized = value.lowercased()
        for ext in EbookFormat.allExtensions where normalized.contains(".\(ext)") {
            return ext
        }
        return nil
    }

    fileprivate struct FeedContents {
        let books: [Book]
        let navigationLinks: [URL]
        let nextLink: URL?
        let searchTemplate: String?
        let facets: [OPDS2FacetGroup]?
    }

    fileprivate struct OPDS2Feed: Decodable {
        let metadata: OPDS2FeedMetadata?
        let publications: [OPDS2Publication]?
        let navigation: [OPDS2Publication]?
        let groups: [OPDS2Group]?
        let links: [OPDS2Link]?
        let facets: [OPDS2FacetGroup]?
        let catalogs: [OPDS2Publication]?
    }

    fileprivate struct OPDS2FeedMetadata: Decodable {
        let title: String?
    }

    fileprivate struct OPDS2Publication: Decodable {
        let metadata: OPDS2Metadata
        let links: [OPDS2Link]?
        let images: [OPDS2Link]?
    }

    fileprivate struct OPDS2Group: Decodable {
        let metadata: OPDS2FeedMetadata?
        let publications: [OPDS2Publication]?
        let navigation: [OPDS2Publication]?
        let links: [OPDS2Link]?
    }

    fileprivate struct OPDS2FacetGroup: Decodable {
        let metadata: OPDS2FeedMetadata?
        let links: [OPDS2Link]?
    }

    fileprivate struct OPDS2Metadata: Decodable {
        let identifier: String?
        let title: String
        let author: [OPDS2Contributor]?
        let translator: [OPDS2Contributor]?
        let narrator: [OPDS2Contributor]?
        let description: String?
        let publisher: String?
        let belongsTo: OPDS2BelongsTo?
        let subject: [OPDS2Subject]?
        let language: [String]?
        let published: String?

        enum CodingKeys: String, CodingKey {
            case identifier, title, author, translator, narrator,
                description, publisher, belongsTo, subject, language, published
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
            title = try c.decode(String.self, forKey: .title)
            author = try OPDS2Contributor.decodeFlexibly(c, key: .author)
            translator = try OPDS2Contributor.decodeFlexibly(c, key: .translator)
            narrator = try OPDS2Contributor.decodeFlexibly(c, key: .narrator)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            publisher =
                (try? c.decodeIfPresent(String.self, forKey: .publisher))
                ?? (try? c.decodeIfPresent(OPDS2Contributor.self, forKey: .publisher))?.name
            belongsTo = try c.decodeIfPresent(OPDS2BelongsTo.self, forKey: .belongsTo)
            subject = try OPDS2Subject.decodeFlexibly(c, key: .subject)
            language =
                (try? c.decodeIfPresent([String].self, forKey: .language))
                ?? (try? c.decodeIfPresent(String.self, forKey: .language)).map { [$0] }
            published = try c.decodeIfPresent(String.self, forKey: .published)
        }
    }

    fileprivate struct OPDS2BelongsTo: Decodable {
        let series: [OPDS2Collection]?
        let collection: [OPDS2Collection]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            series = try OPDS2Collection.decodeFlexibly(c, key: .series)
            collection = try OPDS2Collection.decodeFlexibly(c, key: .collection)
        }
        enum CodingKeys: String, CodingKey { case series, collection }
    }

    fileprivate struct OPDS2Collection: Decodable {
        let name: String
        let position: Double?

        init(from decoder: Decoder) throws {
            if let str = try? decoder.singleValueContainer().decode(String.self) {
                name = str; position = nil
            } else {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                position = try c.decodeIfPresent(Double.self, forKey: .position)
            }
        }
        enum CodingKeys: String, CodingKey { case name, position }

        static func decodeFlexibly<K: CodingKey>(
            _ container: KeyedDecodingContainer<K>,
            key: K
        ) throws -> [OPDS2Collection]? {
            if let arr = try? container.decodeIfPresent([OPDS2Collection].self, forKey: key) { return arr }
            if let one = try? container.decodeIfPresent(OPDS2Collection.self, forKey: key) { return [one] }
            return nil
        }
    }

    fileprivate struct OPDS2Subject: Decodable {
        let name: String

        init(from decoder: Decoder) throws {
            if let str = try? decoder.singleValueContainer().decode(String.self) {
                name = str
            } else {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            }
        }
        enum CodingKeys: String, CodingKey { case name }

        static func decodeFlexibly<K: CodingKey>(
            _ container: KeyedDecodingContainer<K>,
            key: K
        ) throws -> [OPDS2Subject]? {
            if let arr = try? container.decodeIfPresent([OPDS2Subject].self, forKey: key) { return arr }
            if let one = try? container.decodeIfPresent(OPDS2Subject.self, forKey: key) { return [one] }
            return nil
        }
    }

    fileprivate struct OPDS2Contributor: Decodable {
        let name: String

        init(from decoder: Decoder) throws {
            if let str = try? decoder.singleValueContainer().decode(String.self) {
                name = str
            } else {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
            }
        }
        enum CodingKeys: String, CodingKey { case name }

        static func decodeFlexibly<K: CodingKey>(
            _ container: KeyedDecodingContainer<K>,
            key: K
        ) throws -> [OPDS2Contributor]? {
            if let arr = try? container.decodeIfPresent([OPDS2Contributor].self, forKey: key) { return arr }
            if let one = try? container.decodeIfPresent(OPDS2Contributor.self, forKey: key) { return [one] }
            return nil
        }
    }

    fileprivate struct OPDS2Link: Decodable {
        let href: String?
        let type: String?
        let rel: String?
        let templated: Bool?
        let title: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            href = try c.decodeIfPresent(String.self, forKey: .href)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            rel =
                (try? c.decodeIfPresent([String].self, forKey: .rel))?.first
                ?? (try? c.decodeIfPresent(String.self, forKey: .rel))
            templated = try c.decodeIfPresent(Bool.self, forKey: .templated)
            title = try c.decodeIfPresent(String.self, forKey: .title)
        }
        enum CodingKeys: String, CodingKey { case href, type, rel, templated, title }
    }
}

private enum OPDSMediaClassifier {
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "flac", "ogg", "opus", "wav", "aac", "aax",
    ]

    static func mediaType(mimeType: String?, titleHint: String?, url: URL?) -> AppMediaType {
        let mime = mimeType?.lowercased() ?? ""
        let hint = titleHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if mime.hasPrefix("audio/") || mime.contains("audiobook") {
            return .audiobook
        }
        if let hint, audioExtensions.contains(hint) {
            return .audiobook
        }
        if let ext = url?.pathExtension.lowercased(), audioExtensions.contains(ext) {
            return .audiobook
        }
        return .ebook
    }
}

private class OPDSAtomParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let baseURL: URL
    private let providerId: UUID
    private var books: [Book] = []
    private var navigationLinks: [URL] = []
    private var nextLink: URL?
    private var searchTemplate: String?

    private var currentElement = ""
    private var currentEntry: OPDSEntry?
    private var currentText = ""
    private var insideEntry = false
    private var insideAuthor = false

    init(data: Data, baseURL: URL, providerId: UUID) {
        self.data = data
        self.baseURL = baseURL
        self.providerId = providerId
    }

    func parseFeed() -> OPDSProvider.FeedContents {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return OPDSProvider.FeedContents(
            books: books,
            navigationLinks: navigationLinks,
            nextLink: nextLink,
            searchTemplate: searchTemplate,
            facets: nil
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        currentElement = localName(elementName)
        currentText = ""

        if currentElement == "entry" {
            insideEntry = true
            currentEntry = OPDSEntry()
            return
        }
        if currentElement == "author" && insideEntry {
            insideAuthor = true
            return
        }

        let qualName = qualifiedName ?? ""
        let isSchemaSeriesElement =
            qualName == "schema:Series"
            || (namespaceURI == "http://schema.org" && currentElement == "Series")
        if isSchemaSeriesElement && insideEntry {
            let name = attributes["schema:name"] ?? attributes["name"]
            let posStr = attributes["schema:position"] ?? attributes["position"]
            currentEntry?.seriesName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            currentEntry?.seriesPosition = posStr.flatMap { Double($0) }
            return
        }

        if currentElement == "link" {
            let rel = attributes["rel"] ?? ""
            let href = attributes["href"] ?? ""
            let type = attributes["type"] ?? ""
            let resolved = resolveHref(href)

            if insideEntry {

                if isAcquisitionRel(rel) || isAcquisitionType(type) {
                    if currentEntry?.downloadHref == nil {
                        currentEntry?.downloadHref = resolved
                        currentEntry?.downloadType = type
                        currentEntry?.downloadTitle = attributes["title"]
                    }

                } else if rel.contains("http://opds-spec.org/image")
                    || rel == "http://opds-spec.org/cover"
                    || rel == "http://opds-spec.org/thumbnail"
                    || rel == "x-stanza-cover-image"
                    || rel == "x-stanza-cover-image-thumbnail"
                    || rel.contains("thumbnail")
                    || type.hasPrefix("image/")
                    || type == "image/jpg"
                {
                    if currentEntry?.imageHref == nil {
                        currentEntry?.imageHref = resolved
                    }

                } else if isNavigationRel(rel) || isNavigationType(type) {
                    if currentEntry?.downloadHref == nil, let navURL = URL(string: resolved) {
                        currentEntry?.navigationHref = navURL
                    }
                }

            } else {

                if rel == "next" {
                    nextLink = URL(string: resolved)
                } else if rel == "search"
                    && (type.contains("opensearchdescription+xml") || type.contains("opds+osd"))
                {
                    searchTemplate = resolved
                }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let name = localName(elementName)
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "entry":
            if let entry = currentEntry {
                if let downloadHref = entry.downloadHref {
                    let seriesInfo: SeriesInfo? = {
                        guard let name = entry.seriesName, !name.isEmpty else { return nil }
                        let sequence = entry.seriesPosition.map { pos -> String in
                            pos.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(pos)) : String(pos)
                        }
                        return SeriesInfo(name: name, sequence: sequence)
                    }()
                    books.append(
                        Book(
                            id: entry.id ?? downloadHref,
                            title: entry.title ?? "Unknown",
                            author: entry.authors.isEmpty ? nil : entry.authors.joined(separator: ", "),
                            narrator: nil,
                            seriesInfo: seriesInfo,
                            duration: 0,
                            coverURL: entry.imageHref.flatMap { URL(string: $0) },
                            partKey: downloadHref,
                            mediaType: OPDSMediaClassifier.mediaType(
                                mimeType: entry.downloadType,
                                titleHint: entry.downloadTitle,
                                url: URL(string: downloadHref)
                            ),
                            description: entry.summary,
                            genres: [],
                            chapters: [],
                            publisher: nil,
                            progress: 0,
                            currentTime: 0,
                            isFinished: false,
                            lastUpdate: Date(),
                            libraryId: "opds-root",
                            providerId: providerId,
                            source: .opds,
                            rawMetadata: nil
                        )
                    )
                } else if let navURL = entry.navigationHref {
                    navigationLinks.append(navURL)
                }
            }
            currentEntry = nil
            insideEntry = false

        case "author":
            insideAuthor = false

        default:
            guard insideEntry else { break }
            switch name {
            case "id": currentEntry?.id = trimmed
            case "title": currentEntry?.title = trimmed
            case "name" where insideAuthor:
                if !trimmed.isEmpty { currentEntry?.authors.append(trimmed) }
            case "summary", "content":
                if currentEntry?.summary == nil { currentEntry?.summary = trimmed }
            default: break
            }
        }
    }

    private func isAcquisitionRel(_ rel: String) -> Bool {
        rel.contains("opds-spec.org/acquisition")
    }

    private func isAcquisitionType(_ type: String) -> Bool {
        let t = type.lowercased()
        return [
            "application/epub+zip",
            "application/pdf",
            "application/x-cbz",
            "application/vnd.comicbook+zip",
            "application/x-cbr",
            "application/vnd.comicbook-rar",
            "application/x-mobipocket-ebook",
            "application/x-mobi8-ebook",
            "audio/mpeg",
            "audio/mp4",
            "audio/ogg",
        ].contains(t)
    }

    private func isNavigationRel(_ rel: String) -> Bool {
        rel == "subsection" || rel == "alternate" || rel == "related"
            || rel.contains("opds-spec.org/facet")
            || rel.contains("opds-spec.org/sort")
    }

    private func isNavigationType(_ type: String) -> Bool {
        let t = type.lowercased()
        return t.contains("atom+xml") || t.contains("opds+json")
    }

    private func localName(_ element: String) -> String {
        guard let idx = element.lastIndex(of: ":") else { return element }
        return String(element[element.index(after: idx)...])
    }

    private func resolveHref(_ href: String) -> String {
        guard !href.hasPrefix("http://"), !href.hasPrefix("https://") else { return href }
        return URL(string: href, relativeTo: baseURL)?.absoluteString ?? href
    }
}

private struct OPDSEntry {
    var id: String?
    var title: String?
    var authors: [String] = []
    var summary: String?
    var downloadHref: String?
    var downloadType: String?
    var downloadTitle: String?
    var imageHref: String?
    var navigationHref: URL?

    var seriesName: String?
    var seriesPosition: Double?
}

private final class OPDSSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let username: String?
    private let password: String?
    private let token: String?

    init(username: String?, password: String?, token: String?) {
        self.username = username
        self.password = password
        self.token = token
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod

        if method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest {
            if let u = username, !u.isEmpty, let p = password {
                completionHandler(
                    .useCredential,
                    URLCredential(user: u, password: p, persistence: .forSession)
                )
                return
            }
        }

        if method == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        {

            if NetworkHostUtils.isLocalNetworkHost(challenge.protectionSpace.host) {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
        }

        completionHandler(.performDefaultHandling, nil)
    }
}
