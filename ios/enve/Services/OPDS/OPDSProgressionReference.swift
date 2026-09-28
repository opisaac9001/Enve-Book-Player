import Foundation

/// Validate URI grammar directly; URL may accept or silently repair invalid input.
nonisolated enum OPDSProgressionURI {
    /// RFC 3986 `URI`: a scheme, then anything the repertoire allows.
    static func isURI(_ value: String) -> Bool {
        !value.isEmpty && hasValidCharacters(value) && hasScheme(value)
    }

    /// RFC 3986 `URI-reference`: a `URI` or a `relative-ref`. `chapter1.html` and `#par36` are both valid.
    static func isReference(_ value: String) -> Bool {
        guard !value.isEmpty, hasValidCharacters(value) else { return false }
        if hasScheme(value) { return true }
        let path = value.prefix(while: { $0 != "?" && $0 != "#" })
        // `path-noscheme`: a colon in the first segment would make a relative reference read as a scheme.
        return path.hasPrefix("/") || !path.prefix(while: { $0 != "/" }).contains(":")
    }

    private static func hasValidCharacters(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            if scalars[index] == "%" {
                guard index + 2 < scalars.count,
                    isHexDigit(scalars[index + 1]),
                    isHexDigit(scalars[index + 2])
                else { return false }
                index += 3
                continue
            }
            guard isAllowed(scalars[index]) else { return false }
            index += 1
        }
        return true
    }

    /// Accept RFC 3986 characters and RFC 3987 Unicode scalars; reject whitespace and control characters.
    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else {
            return !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.illegalCharacters.contains(scalar)
        }
        return asciiRepertoire.contains(scalar)
    }

    private static let asciiRepertoire: Set<Unicode.Scalar> = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#[]@!$&'()*+,;=".unicodeScalars
    )

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && Character(scalar).isHexDigit
    }

    private static func hasScheme(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        let scheme = value[value.startIndex..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.dropFirst().allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".")
        }
    }
}

/// Preserve raw references so classifying known fragment formats does not discard unknown data.
nonisolated struct OPDSProgressionReference: Equatable, Sendable {
    /// The fragment syntaxes the draft names. Everything else stays `opaque` and travels unchanged.
    enum Fragment: Equatable, Sendable {
        /// Media Fragment URI 1.0 temporal dimension, resolved to the start time in seconds.
        case mediaTime(TimeInterval)
        /// RFC 8118 `page`, one-based as written.
        case pdfPage(Int)
        /// The text directive exactly as written after `:~:text=`.
        case scrollToText(String)
        case epubCFI(String)
        case htmlID(String)
        case opaque(String)
    }

    /// Long highlights make unusable URLs, and a truncated start term still matches the same text run.
    private static let snippetCharacterLimit = 120

    let raw: String
    /// Empty when the reference addresses the publication as a whole, as in `#t=67`.
    let path: String
    let fragment: Fragment?

    init(raw: String) {
        self.raw = raw
        guard let separator = raw.firstIndex(of: "#") else {
            path = raw
            fragment = nil
            return
        }
        path = String(raw[raw.startIndex..<separator])
        let value = String(raw[raw.index(after: separator)...])
        fragment = value.isEmpty ? nil : Self.classify(value)
    }

    private static func classify(_ value: String) -> Fragment {
        if value.hasPrefix(":~:text=") {
            return .scrollToText(String(value.dropFirst(":~:text=".count)))
        }
        if value.hasPrefix("epubcfi("), value.hasSuffix(")") {
            let inner = value.dropFirst("epubcfi(".count).dropLast()
            if !inner.isEmpty {
                return .epubCFI(inner.removingPercentEncoding ?? String(inner))
            }
        }
        if let seconds = mediaTimeSeconds(value) { return .mediaTime(seconds) }
        if let page = pdfPageNumber(value) { return .pdfPage(page) }
        // A fragment carrying neither a parameter nor a separator is an element identifier.
        if !value.contains("="), !value.contains("&") {
            return .htmlID(value.removingPercentEncoding ?? value)
        }
        return .opaque(value)
    }

    private static func mediaTimeSeconds(_ value: String) -> TimeInterval? {
        guard value.hasPrefix("t=") else { return nil }
        var specification = String(value.dropFirst(2))
        if specification.lowercased().hasPrefix("npt:") {
            specification = String(specification.dropFirst(4))
        }
        // An interval names its start first; smpte and clock formats are left to `opaque`.
        let start = specification.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return normalPlayTimeSeconds(start)
    }

    private static func normalPlayTimeSeconds(_ text: String) -> TimeInterval? {
        if text.isEmpty { return 0 }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }

        var total: TimeInterval = 0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty,
                part.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                let value = Double(part),
                value >= 0
            else { return nil }
            // Only the seconds field may be fractional.
            if index < parts.count - 1, part.contains(".") { return nil }
            total = total * 60 + value
        }
        return total
    }

    private static func pdfPageNumber(_ value: String) -> Int? {
        for parameter in value.split(separator: "&") where parameter.hasPrefix("page=") {
            let digits = parameter.dropFirst("page=".count)
            guard !digits.isEmpty,
                digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                let page = Int(digits),
                page >= 1
            else { return nil }
            return page
        }
        return nil
    }

    /// The start term of a `text=` directive, which is the part a reader can search for.
    static func textDirectiveSnippet(_ directive: String) -> String? {
        var parts = directive.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 1, parts[0].hasSuffix("-") { parts.removeFirst() }
        if parts.count > 1, parts[parts.count - 1].hasPrefix("-") { parts.removeLast() }
        guard let start = parts.first, !start.isEmpty else { return nil }
        return start.removingPercentEncoding ?? start
    }

    static func textDirective(forSnippet snippet: String) -> String? {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(snippetCharacterLimit))
            .addingPercentEncoding(withAllowedCharacters: textDirectiveAllowed)
    }

    static func encodedHTMLID(_ identifier: String) -> String? {
        guard !identifier.isEmpty else { return nil }
        return identifier.addingPercentEncoding(withAllowedCharacters: htmlIDAllowed)
    }

    static func encodedCFI(_ cfi: String) -> String? {
        guard !cfi.isEmpty else { return nil }
        return cfi.addingPercentEncoding(withAllowedCharacters: cfiAllowed)
    }

    /// `-`, `,` and `&` are directive syntax, so a snippet may never spell them literally.
    private static let textDirectiveAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "._~")
        return allowed
    }()

    /// Withholding `=` and `&` keeps an encoded identifier from reparsing as a parameter fragment.
    private static let htmlIDAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    /// Parentheses are withheld so the `epubcfi(...)` wrapper stays unambiguous.
    private static let cfiAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/:,.-_~!$'*+;@[]")
        return allowed
    }()
}

