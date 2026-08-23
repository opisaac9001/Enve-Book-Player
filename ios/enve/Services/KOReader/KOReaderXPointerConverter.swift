import Foundation
import Logging
import Zip

enum KOReaderXPointerConverter {

    nonisolated static func locatorJSON(
        xpointer: String,
        percentage: Double,
        epubFileURL: URL
    ) async -> String? {
        await Task.detached(priority: .utility) {
            do {
                return try convert(xpointer: xpointer, percentage: percentage, epubFileURL: epubFileURL)
            } catch {
                AppLogger.sync.warning("KOReader xpointer conversion failed: \(error.localizedDescription)")
                return nil
            }
        }.value
    }

    nonisolated private static func convert(
        xpointer: String,
        percentage: Double,
        epubFileURL: URL
    ) throws -> String {
        let parsed = try parseXPointer(xpointer)
        let spineHrefs = try readSpineHrefs(epubFileURL: epubFileURL)

        guard parsed.spineIndex < spineHrefs.count else {
            throw ConversionError.spineIndexOutOfBounds(parsed.spineIndex, spineHrefs.count)
        }

        let spineHref = spineHrefs[parsed.spineIndex]
        let spineItemData = try readEPUBEntry(epubFileURL: epubFileURL, entryPath: spineHref)
        guard let html = String(data: spineItemData, encoding: .utf8) ?? String(data: spineItemData, encoding: .isoLatin1) else {
            throw ConversionError.htmlDecodingFailed(spineHref)
        }

        let partialCfi = try buildPartialCFI(
            html: html,
            elementPath: parsed.elementPath,
            textOffset: parsed.textOffset
        )

        return buildLocatorJSON(
            href: spineHref,
            partialCfi: partialCfi,
            progression: percentage
        )
    }

    private struct ParsedXPointer {
        let spineIndex: Int
        let elementPath: [PathSegment]
        let textOffset: Int?
    }

    fileprivate struct PathSegment {
        let tagName: String
        let index: Int
    }

