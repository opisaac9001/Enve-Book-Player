import Foundation

/// Map locators, pages, and audio times to ordered references; fall back to progression when unmappable.
enum OPDSProgressionMapping {
    static func point(forEbookLocator locator: String?) -> OPDSProgressionPoint {
        guard let locator, !locator.isEmpty else { return OPDSProgressionPoint() }

        // tvOS has no paged reader and does not build the PDF locator type.
        #if !os(tvOS)
        if let pageIndex = ReaderLocatorProgress.parsePDFLocator(locator) {
            return OPDSProgressionPoint(pdfPage: pageIndex + 1)
        }
        #endif
        guard let json = jsonObject(locator), !isAudioLocator(json) else { return OPDSProgressionPoint() }

        let locations = json["locations"] as? [String: Any]
        var path: String?
        var hrefIdentifier: String?
        if let href = json["href"] as? String, !href.isEmpty {
            if let separator = href.firstIndex(of: "#") {
                path = String(href[href.startIndex..<separator])
                let candidate = String(href[href.index(after: separator)...])
                if isPlainIdentifier(candidate) { hrefIdentifier = candidate }
            } else {
                path = href
            }
        }

        let fragmentIdentifier = (locations?["fragments"] as? [Any])?
            .compactMap { $0 as? String }
            .first(where: isPlainIdentifier)

        return OPDSProgressionPoint(
            resourcePath: path,
            scrollToText: (json["text"] as? [String: Any])?["highlight"] as? String,
            htmlID: fragmentIdentifier ?? hrefIdentifier,
            epubCFI: unwrappedCFI(EpubLocationBridge.epubCFI(from: locator))
        )
    }

    /// The draft's optional `title`, which contextualizes a progression for whoever reads it on the server.
    static func chapterTitle(inEbookLocator locator: String?) -> String? {
        guard let locator,
            let title = jsonObject(locator)?["title"] as? String
        else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `nil` leaves the book's existing locator alone and lets `progression` carry the position by itself.
    static func ebookLocator(for book: Book, point: OPDSProgressionPoint, progression: Double) -> String? {
        #if !os(tvOS)
        if let page = point.pdfPage, EbookFormat.from(fileExtension: book.ebookFormat ?? "") == .pdf {
            return ReaderLocatorProgress.makePDFLocator(pageIndex: page - 1)
        }
        #endif
        guard let path = point.resourcePath, !path.isEmpty else { return nil }

        var locations: [String: Any] = ["totalProgression": min(max(progression, 0), 1)]
        if let cfi = EpubLocationBridge.normalizedEPUBCFI(point.epubCFI) {
            locations["cfi"] = cfi
        }
        if let htmlID = point.htmlID, isPlainIdentifier(htmlID) {
            locations["fragments"] = [htmlID]
        }

        var locator: [String: Any] = [
            "href": path,
            "type": "application/xhtml+xml",
            "locations": locations,
        ]
        if let snippet = point.scrollToText, !snippet.isEmpty {
            locator["text"] = ["highlight": snippet]
        }

        guard JSONSerialization.isValidJSONObject(locator),
            let data = try? JSONSerialization.data(withJSONObject: locator)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func audioSeconds(
        in point: OPDSProgressionPoint,
        progression: Double,
        duration: TimeInterval?
    ) -> TimeInterval? {
        if let seconds = point.audioSeconds, seconds.isFinite, seconds >= 0 {
            guard let duration, duration > 0 else { return seconds }
            return min(seconds, duration)
        }
        guard let duration, duration > 0 else { return nil }
        return min(max(progression, 0), 1) * duration
    }

    /// Returns nil without a duration; the draft requires an audio position expressed as a fraction.
    static func audioProgression(seconds: TimeInterval, duration: TimeInterval?) -> Double? {
        guard let duration, duration > 0, seconds.isFinite else { return nil }
        return min(max(seconds / duration, 0), 1)
    }

    private static func jsonObject(_ locator: String) -> [String: Any]? {
        guard let data = locator.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Read-aloud locators address an audio timeline, not a resource inside the publication.
    private static func isAudioLocator(_ json: [String: Any]) -> Bool {
        let type = (json["type"] as? String)?.lowercased() ?? ""
        let href = (json["href"] as? String)?.lowercased() ?? ""
        return type.contains("audio") || href.hasPrefix("audiobook://")
    }

    private static func isPlainIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && EpubLocationBridge.normalizedEPUBCFI(value) == nil
            && !value.contains(where: \.isWhitespace)
            && !value.contains("=")
    }

    /// References carry the CFI without its `epubcfi(...)` wrapper; Enve's locators keep the wrapper.
    private static func unwrappedCFI(_ wrapped: String?) -> String? {
        guard let wrapped, wrapped.hasPrefix("epubcfi("), wrapped.hasSuffix(")") else { return nil }
        let inner = wrapped.dropFirst("epubcfi(".count).dropLast()
        return inner.isEmpty ? nil : String(inner)
    }
}
