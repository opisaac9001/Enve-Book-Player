import Foundation

nonisolated struct PodcastOPMLEpisode: Equatable, Sendable {
    var title: String?
    var guid: String?
    var enclosureURL: String?
    var publishedAt: Date?
    var updatedAt: Date?
    var position: TimeInterval?
    var isPlayed = false

    var hasListeningState: Bool { isPlayed || (position ?? 0) > 0 }
}

nonisolated struct PodcastOPMLFeed: Equatable, Sendable {
    var title: String
    var feedURL: String
    var siteURL: String?
    /// False only when the file says so explicitly (Overcast lists unsubscribed shows that still carry history).
    var isSubscribed = true
    var episodes: [PodcastOPMLEpisode] = []
}

nonisolated struct PodcastOPMLDocument: Equatable, Sendable {
    var feeds: [PodcastOPMLFeed]
    var invalidFeedCount: Int
}

nonisolated enum PodcastOPMLError: LocalizedError, Equatable {
    case unreadable
    case empty
    case tooLarge
    case unsupportedEncoding
    case documentTypeNotAllowed
    case notOPML
    case tooComplex
    case malformed(line: Int)
    case noFeeds

    var errorDescription: String? {
        switch self {
        case .unreadable: "The file couldn't be opened. Make sure it's downloaded and try again."
        case .empty: "The file is empty."
        case .tooLarge: "The file is larger than 16 MB, which is more than a podcast export should need."
        case .unsupportedEncoding: "The file isn't UTF-8 text. Export it again or save it as UTF-8."
        case .documentTypeNotAllowed: "The file declares a document type or entities, which OPML files never need. It wasn't opened."
        case .notOPML: "This isn't an OPML file."
        case .tooComplex: "The file has too many entries or is nested too deeply to import safely."
        case .malformed(let line): "The file is damaged near line \(line) and couldn't be read."
        case .noFeeds: "The file doesn't contain any podcast feeds."
        }
    }
}

