import Foundation

final class RSSPodcastParser: NSObject, XMLParserDelegate {

    static let shared = RSSPodcastParser()

    struct ParsedPodcastFeed {
        var title: String = ""
        var author: String?
        var description: String?
        var coverURL: URL?
        var link: String?
        var language: String?
        var episodes: [ParsedEpisode] = []
    }

    struct ParsedEpisode: Identifiable {
        var id: String
        var title: String = ""
        var description: String?
        var audioURL: URL?
        var duration: TimeInterval = 0
        var publishedDate: Date?
        var season: String?
        var episode: String?
        var episodeType: String?
        var fileSize: Int64?
        var mimeType: String?
        var coverURL: URL?
    }

    private var currentFeed = ParsedPodcastFeed()
    private var currentEpisode: ParsedEpisode?
    private var currentElement = ""
    private var currentText = ""
    private var isInsideItem = false
    private var isInsideChannel = false
    private var isInsideImage = false

    func parseFeed(from url: URL) async throws -> ParsedPodcastFeed {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw RSSError.fetchFailed
        }
        return try parseFeed(from: data)
    }

    func parseFeed(from feedURL: String) async throws -> ParsedPodcastFeed {
        guard let url = URL(string: feedURL) else {
            throw RSSError.invalidURL
        }
        return try await parseFeed(from: url)
    }

    func parseFeed(from data: Data) throws -> ParsedPodcastFeed {
        currentFeed = ParsedPodcastFeed()
        currentEpisode = nil
        currentElement = ""
        currentText = ""
        isInsideItem = false
        isInsideChannel = false
        isInsideImage = false

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw RSSError.parseFailed(parser.parserError?.localizedDescription ?? "Unknown XML error")
        }

        return currentFeed
    }

    func convertToBooks(
        feed: ParsedPodcastFeed,
        feedURL: String,
        providerId: UUID = UUID()
    ) -> [Book] {
        return feed.episodes.compactMap { episode -> Book? in
            guard let audioURL = episode.audioURL else { return nil }

            return Book(
                id: "rss_\(episode.id)",
                title: episode.title,
                author: feed.title,
                thumb: (episode.coverURL ?? feed.coverURL)?.absoluteString,
                partKey: audioURL.absoluteString,
                duration: episode.duration > 0 ? episode.duration : nil,
                isPodcastEpisode: true,
                episodeId: episode.id,
                podcastLibraryItemId: feedURL,
                podcastName: feed.title,
                description: episode.description?.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression),
                addedAt: episode.publishedDate,
                currentTime: 0,
                isFinished: false,
                lastUpdate: Date(),
                providerId: providerId,
                libraryId: "rss_\(feedURL.hashValue)"
            )
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "channel":
            isInsideChannel = true

        case "item":
            isInsideItem = true
            currentEpisode = ParsedEpisode(id: UUID().uuidString)

        case "enclosure":
            if isInsideItem {
                if let urlString = attributeDict["url"], let url = URL(string: urlString) {
                    currentEpisode?.audioURL = url
                }
                if let lengthStr = attributeDict["length"], let length = Int64(lengthStr) {
                    currentEpisode?.fileSize = length
                }
                currentEpisode?.mimeType = attributeDict["type"]
            }

        case "itunes:image":
            if let href = attributeDict["href"], let url = URL(string: href) {
                if isInsideItem {
                    currentEpisode?.coverURL = url
                } else if isInsideChannel {
                    currentFeed.coverURL = url
                }
            }

        case "image":
            if isInsideChannel && !isInsideItem {
                isInsideImage = true
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if isInsideItem {
            switch elementName {
            case "title":
                currentEpisode?.title = trimmed
            case "description", "content:encoded":
                if currentEpisode?.description == nil || elementName == "content:encoded" {
                    currentEpisode?.description = trimmed
                }
            case "guid":
                if !trimmed.isEmpty {
                    currentEpisode?.id = trimmed
                }
            case "pubDate":
                currentEpisode?.publishedDate = parseRSSDate(trimmed)
            case "itunes:duration":
                currentEpisode?.duration = parseDuration(trimmed)
            case "itunes:season":
                currentEpisode?.season = trimmed
            case "itunes:episode":
                currentEpisode?.episode = trimmed
            case "itunes:episodeType":
                currentEpisode?.episodeType = trimmed
            case "item":
                if let episode = currentEpisode, episode.audioURL != nil {
                    currentFeed.episodes.append(episode)
                }
                currentEpisode = nil
                isInsideItem = false
            default:
                break
            }
        } else if isInsideChannel {
            switch elementName {
            case "title":
                if !isInsideImage {
                    currentFeed.title = trimmed
                }
            case "itunes:author", "author", "managingEditor":
                if currentFeed.author == nil {
                    currentFeed.author = trimmed
                }
            case "description", "itunes:summary":
                if currentFeed.description == nil {
                    currentFeed.description = trimmed
                }
            case "link":
                if !isInsideImage {
                    currentFeed.link = trimmed
                }
            case "language":
                currentFeed.language = trimmed
            case "url":
                if isInsideImage, let url = URL(string: trimmed), currentFeed.coverURL == nil {
                    currentFeed.coverURL = url
                }
            case "image":
                isInsideImage = false
            case "channel":
                isInsideChannel = false
            default:
                break
            }
        }
    }

    private func parseDuration(_ string: String) -> TimeInterval {
        let parts = string.split(separator: ":")
        switch parts.count {
        case 1:
            return TimeInterval(string) ?? 0
        case 2:
            let minutes = TimeInterval(parts[0]) ?? 0
            let seconds = TimeInterval(parts[1]) ?? 0
            return minutes * 60 + seconds
        case 3:
            let hours = TimeInterval(parts[0]) ?? 0
            let minutes = TimeInterval(parts[1]) ?? 0
            let seconds = TimeInterval(parts[2]) ?? 0
            return hours * 3600 + minutes * 60 + seconds
        default:
            return 0
        }
    }

    private func parseRSSDate(_ string: String) -> Date? {
        let formatters: [DateFormatter] = [
            {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
                return f
            }(),
            {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                return f
            }(),
            {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
                return f
            }(),
        ]
        for formatter in formatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    enum RSSError: Error, LocalizedError {
        case invalidURL
        case fetchFailed
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid feed URL"
            case .fetchFailed: return "Failed to fetch RSS feed"
            case .parseFailed(let reason): return "RSS parsing failed: \(reason)"
            }
        }
    }
}
