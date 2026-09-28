import Foundation
import Logging

enum KOReaderXPointerConverter {

    nonisolated static func locatorJSON(
        xpointer: String,
        percentage: Double,
        epubFileURL: URL
    ) async -> String? {
        #if os(tvOS)
        // The tvOS target has no reader and does not link a zip reader.
        return nil
        #else
        let work = Task.detached(priority: .utility) {
            try await convert(xpointer: xpointer, percentage: percentage, epubFileURL: epubFileURL)
        }
        return await outcome(of: work, describing: "KOReader xpointer conversion failed")
        #endif
    }

    nonisolated static func xpointer(
        forLocatorJSON locatorJSON: String,
        epubFileURL: URL
    ) async -> String? {
        #if os(tvOS)
        return nil
        #else
        let work = Task.detached(priority: .utility) {
            try await reverseConvert(locatorJSON: locatorJSON, epubFileURL: epubFileURL)
        }
        return await outcome(of: work, describing: "KOReader reverse xpointer failed")
        #endif
    }

    #if !os(tvOS)

    /// Detaching keeps the archive read and the DOM walk off the main actor; the cancellation
    /// handler restores the link to the caller that a detached task does not inherit.
    nonisolated private static func outcome(of work: Task<String, Error>, describing failure: String) async -> String? {
        do {
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch is CancellationError {
            return nil
        } catch {
            AppLogger.sync.warning("\(failure): \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated private static func convert(
        xpointer: String,
        percentage: Double,
        epubFileURL: URL
    ) async throws -> String {
        let parsed = try parseXPointer(xpointer)
        let archive = try await EpubArchive(url: epubFileURL)
        let spineHrefs = linearSpineHrefs(in: archive.package)

        guard parsed.spineIndex >= 0, parsed.spineIndex < spineHrefs.count else {
            throw ConversionError.spineIndexOutOfBounds(parsed.spineIndex, spineHrefs.count)
        }

        let spineHref = spineHrefs[parsed.spineIndex]
        let html = try await archive.html(at: spineHref)
        let partialCfi = try buildPartialCFI(html: html, parsed: parsed)

        return buildLocatorJSON(href: spineHref, partialCfi: partialCfi, progression: percentage)
    }

    nonisolated private static func reverseConvert(locatorJSON: String, epubFileURL: URL) async throws -> String {
        guard let data = locatorJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ConversionError.invalidXPointer(locatorJSON)
        }

        guard let href = json["href"] as? String else {
            throw ConversionError.invalidXPointer("missing href")
        }

        let locations = json["locations"] as? [String: Any]
        let otherLocations = locations?["otherLocations"] as? [String: Any]
        guard let partialCfi = otherLocations?["partialCfi"] as? String, !partialCfi.isEmpty else {
            throw ConversionError.invalidXPointer("no partialCfi")
        }

        let archive = try await EpubArchive(url: epubFileURL)
        let spineHrefs = linearSpineHrefs(in: archive.package)

        guard let spineIndex = spineHrefs.firstIndex(where: { $0.hasSuffix(href) || $0 == href }) else {
            throw ConversionError.spineIndexOutOfBounds(-1, spineHrefs.count)
        }

        let html = try await archive.html(at: spineHrefs[spineIndex])
        let suffix = try xpointerSuffix(forPartialCFI: partialCfi, html: html)
        return "/body/DocFragment[\(spineIndex + 1)]/body" + suffix
    }

    /// KOReader's DocFragment numbering skips non-linear spine items.
    nonisolated private static func linearSpineHrefs(in package: EpubPackage) -> [String] {
        package.spine.filter(\.isLinear).map(\.href)
    }

    #endif

    /// Where a KOReader xpointer points inside one element: either into a text node or, when the
    /// offset sits on the element itself, at the element's own content boundary.
    fileprivate enum XPointerOffset: Equatable {
        /// `/text()[K].N` — `K` is 1 for the unbracketed `/text().N` form.
        case text(nodeIndex: Int, characterOffset: Int)
        /// `.N` on an element. crengine counts child nodes here, not characters.
        case element
    }

    fileprivate struct ParsedXPointer {
        let spineIndex: Int
        let elementPath: [PathSegment]
        let offset: XPointerOffset?
    }

    fileprivate struct PathSegment {
        let tagName: String
        let index: Int
    }

    nonisolated private static func parseXPointer(_ xpointer: String) throws -> ParsedXPointer {
        // Trailing groups: the optional `/text()` marker, its optional `[K]` index, and the
        // optional `.N` offset that may follow either the text node or the element itself.
        let docFragmentRegex = try NSRegularExpression(
            pattern: #"^/body/DocFragment\[(\d+)\]/body(.*?)(/text\(\)(?:\[(\d+)\])?)?(?:\.(\d+))?$"#
        )
        let range = NSRange(xpointer.startIndex..., in: xpointer)
        guard let match = docFragmentRegex.firstMatch(in: xpointer, range: range) else {
            throw ConversionError.invalidXPointer(xpointer)
        }

        let source = xpointer as NSString
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : source.substring(with: range)
        }

        guard let spineN = group(1).flatMap(Int.init) else { throw ConversionError.invalidXPointer(xpointer) }
        let elementPath = try parseElementPath(group(2) ?? "")
        let characterOffset = group(5).flatMap(Int.init)

        let offset: XPointerOffset?
        if group(3) != nil {
            offset = .text(nodeIndex: group(4).flatMap(Int.init) ?? 1, characterOffset: characterOffset ?? 0)
        } else {
            offset = characterOffset == nil ? nil : .element
        }

        return ParsedXPointer(spineIndex: spineN - 1, elementPath: elementPath, offset: offset)
    }

    nonisolated private static func parseElementPath(_ path: String) throws -> [PathSegment] {
        guard !path.isEmpty else { return [] }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        return try segments.map { segment in
            let s = String(segment)
            if let open = s.firstIndex(of: "["), s.hasSuffix("]") {
                let tag = String(s[s.startIndex..<open])
                guard let index = Int(s[s.index(after: open)..<s.index(before: s.endIndex)]), index >= 1,
                    isTagName(tag)
                else {
                    throw ConversionError.invalidPathSegment(s)
                }
                return PathSegment(tagName: tag.lowercased(), index: index)
            }
            guard isTagName(s) else { throw ConversionError.invalidPathSegment(s) }
            return PathSegment(tagName: s.lowercased(), index: 1)
        }
    }

    nonisolated private static func isTagName(_ candidate: String) -> Bool {
        !candidate.isEmpty && candidate.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// Spine-item half of the forward conversion: the DOM walk, without the EPUB access around it.
    nonisolated static func partialCFI(forXPointer xpointer: String, html: String) throws -> String {
        try buildPartialCFI(html: html, parsed: parseXPointer(xpointer))
    }

    nonisolated private static func buildPartialCFI(html: String, parsed: ParsedXPointer) throws -> String {
        let domParser = EpubXHTMLDocument()
        try domParser.parse(html: html)

        let targetNode = try domParser.resolve(path: parsed.elementPath)
        var cfi = "/4" + domParser.cfiSteps(for: targetNode)

        // An element-level offset is a child index in crengine, not a character offset, so the
        // element itself is the honest anchor; a text offset maps onto a CFI text node.
        if case .text(let nodeIndex, let characterOffset) = parsed.offset {
            let position = domParser.cfiTextPosition(
                in: targetNode,
                textNodeIndex: nodeIndex,
                characterOffset: characterOffset
            )
            cfi += "/\(position.step):\(position.offset)"
        }
        return cfi
    }

    nonisolated private static func buildLocatorJSON(href: String, partialCfi: String, progression: Double) -> String {

        let escapedHref = href.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedCfi = partialCfi.replacingOccurrences(of: "\"", with: "\\\"")
        let prog = min(max(progression, 0), 1)
        return """
            {"href":"\(escapedHref)","type":"application/xhtml+xml","locations":{"totalProgression":\(prog),"otherLocations":{"partialCfi":"\(escapedCfi)"}}}
            """
    }

    /// Spine-item half of the reverse conversion: everything a KOReader xpointer carries after
    /// `/body/DocFragment[n]/body`.
    nonisolated static func xpointerSuffix(forPartialCFI partialCfi: String, html: String) throws -> String {
        let domParser = EpubXHTMLDocument()
        try domParser.parse(html: html)

        var cfi = partialCfi
        if cfi.hasPrefix("/4") { cfi = String(cfi.dropFirst(2)) }

        // A character offset may carry a CFI text assertion; it is a repair hint, not a position.
        var characterOffset: Int?
        if let (value, remainder) = try trailingCapture(in: cfi, pattern: #":(\d+)(?:\[[^\]]*\])?$"#) {
            characterOffset = Int(value)
            cfi = remainder
        }

        // A text node is an odd CFI step. An even trailing step is an element and stays in the path.
        var textStep: Int?
        if let (value, remainder) = try trailingCapture(in: cfi, pattern: #"/(\d+)(?:\[[^\]]*\])?$"#),
            let step = Int(value), step % 2 == 1
        {
            textStep = step
            cfi = remainder
        }

        let stepRegex = try NSRegularExpression(pattern: #"/(\d+)(?:\[([^\]]*)\])?"#)
        let cfiNS = cfi as NSString
        var node = try domParser.bodyNode()
        var suffix = ""

        for match in stepRegex.matches(in: cfi, range: NSRange(cfi.startIndex..., in: cfi)) {
            guard let step = Int(cfiNS.substring(with: match.range(at: 1))), step % 2 == 0 else { continue }
            let idHint =
                match.range(at: 2).location != NSNotFound
                ? cfiNS.substring(with: match.range(at: 2))
                : nil

            guard let next = domParser.elementChild(of: node, at: step / 2, idHint: idHint) else { break }
            suffix += "/\(next.tagName)[\(domParser.siblingIndex(of: next, in: node))]"
            node = next
        }

        guard let characterOffset else { return suffix + ".0" }
        guard let text = domParser.textRunPosition(in: node, cfiStep: textStep ?? 1, cfiOffset: characterOffset) else {
            return suffix + "/text().\(characterOffset)"
        }
        // crengine writes the unbracketed form when it means the first text node.
        let selector = text.index > 1 ? "/text()[\(text.index)]" : "/text()"
        return suffix + selector + ".\(text.offset)"
    }

    /// Matches an end-anchored pattern with one capture and returns it alongside the text in front of it.
    nonisolated private static func trailingCapture(in text: String, pattern: String) throws -> (String, String)? {
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let whole = Range(match.range, in: text),
            let captured = Range(match.range(at: 1), in: text)
        else { return nil }
        return (String(text[captured]), String(text[text.startIndex..<whole.lowerBound]))
    }

    enum ConversionError: Error, LocalizedError {
        case invalidXPointer(String)
        case invalidPathSegment(String)
        case spineIndexOutOfBounds(Int, Int)
        case elementNotFound(String)

        var errorDescription: String? {
            switch self {
            case .invalidXPointer(let s): return "Invalid KoReader xpointer: \(s)"
            case .invalidPathSegment(let s): return "Invalid xpointer segment: \(s)"
            case .spineIndexOutOfBounds(let i, let c): return "Spine index \(i) out of bounds (\(c) items)"
            case .elementNotFound(let p): return "Element not found at path: \(p)"
            }
        }
    }
}


extension EpubXHTMLDocument {
    /// Walks the whole ancestry. KOReader indexes each step among its own siblings, so resolving
    /// only the last step against the document would land in the wrong branch whenever a tag
    /// repeats across containers.
    nonisolated fileprivate func resolve(path: [KOReaderXPointerConverter.PathSegment]) throws -> Node {
        var current = try bodyNode()
        for segment in path {
            guard let next = elementChild(of: current, tagName: segment.tagName, occurrence: segment.index) else {
                throw KOReaderXPointerConverter.ConversionError.elementNotFound("\(segment.tagName)[\(segment.index)]")
            }
            current = next
        }
        return current
    }

    nonisolated private func elementChild(of parent: Node, tagName: String, occurrence: Int) -> Node? {
        guard occurrence >= 1 else { return nil }
        var seen = 0
        for child in parent.children where child.tagName == tagName {
            seen += 1
            if seen == occurrence { return child }
        }
        return nil
    }

    /// CFI numbers a text node `2 * elementsBefore + 1` and counts its offset in UTF-16 units,
    /// while a KOReader offset counts Unicode scalars inside one crengine text node.
    nonisolated fileprivate func cfiTextPosition(in node: Node, textNodeIndex: Int, characterOffset: Int) -> (step: Int, offset: Int) {
        guard textNodeIndex >= 1, textNodeIndex <= node.textRuns.count else {
            // The sending device saw markup we do not have; the leading text node is the closest anchor.
            return (1, characterOffset)
        }
        let run = node.textRuns[textNodeIndex - 1]
        return (2 * run.elementsBefore + 1, run.cfiOffset + Self.utf16Offset(in: run.text, scalarOffset: characterOffset))
    }

    nonisolated fileprivate func textRunPosition(in node: Node, cfiStep: Int, cfiOffset: Int) -> (index: Int, offset: Int)? {
        guard cfiStep % 2 == 1, cfiOffset >= 0 else { return nil }
        let elementsBefore = (cfiStep - 1) / 2

        var found: (index: Int, run: TextRun)?
        for (position, run) in node.textRuns.enumerated()
        where run.elementsBefore == elementsBefore && run.cfiOffset <= cfiOffset {
            found = (position + 1, run)
        }
        guard let found else { return nil }
        return (found.index, Self.scalarOffset(in: found.run.text, utf16Offset: cfiOffset - found.run.cfiOffset))
    }

    nonisolated private static func utf16Offset(in text: String, scalarOffset: Int) -> Int {
        var remaining = scalarOffset
        var width = 0
        for scalar in text.unicodeScalars {
            guard remaining > 0 else { break }
            width += UTF16.width(scalar)
            remaining -= 1
        }
        return width
    }

    nonisolated private static func scalarOffset(in text: String, utf16Offset: Int) -> Int {
        var consumed = 0
        var scalars = 0
        for scalar in text.unicodeScalars {
            guard consumed < utf16Offset else { break }
            consumed += UTF16.width(scalar)
            scalars += 1
        }
        return scalars
    }
}