nonisolated final class PodcastOPMLParser: NSObject, XMLParserDelegate {
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumOutlines = 200_000
    static let maximumFeeds = 5_000
    static let maximumDepth = 32

    private enum Frame {
        case other
        case feed(Int)
    }

    private var feeds: [PodcastOPMLFeed] = []
    private var invalidFeedCount = 0
    private var frames: [Frame] = []
    private var outlineCount = 0
    private var sawRoot = false
    private var failure: PodcastOPMLError?
    private let isoFormatter = ISO8601DateFormatter()
    private let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let rfc822Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    static func parse(_ data: Data) throws(PodcastOPMLError) -> PodcastOPMLDocument {
        guard !data.isEmpty else { throw .empty }
        guard data.count <= maximumBytes else { throw .tooLarge }
        guard String(data: data, encoding: .utf8) != nil else { throw .unsupportedEncoding }
        let prefix = Array(data.prefix(4))
        if prefix.starts(with: [0xFE, 0xFF]) || prefix.starts(with: [0xFF, 0xFE]) || prefix.contains(0) {
            throw .unsupportedEncoding
        }
        // XMLParser still expands internal entities, so DTDs are refused before parsing to rule out entity bombs.
        for marker in ["<!DOCTYPE", "<!doctype", "<!ENTITY", "<!entity"] where data.range(of: Data(marker.utf8)) != nil {
            throw .documentTypeNotAllowed
        }

        let delegate = PodcastOPMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        let succeeded = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard succeeded else { throw .malformed(line: max(parser.lineNumber, 1)) }
        guard delegate.sawRoot else { throw .notOPML }
        guard !delegate.feeds.isEmpty else { throw .noFeeds }
        return PodcastOPMLDocument(feeds: delegate.feeds, invalidFeedCount: delegate.invalidFeedCount)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard frames.count < Self.maximumDepth else { return fail(.tooComplex, parser) }
        if !sawRoot {
            guard elementName.lowercased() == "opml" else { return fail(.notOPML, parser) }
            sawRoot = true
            frames.append(.other)
            return
        }
        guard elementName.lowercased() == "outline" else {
            frames.append(.other)
            return
        }
        outlineCount += 1
        guard outlineCount <= Self.maximumOutlines else { return fail(.tooComplex, parser) }

        let attributes = Dictionary(attributeDict.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        if let rawFeedURL = attributes["xmlurl"] {
            guard let feedURL = PodcastFeedURL.canonical(rawFeedURL) else {
                invalidFeedCount += 1
                frames.append(.other)
                return
            }
            guard feeds.count < Self.maximumFeeds else { return fail(.tooComplex, parser) }
            feeds.append(
                PodcastOPMLFeed(
                    title: nonEmpty(attributes["title"]) ?? nonEmpty(attributes["text"]) ?? URL(string: feedURL)?.host ?? feedURL,
                    feedURL: feedURL,
                    siteURL: nonEmpty(attributes["htmlurl"]),
                    isSubscribed: attributes["subscribed"].map(isTrue) ?? true
                )
            )
            frames.append(.feed(feeds.count - 1))
            return
        }

        if let feedIndex = enclosingFeedIndex, isEpisode(attributes) {
            feeds[feedIndex].episodes.append(episode(from: attributes))
        }
        frames.append(.other)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = frames.popLast()
    }

    private var enclosingFeedIndex: Int? {
        for frame in frames.reversed() {
            if case .feed(let index) = frame { return index }
        }
        return nil
    }

    private func isEpisode(_ attributes: [String: String]) -> Bool {
        attributes["type"]?.lowercased() == "podcast-episode" || attributes["enclosureurl"] != nil
    }

    private func episode(from attributes: [String: String]) -> PodcastOPMLEpisode {
        let position = attributes["progress"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return PodcastOPMLEpisode(
            title: nonEmpty(attributes["title"]) ?? nonEmpty(attributes["text"]),
            guid: nonEmpty(attributes["guid"]),
            enclosureURL: nonEmpty(attributes["enclosureurl"]),
            publishedAt: attributes["pubdate"].flatMap(date),
            updatedAt: attributes["userupdateddate"].flatMap(date),
            position: position,
            isPlayed: attributes["played"].map(isTrue) ?? false
        )
    }

    private func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return isoFormatter.date(from: trimmed)
            ?? isoFractionalFormatter.date(from: trimmed)
            ?? rfc822Formatter.date(from: trimmed)
    }

    private func isTrue(_ value: String) -> Bool {
        ["1", "true", "yes"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func fail(_ error: PodcastOPMLError, _ parser: XMLParser) {
        failure = failure ?? error
        parser.abortParsing()
    }
}

nonisolated struct PodcastOPMLExportFeed: Equatable, Sendable {
    var title: String
    var feedURL: String
    var episodes: [PodcastOPMLEpisode]
}

nonisolated enum PodcastOPMLWriter {
    static func data(feeds: [PodcastOPMLExportFeed], createdAt: Date) -> Data {
        let iso = ISO8601DateFormatter()
        let rfc822 = DateFormatter()
        rfc822.locale = Locale(identifier: "en_US_POSIX")
        rfc822.timeZone = TimeZone(identifier: "GMT")
        rfc822.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"

        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0">"#,
            "  <head>",
            "    <title>Enve Podcast Subscriptions</title>",
            "    <dateCreated>\(rfc822.string(from: createdAt))</dateCreated>",
            "  </head>",
            "  <body>",
        ]
        for feed in feeds {
            let attributes = element([
                ("type", "rss"), ("text", feed.title), ("title", feed.title), ("xmlUrl", feed.feedURL),
            ])
            guard !feed.episodes.isEmpty else {
                lines.append("    <outline \(attributes)/>")
                continue
            }
            lines.append("    <outline \(attributes)>")
            for episode in feed.episodes {
                var pairs: [(String, String)] = [("type", "podcast-episode")]
                if let title = episode.title { pairs.append(("title", title)) }
                if let guid = episode.guid { pairs.append(("guid", guid)) }
                if let enclosure = episode.enclosureURL { pairs.append(("enclosureUrl", enclosure)) }
                if let published = episode.publishedAt { pairs.append(("pubDate", iso.string(from: published))) }
                if episode.isPlayed {
                    pairs.append(("played", "1"))
                } else if let position = episode.position, position > 0 {
                    pairs.append(("progress", String(Int(position.rounded(.down)))))
                }
                if let updated = episode.updatedAt { pairs.append(("userUpdatedDate", iso.string(from: updated))) }
                lines.append("      <outline \(element(pairs))/>")
            }
            lines.append("    </outline>")
        }
        lines.append(contentsOf: ["  </body>", "</opml>", ""])
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func escapeAttribute(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            case "\n": escaped += "&#10;"
            case "\r": escaped += "&#13;"
            case "\t": escaped += "&#9;"
            default:
                // XML 1.0 forbids the other C0 controls and U+FFFE/U+FFFF even as character references.
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    private static func element(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0)=\"\(escapeAttribute($0.1))\"" }.joined(separator: " ")
    }
}
