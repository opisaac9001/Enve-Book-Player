import Foundation

nonisolated struct ListeningPositionReadingLocation: Equatable, Sendable {
    static let progressionScale: Int64 = 1_000_000

    let format: String
    let progressionUnits: Int64
    let href: String?
    let resourceProgressionUnits: Int64?
    let page: Int?
    let pageCount: Int?
    let epubCFI: String?
    let readiumLocatorJSON: String?

    var progression: Double { Double(progressionUnits) / Double(Self.progressionScale) }

    init(
        format: String,
        progressionUnits: Int64,
        href: String? = nil,
        resourceProgressionUnits: Int64? = nil,
        page: Int? = nil,
        pageCount: Int? = nil,
        epubCFI: String? = nil,
        readiumLocatorJSON: String? = nil
    ) throws(ListeningPositionPayloadError) {
        guard !format.isEmpty, format.utf8.count <= 16,
            format.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) })
        else { throw .invalidField("f") }
        guard (0...Self.progressionScale).contains(progressionUnits) else { throw .invalidField("p") }
        guard (href == nil) == (resourceProgressionUnits == nil) else { throw .invalidField("h") }
        let isPaged = format == "pdf" || format == "comic"
        guard isPaged || (page == nil && pageCount == nil) else { throw .invalidField("page") }
        guard !isPaged || href == nil else { throw .invalidField("h") }
        guard !isPaged || (epubCFI == nil && readiumLocatorJSON == nil) else { throw .invalidField("l") }
        if let epubCFI, !SharedReadingLocator.validCFI(epubCFI) { throw .invalidField("c") }
        if let href, !Self.validHref(href) { throw .invalidField("h") }
        if let resourceProgressionUnits, !(0...Self.progressionScale).contains(resourceProgressionUnits) {
            throw .invalidField("o")
        }
        if let page, !(1...1_000_000).contains(page) { throw .invalidField("page") }
        if let pageCount {
            guard (1...1_000_000).contains(pageCount), let page, page <= pageCount else { throw .invalidField("pages") }
        }
        self.format = format
        self.progressionUnits = progressionUnits
        self.href = href
        self.resourceProgressionUnits = resourceProgressionUnits
        self.page = page
        self.pageCount = pageCount
        self.epubCFI = epubCFI
        if let readiumLocatorJSON {
            self.readiumLocatorJSON = try SharedReadingLocator.sanitized(readiumLocatorJSON, strict: true)
            if let href, SharedReadingLocator.object(self.readiumLocatorJSON)?["href"] as? String != href {
                throw .invalidField("l")
            }
        } else {
            self.readiumLocatorJSON = nil
        }
    }

    init?(book: Book) {
        guard book.mediaType == .ebook else { return nil }
        let format = Self.format(for: book)
        let precise = ["pdf", "comic"].contains(format) ? (cfi: nil as String?, locator: nil as String?)
            : SharedReadingLocator.representations(from: book.epubLocator)
        let object = book.epubLocator.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let readingObject = SharedReadingLocator.object(precise.locator) ?? object
        let locations = readingObject?["locations"] as? [String: Any]
        let rawHref = readingObject?["href"] as? String
        let href = rawHref.flatMap { format != "pdf" && format != "comic" && Self.validHref($0) ? $0 : nil }
        let offsetNumber = locations?["progression"] as? NSNumber
        let rawOffset = offsetNumber.flatMap { CFGetTypeID($0) != CFBooleanGetTypeID() ? $0.doubleValue : nil }
        let offset = rawOffset.flatMap { $0.isFinite && (0...1).contains($0) ? Int64(($0 * Double(Self.progressionScale)).rounded()) : nil }
        let pageIndex: Int? = if format == "comic", let locator = book.epubLocator, locator.hasPrefix("cbz-page:") {
            Int(locator.dropFirst("cbz-page:".count))
        } else if format == "pdf", let locator = book.epubLocator, locator.hasPrefix("pdf-page:") {
            Int(locator.dropFirst("pdf-page:".count))
        } else if format == "pdf" {
            Self.integer(object?["page"])
        } else { nil }
        let page = pageIndex.flatMap { (0..<1_000_000).contains($0) ? $0 + 1 : nil }
        let count = Self.pageCount(for: book)
        let validCount = count.flatMap { count in page.flatMap { $0 <= count ? count : nil } }
        self = try! Self(
            format: format,
            progressionUnits: Int64((book.canonicalEbookProgress * Double(Self.progressionScale)).rounded()),
            href: href != nil && offset != nil ? href : nil,
            resourceProgressionUnits: href != nil ? offset : nil,
            page: page,
            pageCount: validCount,
            epubCFI: precise.cfi,
            readiumLocatorJSON: precise.locator
        )
    }

    static func format(for book: Book) -> String {
        if book.isComic { return "comic" }
        return [book.ebookFormat, book.ebookFileURL?.pathExtension]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .first { !$0.isEmpty && $0.utf8.count <= 16 && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) } }
            ?? "ebook"
    }

    static func pageCount(for book: Book) -> Int? {
        if let count = book.comicMetadata?.pageCount, (1...1_000_000).contains(count) { return count }
        guard let data = book.epubLocator?.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let count = integer(object["pageCount"]), (1...1_000_000).contains(count)
        else { return nil }
        return count
    }

    func progression(for book: Book) -> Double {
        guard format == Self.format(for: book), ["comic", "pdf"].contains(format),
            let page, let count = Self.pageCount(for: book)
        else { return progression }
        return count == 1 ? 1 : Double(page - 1) / Double(count - 1)
    }

    func locatorJSON(for book: Book) -> String? {
        let isMatchingFormat = format == Self.format(for: book)
        if isMatchingFormat, let page, format == "comic" { return "cbz-page:\(page - 1)" }
        if isMatchingFormat, let page, format == "pdf" { return "{\"page\":\(page - 1),\"enveSharedPosition\":true}" }
        var object = isMatchingFormat ? SharedReadingLocator.object(readiumLocatorJSON) ?? [:] : [:]
        var locations = object["locations"] as? [String: Any] ?? [:]
        locations["totalProgression"] = progression
        object["enveSharedPosition"] = true
        if isMatchingFormat, let href, let resourceProgressionUnits {
            object["href"] = href
            object["type"] = "application/xhtml+xml"
            if locations["progression"] == nil {
                locations["progression"] = Double(resourceProgressionUnits) / Double(Self.progressionScale)
            }
        }
        if isMatchingFormat, let epubCFI {
            locations["cfi"] = epubCFI
            locations["enveSourceEngine"] = "foliate"
        }
        object["locations"] = locations
        return SharedReadingLocator.encoded(object)
    }

    static func validHref(_ value: String) -> Bool {
        guard !value.isEmpty, value.unicodeScalars.count <= 256,
            value == value.precomposedStringWithCanonicalMapping,
            !value.unicodeScalars.contains(where: disallowedHrefScalar),
            let decoded = value.removingPercentEncoding,
            !decoded.unicodeScalars.contains(where: disallowedHrefScalar),
            !decoded.hasPrefix("/"), !decoded.contains(":"), !decoded.contains("\\"),
            !decoded.contains("?"), !decoded.contains("#"),
            !decoded.split(separator: "/").contains("..")
        else { return false }
        return true
    }

    private static func disallowedHrefScalar(_ scalar: Unicode.Scalar) -> Bool {
        [.control, .format, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        guard number.isFinite, number == number.rounded(), (0...1_000_000).contains(number) else { return nil }
        return Int(number)
    }
}