/// Emit audio time, resource, PDF page, then CFI; append unresolved references unchanged.
nonisolated struct OPDSProgressionPoint: Equatable, Sendable {
    var audioSeconds: TimeInterval?
    var resourcePath: String?
    var scrollToText: String?
    var htmlID: String?
    /// One-based, as RFC 8118 writes it.
    var pdfPage: Int?
    var epubCFI: String?
    var additional: [String] = []

    init(
        audioSeconds: TimeInterval? = nil,
        resourcePath: String? = nil,
        scrollToText: String? = nil,
        htmlID: String? = nil,
        pdfPage: Int? = nil,
        epubCFI: String? = nil,
        additional: [String] = []
    ) {
        self.audioSeconds = audioSeconds
        self.resourcePath = resourcePath
        self.scrollToText = scrollToText
        self.htmlID = htmlID
        self.pdfPage = pdfPage
        self.epubCFI = epubCFI
        self.additional = additional
    }

    init(references: [String]) {
        for raw in references where !raw.isEmpty {
            let reference = OPDSProgressionReference(raw: raw)
            var resolved = false

            switch reference.fragment {
            case .mediaTime(let seconds)? where audioSeconds == nil:
                audioSeconds = seconds
                resolved = true
            case .pdfPage(let page)? where pdfPage == nil:
                pdfPage = page
                resolved = true
            case .epubCFI(let cfi)? where epubCFI == nil:
                epubCFI = cfi
                resolved = true
            case .scrollToText(let directive)? where scrollToText == nil && !reference.path.isEmpty:
                guard let snippet = OPDSProgressionReference.textDirectiveSnippet(directive) else { break }
                scrollToText = snippet
                resolved = true
            case .htmlID(let identifier)? where htmlID == nil && !reference.path.isEmpty:
                htmlID = identifier
                resolved = true
            case nil where !reference.path.isEmpty:
                // A bare resource path, as a pre-paginated publication reports.
                resolved = resourcePath == nil
            default:
                break
            }

            if resolved, !reference.path.isEmpty, resourcePath == nil {
                resourcePath = reference.path
            }
            if !resolved { additional.append(raw) }
        }
    }

    var references: [String] {
        var result: [String] = []

        if let audioSeconds, audioSeconds.isFinite, audioSeconds >= 0 {
            result.append("#t=\(Self.mediaTimeText(audioSeconds))")
        }

        if let resourcePath, let path = Self.writablePath(resourcePath) {
            var refined = false
            if let scrollToText, let directive = OPDSProgressionReference.textDirective(forSnippet: scrollToText) {
                result.append("\(path)#:~:text=\(directive)")
                refined = true
            }
            if let htmlID, let encoded = OPDSProgressionReference.encodedHTMLID(htmlID) {
                result.append("\(path)#\(encoded)")
                refined = true
            }
            if !refined { result.append(path) }
        }

        if let pdfPage, pdfPage >= 1 {
            result.append("#page=\(pdfPage)")
        }
        if let epubCFI, let encoded = OPDSProgressionReference.encodedCFI(epubCFI) {
            result.append("#epubcfi(\(encoded))")
        }

        return result + Self.merging(additional, into: result)
    }

    /// Percent-encode locator paths that are not valid URI references.
    private static func writablePath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        if OPDSProgressionURI.isReference(path) { return path }
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            OPDSProgressionURI.isReference(encoded)
        else { return nil }
        return encoded
    }

    /// Replace retained references of regenerated kinds to avoid sending conflicting positions.
    private static func merging(_ retained: [String], into generated: [String]) -> [String] {
        var occupied = Set(generated.map { slot(of: $0) })
        return retained.filter { !$0.isEmpty && occupied.insert(slot(of: $0)).inserted }
    }

    /// Unknown fragments match only themselves so distinct vendor extensions survive merging.
    private static func slot(of raw: String) -> String {
        switch OPDSProgressionReference(raw: raw).fragment {
        case .mediaTime?: "time"
        case .pdfPage?: "page"
        case .epubCFI?: "cfi"
        case .scrollToText?: "text"
        case .htmlID?: "id"
        case .opaque?: raw
        case nil: "path"
        }
    }

    private static func mediaTimeText(_ seconds: TimeInterval) -> String {
        var text = String(format: "%.3f", seconds)
        guard text.contains(".") else { return text }
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
