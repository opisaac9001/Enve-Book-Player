import Foundation

// Wire contract: docs/architecture/listening-position-sharing.md.
struct ListeningPositionPayload: Equatable, Sendable {
    static let kind = "enve.position"
    static let maxEncodedBytes = 2200
    static let maxDurationMilliseconds: Int64 = 3_600_000_000

    static let maxTitleLength = 160
    static let maxPersonLength = 100
    static let maxPeople = 4
    static let maxSeriesLength = 120
    static let maxSequenceLength = 16

    let positionMilliseconds: Int64
    let durationMilliseconds: Int64
    let title: String
    let authors: [String]
    let narrators: [String]
    let series: String?
    let seriesSequence: String?
    let asin: String?
    let isbn: String?
    let readingLocation: ListeningPositionReadingLocation?

    var position: TimeInterval { TimeInterval(positionMilliseconds) / 1000 }
    var duration: TimeInterval { TimeInterval(durationMilliseconds) / 1000 }

    init(
        positionMilliseconds: Int64,
        durationMilliseconds: Int64,
        title: String,
        authors: [String] = [],
        narrators: [String] = [],
        series: String? = nil,
        seriesSequence: String? = nil,
        asin: String? = nil,
        isbn: String? = nil,
        readingLocation: ListeningPositionReadingLocation? = nil
    ) throws(ListeningPositionPayloadError) {
        if readingLocation == nil {
            guard durationMilliseconds > 0, durationMilliseconds <= Self.maxDurationMilliseconds else { throw .invalidField("dur") }
            guard positionMilliseconds >= 0, positionMilliseconds <= durationMilliseconds else { throw .invalidField("pos") }
        } else {
            guard positionMilliseconds == 0, durationMilliseconds == 0 else { throw .invalidField("pos") }
        }
        guard Self.isValidText(title, maxLength: Self.maxTitleLength) else { throw .invalidField("t") }
        guard authors.count <= Self.maxPeople, authors.allSatisfy({ Self.isValidText($0, maxLength: Self.maxPersonLength) }) else {
            throw .invalidField("a")
        }
        guard narrators.count <= Self.maxPeople, narrators.allSatisfy({ Self.isValidText($0, maxLength: Self.maxPersonLength) }) else {
            throw .invalidField("n")
        }
        if let series, !Self.isValidText(series, maxLength: Self.maxSeriesLength) { throw .invalidField("s") }
        if let seriesSequence, !Self.isValidText(seriesSequence, maxLength: Self.maxSequenceLength) { throw .invalidField("q") }
        if let asin, Self.normalizedASIN(asin) != asin { throw .invalidField("asin") }
        if let isbn, Self.normalizedISBN(isbn) != isbn { throw .invalidField("isbn") }

        self.positionMilliseconds = positionMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.title = title
        self.authors = authors
        self.narrators = narrators
        self.series = series
        self.seriesSequence = seriesSequence
        self.asin = asin
        self.isbn = isbn
        self.readingLocation = readingLocation
    }