    nonisolated private static func parseXPointer(_ xpointer: String) throws -> ParsedXPointer {

        let docFragmentRegex = try NSRegularExpression(pattern: #"^/body/DocFragment\[(\d+)\]/body(.*?)(?:/text\(\)\.(\d+))?$"#)
        let range = NSRange(xpointer.startIndex..., in: xpointer)
        guard let match = docFragmentRegex.firstMatch(in: xpointer, range: range) else {
            throw ConversionError.invalidXPointer(xpointer)
        }

        let spineN = Int((xpointer as NSString).substring(with: match.range(at: 1)))!
        let spineIndex = spineN - 1

        let bodyPath =
            match.range(at: 2).location != NSNotFound
            ? (xpointer as NSString).substring(with: match.range(at: 2))
            : ""

        let textOffset: Int? =
            match.range(at: 3).location != NSNotFound
            ? Int((xpointer as NSString).substring(with: match.range(at: 3)))
            : nil

        let elementPath = try parseElementPath(bodyPath)
        return ParsedXPointer(spineIndex: spineIndex, elementPath: elementPath, textOffset: textOffset)
    }

    nonisolated private static func parseElementPath(_ path: String) throws -> [PathSegment] {
        guard !path.isEmpty else { return [] }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        return try segments.map { segment in
            let s = String(segment)
            if s.range(of: #"^(\w+)\[(\d+)\]$"#, options: .regularExpression) != nil {
                let parts = s.components(separatedBy: "[")
                let tag = parts[0]
                let idx = Int(parts[1].dropLast())!
                return PathSegment(tagName: tag.lowercased(), index: idx)
            } else if s.range(of: #"^\w+$"#, options: .regularExpression) != nil {
                return PathSegment(tagName: s.lowercased(), index: 1)
            } else {
                throw ConversionError.invalidPathSegment(s)
            }
        }
    }

    nonisolated private static func readSpineHrefs(epubFileURL: URL) throws -> [String] {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("koreader_xptr_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try Zip.unzipFile(epubFileURL, destination: tempDir, overwrite: true, password: nil)

        let containerURL = tempDir.appendingPathComponent("META-INF/container.xml")
        let containerData = try Data(contentsOf: containerURL)
        let opfRelativePath = try parseOPFPath(from: containerData)

        let opfURL = tempDir.appendingPathComponent(opfRelativePath)
        let opfData = try Data(contentsOf: opfURL)
        let opfBaseDir = (opfRelativePath as NSString).deletingLastPathComponent

        return try parseSpineHrefs(opfData: opfData, opfBaseDir: opfBaseDir)
    }

    nonisolated private static func parseOPFPath(from containerData: Data) throws -> String {
        let parser = OPFPathParser()
        let xmlParser = XMLParser(data: containerData)
        xmlParser.delegate = parser
        xmlParser.parse()
        guard let path = parser.opfPath else {
            throw ConversionError.missingOPFPath
        }
        return path
    }

    nonisolated private static func parseSpineHrefs(opfData: Data, opfBaseDir: String) throws -> [String] {
        let parser = SpineParser()
        let xmlParser = XMLParser(data: opfData)
        xmlParser.delegate = parser
        xmlParser.parse()

        return parser.spineIdrefs.compactMap { idref in
            guard let href = parser.manifestHrefByID[idref] else { return nil }
            if opfBaseDir.isEmpty { return href }
            return opfBaseDir + "/" + href
        }
    }

    nonisolated private static func readEPUBEntry(epubFileURL: URL, entryPath: String) throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("koreader_entry_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try Zip.unzipFile(epubFileURL, destination: tempDir, overwrite: true, password: nil)
        let fileURL = tempDir.appendingPathComponent(entryPath)
        return try Data(contentsOf: fileURL)
    }

    nonisolated private static func buildPartialCFI(
        html: String,
        elementPath: [PathSegment],
        textOffset: Int?
    ) throws -> String {
        let domParser = HTMLDOMParser()
        try domParser.parse(html: html)

        guard !elementPath.isEmpty else {
            return "/4"
        }

        let targetNode = try domParser.resolve(path: elementPath)
        let cfiSteps = domParser.cfiSteps(for: targetNode)

        var cfi = "/4" + cfiSteps
        if let offset = textOffset {
            cfi += "/1:\(offset)"
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

    nonisolated static func xpointer(
        forLocatorJSON locatorJSON: String,
        epubFileURL: URL
    ) async -> String? {
        await Task.detached(priority: .utility) {
            do {
                return try reverseConvert(locatorJSON: locatorJSON, epubFileURL: epubFileURL)
            } catch {
                AppLogger.sync.warning("KOReader reverse xpointer failed: \(error.localizedDescription)")
                return nil
            }
        }.value
    }

    nonisolated private static func reverseConvert(locatorJSON: String, epubFileURL: URL) throws -> String {
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

        let _ = (locations?["totalProgression"] as? Double) ?? 0

        let spineHrefs = try readSpineHrefs(epubFileURL: epubFileURL)

        guard let spineIndex = spineHrefs.firstIndex(where: { $0.hasSuffix(href) || $0 == href }) else {
            throw ConversionError.spineIndexOutOfBounds(-1, spineHrefs.count)
        }

        let spineHref = spineHrefs[spineIndex]
        let spineItemData = try readEPUBEntry(epubFileURL: epubFileURL, entryPath: spineHref)
        guard let html = String(data: spineItemData, encoding: .utf8) ?? String(data: spineItemData, encoding: .isoLatin1) else {
            throw ConversionError.htmlDecodingFailed(spineHref)
        }

        let (elementPath, textOffset) = try buildXPointerPath(html: html, partialCfi: partialCfi)

        let docN = spineIndex + 1
        var xpointer = "/body/DocFragment[\(docN)]/body"
        for seg in elementPath {
            xpointer += "/\(seg.tagName)[\(seg.index)]"
        }
        if let offset = textOffset {
            xpointer += "/text().\(offset)"
        } else {
            xpointer += ".0"
        }

        return xpointer
    }

    nonisolated private static func buildXPointerPath(html: String, partialCfi: String) throws -> (path: [PathSegment], textOffset: Int?) {
        let domParser = HTMLDOMParser()
        try domParser.parse(html: html)

        var cfi = partialCfi
        if cfi.hasPrefix("/4") { cfi = String(cfi.dropFirst(2)) }

        var textOffset: Int? = nil

        let textRe = try NSRegularExpression(pattern: #"(?:/1)?:(\d+)$"#)
        let cfiNS = cfi as NSString
        if let tm = textRe.firstMatch(in: cfi, range: NSRange(cfi.startIndex..., in: cfi)) {
            textOffset = Int(cfiNS.substring(with: tm.range(at: 1)))
            cfi = String(cfi.prefix(tm.range.location))
        }
        let textNodeRe = try NSRegularExpression(pattern: #"/text\(\)\[\d+\]$"#)
        cfi = textNodeRe.stringByReplacingMatches(in: cfi, range: NSRange(cfi.startIndex..., in: cfi), withTemplate: "")

        let stepRe = try NSRegularExpression(pattern: #"/(\d+)(?:\[([^\]]*)\])?"#)
        let matches = stepRe.matches(in: cfi, range: NSRange(cfi.startIndex..., in: cfi))

        var node = domParser.bodyNode()
        var path: [PathSegment] = []

        for match in matches {
            let stepStr = cfiNS.substring(with: match.range(at: 1))
            guard let step = Int(stepStr), step % 2 == 0 else { continue }
            let elementPos = step / 2

            let idHint =
                match.range(at: 2).location != NSNotFound
                ? cfiNS.substring(with: match.range(at: 2))
                : nil

            guard let nextNode = domParser.elementChild(of: node, at: elementPos, idHint: idHint) else { break }
            let tagIndex = domParser.koreaderIndex(of: nextNode, in: node)
            path.append(PathSegment(tagName: nextNode.tagName, index: tagIndex))
            node = nextNode
        }

        return (path, textOffset)
    }

    enum ConversionError: Error, LocalizedError {
        case invalidXPointer(String)
        case invalidPathSegment(String)
        case missingOPFPath
        case spineIndexOutOfBounds(Int, Int)
        case elementNotFound(String)
        case htmlDecodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidXPointer(let s): return "Invalid KoReader xpointer: \(s)"
            case .invalidPathSegment(let s): return "Invalid xpointer segment: \(s)"
            case .missingOPFPath: return "EPUB container.xml missing OPF path"
            case .spineIndexOutOfBounds(let i, let c): return "Spine index \(i) out of bounds (\(c) items)"
            case .elementNotFound(let p): return "Element not found at path: \(p)"
            case .htmlDecodingFailed(let f): return "Could not decode HTML: \(f)"
            }
        }
    }
}

private final class OPFPathParser: NSObject, XMLParserDelegate {
    nonisolated(unsafe) var opfPath: String?

    nonisolated override init() { super.init() }

    nonisolated func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        if elementName == "rootfile" || qualifiedName == "rootfile",
            let path = attributes["full-path"], opfPath == nil
        {
            opfPath = path
        }
    }
}

private final class SpineParser: NSObject, XMLParserDelegate {
    nonisolated(unsafe) var manifestHrefByID: [String: String] = [:]
    nonisolated(unsafe) var spineIdrefs: [String] = []

    nonisolated override init() { super.init() }

    nonisolated func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        let tag = (qualifiedName ?? elementName).components(separatedBy: ":").last ?? elementName
        switch tag {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                manifestHrefByID[id] = href
            }
        case "itemref":
            if let idref = attributes["idref"] {
                if attributes["linear"] != "no" {
                    spineIdrefs.append(idref)
                }
            }
        default:
            break
        }
    }
}

private final class HTMLDOMParser: NSObject, XMLParserDelegate {

    final class Node {
        let tagName: String
        nonisolated(unsafe) weak var parent: Node?
        nonisolated(unsafe) var children: [Node] = []
        nonisolated(unsafe) var childIndexAmongParent: Int = 0

        nonisolated init(tagName: String, parent: Node?) {
            self.tagName = tagName
            self.parent = parent
        }
    }

    nonisolated(unsafe) private var root: Node?
    nonisolated(unsafe) private var stack: [Node] = []
    nonisolated(unsafe) private var allByTag: [String: [Node]] = [:]

    nonisolated override init() { super.init() }

    nonisolated func parse(html: String) throws {
        let xmlString: String
        if html.contains("<?xml") || html.contains("<html") {
            xmlString = html
        } else {
            xmlString = "<root>\(html)</root>"
        }
        guard let data = xmlString.data(using: .utf8) else { return }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.parse()
    }

    nonisolated func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        let tag = elementName.lowercased()
        let node = Node(tagName: tag, parent: stack.last)
        stack.last?.children.append(node)

        if let parent = stack.last {
            let sameTag = parent.children.filter { $0.tagName == tag }
            node.childIndexAmongParent = sameTag.count
        } else {
            node.childIndexAmongParent = 1
        }

        allByTag[tag, default: []].append(node)

        if root == nil { root = node }
        stack.append(node)
    }

    nonisolated func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if !stack.isEmpty { stack.removeLast() }
    }

