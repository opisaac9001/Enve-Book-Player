import Foundation

enum WorkIdentity {

    nonisolated static func workKey(for book: Book) -> String {
        guard book.mediaType != .podcast, !book.isPodcastEpisode else { return "" }
        let title = workTitle(book.title)
        guard !title.isEmpty, !placeholderTitles.contains(title) else { return "" }
        let author = TextNormalizer.normalizeAuthor(book.author ?? "")

        if book.mediaType == .audiobook {
            guard let duration = book.duration, duration > 0 else { return "" }
            return "w:\(title)|\(author)|d:\(Int(duration.rounded()))"
        }

        if let volume = titleVolume(title, seriesContext: hasSeriesContext(book)) {
            var base = volume.base
            if base.isEmpty { base = TextNormalizer.normalizeSeries(book.series ?? "") }
            if base.isEmpty { base = title }
            return "w:\(base)|\(author)|s:\(volume.number)"
        }

        if let position = seriesPosition(book) {
            return "w:\(title)|\(author)|s:\(position)"
        }
        return "w:\(title)|\(author)"
    }

    private nonisolated static let placeholderTitles: Set<String> = [
        "unknown title", "unknown", "untitled", "unknown album", "no title", "track 1",
    ]

    private nonisolated static func hasSeriesContext(_ book: Book) -> Bool {
        if let series = book.series, !series.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if let seq = book.seriesSequence, !seq.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if let number = book.seriesNumber, number > 0 { return true }
        return false
    }

    private nonisolated static func titleVolume(_ title: String, seriesContext: Bool) -> (number: String, base: String)? {
        if let match = firstCapture(title, #"(?i)\b(?:volume|vol|book|bk|part|pt|novel)\b\.?\s*#?\s*(\d+(?:\.\d+)?)"#) {
            return (normalizedNumber(match.capture), removingRange(title, match.range))
        }
        if seriesContext, let match = firstCapture(title, #"\s(\d+(?:\.\d+)?)$"#) {
            return (normalizedNumber(match.capture), String(title[..<match.range.lowerBound]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private nonisolated static func seriesPosition(_ book: Book) -> String? {
        if let raw = book.seriesSequence?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let numeric = raw.filter { $0.isNumber || $0 == "." }
            if let value = Double(numeric), value > 0 { return String(format: "%g", value) }
            return raw.lowercased()
        }
        if let number = book.seriesNumber, number > 0 { return String(number) }
        return nil
    }

    private nonisolated static func normalizedNumber(_ string: String) -> String {
        if let value = Double(string) { return String(format: "%g", value) }
        return string
    }

    private nonisolated static func removingRange(_ title: String, _ range: Range<String.Index>) -> String {
        var result = title
        result.removeSubrange(range)
        return result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private nonisolated static func firstCapture(_ string: String, _ pattern: String) -> (capture: String, range: Range<String.Index>)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let length = (string as NSString).length
        guard let match = regex.firstMatch(in: string, range: NSRange(location: 0, length: length)),
            match.numberOfRanges >= 2,
            let full = Range(match.range, in: string),
            let captured = Range(match.range(at: 1), in: string)
        else { return nil }
        return (String(string[captured]), full)
    }

    nonisolated static func editionKey(for book: Book) -> String {
        let work = workKey(for: book)
        guard !work.isEmpty else { return "" }
        let format = book.mediaType.rawValue
        let production = VersionDetector.detectProductionType(from: book).rawValue
        let abridged = VersionDetector.detectAbridgedState(from: book).rawValue
        let language = (book.language ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let narrators = TextNormalizer.normalizeNarratorList(book.narrator ?? "").sorted().joined(separator: ",")
        return "\(work)|f:\(format)|p:\(production)|a:\(abridged)|l:\(language)|n:\(narrators)"
    }

    private nonisolated static func workTitle(_ title: String) -> String {
        var t = TextNormalizer.normalizeTitle(title)
        let markers = [
            "full cast", "fullcast", "dramatized", "dramatised",
            "graphic audio", "graphicaudio", "audio drama", "radio drama",
            "unabridged", "abridged", "audiobook", "ebook",
        ]
        var changed = true
        while changed {
            changed = false
            for marker in markers where t.hasSuffix(" " + marker) {
                t = String(t.dropLast(marker.count + 1)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return t
    }
}