    init?(book: Book, position: TimeInterval, duration: TimeInterval) {
        guard book.mediaType == .audiobook || book.mediaType == .podcast,
            duration.isFinite, position.isFinite, duration > 0,
            duration <= Double(Self.maxDurationMilliseconds) / 1000,
            let title = Self.sanitized(book.title, maxLength: Self.maxTitleLength)
        else { return nil }
        guard duration * 1000 <= Double(Self.maxDurationMilliseconds) else { return nil }
        let durationMs = Int64((duration * 1000).rounded(.down))
        guard durationMs > 0 else { return nil }
        let positionMs = Int64((min(max(position, 0), duration) * 1000).rounded(.down))
        let series = book.series.flatMap { Self.sanitized($0, maxLength: Self.maxSeriesLength) }

        let authorNames = book.authors.flatMap { $0.isEmpty ? nil : $0 } ?? [book.author].compactMap { $0 }
        let narratorNames = (book.narrator ?? "")
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "&" })
            .map(String.init)

        let candidate = Self.unchecked(
            positionMilliseconds: positionMs,
            durationMilliseconds: durationMs,
            title: title,
            authors: Self.sanitizedPeople(authorNames),
            narrators: Self.sanitizedPeople(narratorNames),
            series: series,
            seriesSequence: series == nil
                ? nil : (book.seriesSequence ?? book.seriesNumber.map(String.init)).flatMap { Self.sanitized($0, maxLength: Self.maxSequenceLength) },
            asin: book.asin.flatMap(Self.normalizedASIN),
            isbn: book.isbn.flatMap(Self.normalizedISBN)
        )
        guard let bounded = candidate.boundedForSharing() else { return nil }
        self = bounded
    }

    init?(book: Book) {
        guard book.mediaType == .ebook else {
            self.init(book: book, position: book.currentTime, duration: book.duration ?? 0)
            return
        }
        guard let reading = ListeningPositionReadingLocation(book: book),
            let title = Self.sanitized(book.title, maxLength: Self.maxTitleLength)
        else { return nil }
        let series = book.series.flatMap { Self.sanitized($0, maxLength: Self.maxSeriesLength) }
        let authors = book.authors.flatMap { $0.isEmpty ? nil : $0 } ?? [book.author].compactMap { $0 }
        let candidate = Self.unchecked(
            positionMilliseconds: 0,
            durationMilliseconds: 0,
            title: title,
            authors: Self.sanitizedPeople(authors),
            narrators: [],
            series: series,
            seriesSequence: series == nil ? nil : (book.seriesSequence ?? book.seriesNumber.map(String.init))
                .flatMap { Self.sanitized($0, maxLength: Self.maxSequenceLength) },
            asin: book.asin.flatMap(Self.normalizedASIN),
            isbn: book.isbn.flatMap(Self.normalizedISBN),
            readingLocation: reading
        )
        guard let bounded = candidate.boundedForSharing() else { return nil }
        self = bounded
    }

    private func boundedForSharing() -> Self? {
        var candidate = self
        while candidate.encoded().utf8.count > Self.maxEncodedBytes {
            if !candidate.narrators.isEmpty {
                candidate = candidate.replacing(narrators: [])
            } else if candidate.series != nil {
                candidate = candidate.replacing(series: .some(nil), seriesSequence: .some(nil))
            } else if candidate.authors.count > 1 {
                candidate = candidate.replacing(authors: Array(candidate.authors.prefix(1)))
            } else if !candidate.authors.isEmpty {
                candidate = candidate.replacing(authors: [])
            } else {
                return nil
            }
        }
        return candidate
    }

    private static func unchecked(
        positionMilliseconds: Int64,
        durationMilliseconds: Int64,
        title: String,
        authors: [String],
        narrators: [String],
        series: String?,
        seriesSequence: String?,
        asin: String?,
        isbn: String?,
        readingLocation: ListeningPositionReadingLocation? = nil
    ) -> ListeningPositionPayload {
        // Inputs come from the sanitizers above, so validation cannot fail.
        try! ListeningPositionPayload(
            positionMilliseconds: positionMilliseconds,
            durationMilliseconds: durationMilliseconds,
            title: title,
            authors: authors,
            narrators: narrators,
            series: series,
            seriesSequence: seriesSequence,
            asin: asin,
            isbn: isbn,
            readingLocation: readingLocation
        )
    }

    private func replacing(
        authors: [String]? = nil,
        narrators: [String]? = nil,
        series: String?? = nil,
        seriesSequence: String?? = nil,
        readingLocation: ListeningPositionReadingLocation?? = nil
    ) -> ListeningPositionPayload {
        Self.unchecked(
            positionMilliseconds: positionMilliseconds,
            durationMilliseconds: durationMilliseconds,
            title: title,
            authors: authors ?? self.authors,
            narrators: narrators ?? self.narrators,
            series: series ?? self.series,
            seriesSequence: seriesSequence ?? self.seriesSequence,
            asin: asin,
            isbn: isbn,
            readingLocation: readingLocation ?? self.readingLocation
        )
    }
}