    nonisolated func resolve(path: [KOReaderXPointerConverter.PathSegment]) throws -> Node {
        guard !path.isEmpty else {
            guard let body = findBody() else {
                throw KOReaderXPointerConverter.ConversionError.elementNotFound("body")
            }
            return body
        }

        let last = path.last!
        let tag = last.tagName
        let idx = last.index - 1

        guard let globalList = allByTag[tag], idx < globalList.count else {
            throw KOReaderXPointerConverter.ConversionError.elementNotFound("\(tag)[\(last.index)]")
        }
        return globalList[idx]
    }

    nonisolated private func findBody() -> Node? {
        allByTag["body"]?.first
    }

    nonisolated func bodyNode() -> Node {
        findBody() ?? (root ?? Node(tagName: "root", parent: nil))
    }

    nonisolated func elementChild(of parent: Node, at position: Int, idHint: String?) -> Node? {
        let elementChildren = parent.children.filter { !$0.tagName.hasPrefix("#") }
        if let id = idHint, !id.isEmpty {
            if let found = elementChildren.first(where: {
                $0.tagName == id || allByTag[$0.tagName]?.firstIndex(where: { $0 === $0 }) != nil
            }) {
                return found
            }
        }
        guard position >= 1, position <= elementChildren.count else { return nil }
        return elementChildren[position - 1]
    }

    nonisolated func koreaderIndex(of node: Node, in parent: Node) -> Int {
        let siblings = parent.children.filter { $0.tagName == node.tagName }
        return (siblings.firstIndex(where: { $0 === node }) ?? 0) + 1
    }

    nonisolated func cfiSteps(for node: Node) -> String {
        var current: Node? = node
        var parts: [String] = []

        while let n = current, n.tagName != "body", n.tagName != "html", n.tagName != "root" {
            guard let parent = n.parent else { break }
            let pos = allChildIndex(of: n, in: parent)
            parts.insert("/\(pos * 2)", at: 0)
            current = parent
        }
        return parts.joined()
    }

    nonisolated private func allChildIndex(of node: Node, in parent: Node) -> Int {
        return (parent.children.firstIndex(where: { $0 === node }) ?? 0) + 1
    }
}
