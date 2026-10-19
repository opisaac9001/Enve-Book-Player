import Foundation
import Logging

enum BookloreBookMapper {
    static func fraction(fromPercent percent: Double?) -> Double? {
        percent.flatMap { Book.normalizedFractionProgress($0 / 100) }
    }

    // Grimmory fills readProgress from the first stored KOReader (0–1) or Kobo/EPUB/PDF/CBX (0–100) value.
    static func fraction(fromReadProgress value: Double?) -> Double? {
        value.flatMap { Book.normalizedFractionProgress($0 > 1 ? $0 / 100 : $0) }
    }

    private static let ebookFileTypes: Set<String> = [
        "EPUB", "KEPUB", "PDF", "CBX", "CBR", "CBZ", "FB2", "MOBI", "AZW3", "AZW",
    ]
    private static let audiobookFileTypes: Set<String> = [
        "AUDIOBOOK", "MP3", "M4A", "M4B", "MP4", "AAC", "FLAC", "OGG", "OGA", "OPUS", "WAV",
    ]

    static func normalizedFileType(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix(".") {
            value.removeFirst()
        }

        switch value.lowercased() {
        case "application/epub+zip": return "epub"
        case "application/pdf": return "pdf"
        case "application/x-cbz", "application/vnd.comicbook+zip", "application/zip", "application/x-zip-compressed":
            return "cbz"
        case "application/x-cbr", "application/vnd.comicbook-rar", "application/x-rar-compressed", "application/vnd.rar":
            return "cbr"
        case "application/x-mobipocket-ebook": return "mobi"
        case "application/x-mobi8-ebook": return "azw3"
        case "audio/mpeg": return "mp3"
        case "audio/mp4": return "m4a"
        case "audio/aac": return "aac"
        case "audio/flac": return "flac"
        case "audio/ogg": return "ogg"
        case "audio/opus": return "opus"
        case "audio/wav": return "wav"
        default: return value
        }
    }

    static func resolvedFileType(_ candidates: [String?]) -> String? {
        candidates.lazy.compactMap(normalizedFileType).first
    }

    static func fileExtension(from path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        let fileExtension = (path as NSString).pathExtension
        return fileExtension.isEmpty ? nil : fileExtension
    }

    static func mediaType(from fileType: String?) -> AppMediaType {
        switch normalizedFileType(fileType)?.uppercased() {
        case let value? where ebookFileTypes.contains(value): .ebook
        case let value? where audiobookFileTypes.contains(value): .audiobook
        default: .ebook
        }
    }

    static func libraryType(from formats: [String]?) -> String {
        guard let formats, !formats.isEmpty else { return "book" }
        let normalized = Set(formats.compactMap(normalizedFileType).map { $0.uppercased() })
        let hasEbook = !normalized.isDisjoint(with: ebookFileTypes)
        let hasAudio = normalized.contains("AUDIOBOOK")
        if hasAudio && !hasEbook { return "audiobook" }
        if hasEbook && !hasAudio { return "ebook" }
        return "book"
    }

    static func normalizedEbookFormat(_ value: String?) -> String? {
        normalizedFileType(value).flatMap { EbookFormat.from(fileExtension: $0)?.rawValue }
    }