extension ListeningPositionPayload {
    /// Canonical form: compact UTF-8 JSON, keys in byte order, absent optionals omitted.
    func encoded() -> String {
        var fields: [(String, String)] = []
        if !authors.isEmpty { fields.append(("a", Self.jsonArray(authors))) }
        if let asin { fields.append(("asin", Self.jsonString(asin))) }
        if let reading = readingLocation {
            if let cfi = reading.epubCFI { fields.append(("c", Self.jsonString(cfi))) }
            fields.append(("f", Self.jsonString(reading.format)))
            if let href = reading.href { fields.append(("h", Self.jsonString(href))) }
            fields.append(("m", Self.jsonString("reading")))
            if let locator = reading.readiumLocatorJSON { fields.append(("l", Self.jsonString(locator))) }
            if let offset = reading.resourceProgressionUnits { fields.append(("o", String(offset))) }
            fields.append(("p", String(reading.progressionUnits)))
            if let page = reading.page { fields.append(("page", String(page))) }
            if let pages = reading.pageCount { fields.append(("pages", String(pages))) }
        } else {
            fields.append(("dur", String(durationMilliseconds)))
            fields.append(("pos", String(positionMilliseconds)))
        }
        if let isbn { fields.append(("isbn", Self.jsonString(isbn))) }
        fields.append(("k", Self.jsonString(Self.kind)))
        if !narrators.isEmpty { fields.append(("n", Self.jsonArray(narrators))) }
        if let seriesSequence { fields.append(("q", Self.jsonString(seriesSequence))) }
        if let series { fields.append(("s", Self.jsonString(series))) }
        fields.append(("t", Self.jsonString(title)))
        fields.append(("v", readingLocation == nil ? "1" : "2"))
        return "{" + fields.sorted { $0.0 < $1.0 }.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }

    private static func jsonString(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\u{08}": escaped += "\\b"
            case "\u{0C}": escaped += "\\f"
            case "\u{00}"..."\u{1F}": escaped += String(format: "\\u%04x", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "\""
    }

    private static func jsonArray(_ values: [String]) -> String {
        "[" + values.map(jsonString).joined(separator: ",") + "]"
    }
}

enum ListeningPositionPayloadError: Error, Equatable {
    case tooLarge
    case notListeningPosition
    case unsupportedVersion(Int)
    case invalidField(String)
}

extension ListeningPositionPayload {
    static func decode(_ text: String) throws(ListeningPositionPayloadError) -> ListeningPositionPayload {
        guard text.utf8.count <= maxEncodedBytes else { throw .tooLarge }
        let data = Data(text.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .notListeningPosition
        }
        guard object["k"] as? String == kind else { throw .notListeningPosition }
        guard let version = integer(object["v"]), version >= 1, version <= Int64(Int32.max) else {
            throw .invalidField("v")
        }
        guard version == 1 || version == 2 else { throw .unsupportedVersion(Int(version)) }
        let reading: ListeningPositionReadingLocation?
        let position: Int64
        let duration: Int64
        if version == 2 {
            guard object["m"] as? String == "reading" else { throw .invalidField("m") }
            guard object["pos"] == nil, object["dur"] == nil else { throw .invalidField("pos") }
            guard let format = object["f"] as? String else { throw .invalidField("f") }
            guard let progression = integer(object["p"]) else { throw .invalidField("p") }
            func optionalInteger(_ key: String) throws(ListeningPositionPayloadError) -> Int64? {
                guard let value = object[key] else { return nil }
                guard let number = integer(value) else { throw .invalidField(key) }
                return number
            }
            let page = try optionalInteger("page")
            let pages = try optionalInteger("pages")
            if let page, !(1...1_000_000).contains(page) { throw .invalidField("page") }
            if let pages, !(1...1_000_000).contains(pages) { throw .invalidField("pages") }
            reading = try ListeningPositionReadingLocation(
                format: format,
                progressionUnits: progression,
                href: try optionalString(object["h"], field: "h"),
                resourceProgressionUnits: try optionalInteger("o"),
                page: page.map(Int.init),
                pageCount: pages.map(Int.init),
                epubCFI: try optionalString(object["c"], field: "c"),
                readiumLocatorJSON: try optionalString(object["l"], field: "l")
            )
            position = 0
            duration = 0
        } else {
            guard ["m", "f", "p", "h", "o", "page", "pages", "c", "l"].allSatisfy({ object[$0] == nil }) else {
                throw .invalidField("m")
            }
            guard let parsedPosition = integer(object["pos"]) else { throw .invalidField("pos") }
            guard let parsedDuration = integer(object["dur"]) else { throw .invalidField("dur") }
            position = parsedPosition
            duration = parsedDuration
            reading = nil
        }
        guard let title = object["t"] as? String else { throw .invalidField("t") }

        return try ListeningPositionPayload(
            positionMilliseconds: position,
            durationMilliseconds: duration,
            title: title,
            authors: try stringArray(object["a"], field: "a"),
            narrators: try stringArray(object["n"], field: "n"),
            series: try optionalString(object["s"], field: "s"),
            seriesSequence: try optionalString(object["q"], field: "q"),
            asin: try optionalString(object["asin"], field: "asin"),
            isbn: try optionalString(object["isbn"], field: "isbn"),
            readingLocation: reading
        )
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) <= 9_007_199_254_740_991 else { return nil }
        return Int64(double)
    }