    static func displayAuthor(from values: [String]?) -> String {
        guard let values else { return "Unknown Author" }
        let normalized = Set(
            values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !normalized.isEmpty else { return "Unknown Author" }
        return normalized.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .joined(separator: ", ")
    }

    static func title(fromPrimaryFileName fileName: String?) -> String? {
        guard let fileName = fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !fileName.isEmpty else {
            return nil
        }
        let title = (fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    static func publishedYear(from value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let prefix = value.split(separator: "-").first, let year = Int(prefix) {
            return year
        }
        return ISO8601Timestamp.parse(value).map { Calendar(identifier: .gregorian).component(.year, from: $0) }
    }

    static func normalizedSeriesInfo(name: String?, sequence: String?) -> SeriesInfo? {
        guard let rawName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else { return nil }
        if let volume = strippedSeriesVolume(rawName) {
            return SeriesInfo(name: volume.base, sequence: sequence ?? volume.number)
        }
        return SeriesInfo(name: rawName, sequence: sequence)
    }

    static func chapters(from rawChapters: [GrimmoryChapter]?, bookDuration: TimeInterval) -> [Chapter] {
        guard let rawChapters, !rawChapters.isEmpty else { return [] }
        let mapped = rawChapters.enumerated().map { index, chapter in
            let start = max(chapter.start ?? 0, 0)
            let end = max(chapter.end ?? start, start)
            let title = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter \(index + 1)"
            return Chapter(
                id: "grimmory_ch_\(index)",
                start: start,
                end: end,
                title: resolvedTitle,
                index: index
            )
        }
        return normalizeChapters(mapped, bookDuration: max(bookDuration, mapped.map(\.end).max() ?? 0))
    }

    static func chaptersAreInadequate(_ chapters: [Chapter], bookDuration: TimeInterval) -> Bool {
        guard !chapters.isEmpty else { return true }
        return bookDuration > 1_800 && chapters.count <= 1
    }

    static func normalizeChapters(_ chapters: [Chapter], bookDuration: TimeInterval) -> [Chapter] {
        guard !chapters.isEmpty else { return [] }
        let sorted = chapters.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }
        return sorted.enumerated().map { index, chapter in
            let nextStart = sorted.indices.contains(index + 1) ? sorted[index + 1].start : nil
            let fallbackEnd = nextStart ?? (bookDuration > 0 ? bookDuration : chapter.end)
            return Chapter(
                id: chapter.id,
                start: chapter.start,
                end: max(chapter.end > chapter.start ? chapter.end : fallbackEnd, chapter.start),
                title: chapter.title,
                index: index
            )
        }
    }

    static func statusSuppressesContinue(_ status: String?) -> Bool {
        guard let status else { return false }
        return status != "READING" && status != "RE_READING"
    }

    static func normalizedBaseURL(_ urlString: String) -> String {
        var str = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasSuffix("/") { str.removeLast() }
        if !str.hasPrefix("http") { str = "http://\(str)" }
        return str
    }

    static func rewriteCoverPath(_ path: String, mediaType: AppMediaType? = nil) -> String {
        if path.hasPrefix("/api/v1/media/book/") {
            guard mediaType == .audiobook else {
                return path
            }
            if path.hasSuffix("/cover") {
                return String(path.dropLast("/cover".count)) + "/audiobook-cover"
            }
            if path.hasSuffix("/thumbnail") {
                return String(path.dropLast("/thumbnail".count)) + "/audiobook-thumbnail"
            }
            return path
        }

        guard path.hasPrefix("/api/books/") else {
            return path
        }

        let suffixMappings: [(suffix: String, mapped: (String) -> String)] = [
            ("/audiobook-cover", { "/api/v1/media/book/\($0)/audiobook-cover" }),
            ("/audiobook-thumbnail", { "/api/v1/media/book/\($0)/audiobook-thumbnail" }),
            (
                "/cover",
                {
                    switch mediaType {
                    case .audiobook:
                        return "/api/v1/media/book/\($0)/audiobook-thumbnail"
                    default:
                        return "/api/v1/media/book/\($0)/cover"
                    }
                }
            ),
            (
                "/thumbnail",
                {
                    switch mediaType {
                    case .audiobook:
                        return "/api/v1/media/book/\($0)/audiobook-thumbnail"
                    default:
                        return "/api/v1/media/book/\($0)/thumbnail"
                    }
                }
            ),
        ]

        for (suffix, mapper) in suffixMappings {
            if path.hasSuffix(suffix) {
                let stripped = path.dropFirst("/api/books/".count).dropLast(suffix.count)
                if !stripped.isEmpty {
                    return mapper(String(stripped))
                }
            }
        }

        return path
    }

    static func rewriteCoverURL(_ url: URL, mediaType: AppMediaType? = nil) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        let correctedPath = rewriteCoverPath(components.path, mediaType: mediaType)
        guard correctedPath != components.path else {
            return url
        }

        components.path = correctedPath
        return components.url ?? url
    }

    static func absoluteURL(from value: String?, serverURL: String, mediaType: AppMediaType? = nil) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if let absolute = URL(string: value), absolute.scheme != nil {
            return rewriteCoverURL(absolute, mediaType: mediaType)
        }

        let corrected = rewriteCoverPath(value, mediaType: mediaType)
        let base = normalizedBaseURL(serverURL)
        if corrected.hasPrefix("/") {
            return URL(string: "\(base)\(corrected)")
        }
        return URL(string: "\(base)/\(corrected)")
    }

    static func versionedCoverURL(_ url: URL?, updatedOn: String?) -> URL? {
        guard let url, let updatedOn, !updatedOn.isEmpty,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return url
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "v" }
        queryItems.append(URLQueryItem(name: "v", value: updatedOn))
        components.queryItems = queryItems
        return components.url ?? url
    }

    private static func strippedSeriesVolume(_ name: String) -> (base: String, number: String)? {
        let pattern = #"^(.*\S)\s+(?:#\s*|vol\.?\s*|volume\s+|book\s+|bk\.?\s*)(\d+(?:\.\d+)?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, range: range),
            let baseRange = Range(match.range(at: 1), in: name),
            let numberRange = Range(match.range(at: 2), in: name)
        else { return nil }
        let base = String(name[baseRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        return (base, String(name[numberRange]))
    }
}