    private static func optionalString(_ value: Any?, field: String) throws(ListeningPositionPayloadError) -> String? {
        guard let value else { return nil }
        guard let string = value as? String else { throw .invalidField(field) }
        return string
    }

    private static func stringArray(_ value: Any?, field: String) throws(ListeningPositionPayloadError) -> [String] {
        guard let value else { return [] }
        guard let strings = value as? [String] else { throw .invalidField(field) }
        return strings
    }
}

extension ListeningPositionPayload {
    private static let disallowedScalars: CharacterSet = CharacterSet.controlCharacters
        .subtracting(CharacterSet(charactersIn: "\u{200C}\u{200D}"))
        .union(CharacterSet(charactersIn: "\u{2028}\u{2029}"))

    static func isValidText(_ value: String, maxLength: Int) -> Bool {
        sanitized(value, maxLength: maxLength) == value
    }

    /// NFC, no control or line-separator characters, single spaces, trimmed, at most `maxLength` scalars.
    static func sanitized(_ value: String, maxLength: Int) -> String? {
        let cleaned = String(String.UnicodeScalarView(
            value.precomposedStringWithCanonicalMapping.unicodeScalars.map { disallowedScalars.contains($0) ? " " : $0 }
        ))
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.unicodeScalars.count > maxLength else { return collapsed }
        var truncated = ""
        for character in collapsed {
            guard truncated.unicodeScalars.count + character.unicodeScalars.count <= maxLength else { break }
            truncated.append(character)
        }
        let trimmed = truncated.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sanitizedPeople(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names
            .compactMap { sanitized($0, maxLength: maxPersonLength) }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(maxPeople)
            .map(\.self)
    }

    static func normalizedASIN(_ value: String) -> String? {
        let upper = value.trimmingCharacters(in: .whitespaces).uppercased()
        guard upper.count == 10, upper.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) }) else {
            return nil
        }
        return upper
    }

    static func normalizedISBN(_ value: String) -> String? {
        let compact = value.uppercased().filter { $0 != "-" && $0 != " " }
        let digits = compact.dropLast().allSatisfy { $0.isASCII && $0.isNumber }
        switch compact.count {
        case 10 where digits && (compact.last!.isASCII && (compact.last!.isNumber || compact.last == "X")):
            return compact
        case 13 where digits && compact.last!.isASCII && compact.last!.isNumber && (compact.hasPrefix("978") || compact.hasPrefix("979")):
            return compact
        default:
            return nil
        }
    }
}
