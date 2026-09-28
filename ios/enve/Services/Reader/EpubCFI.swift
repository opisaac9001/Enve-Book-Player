import Foundation
import Logging

#if !os(tvOS)
import ReadiumZIPFoundation
#endif

/// EPUB CFIs built from, and resolved against, the book's own package document and XHTML.
nonisolated enum EpubCFI {
    struct Step: Equatable, Sendable {
        var index: Int
        var assertion: String?
        var offset: Int?
    }

    /// A point CFI split at its indirection; a range keeps its start.
    struct Parsed: Equatable, Sendable {
        let package: [Step]
        let local: [Step]
    }

    /// The text chunk is the character data after `chunk` child elements, as CFI odd steps count it.
    struct TextPosition: Equatable, Sendable {
        let chunk: Int
        let offset: Int
    }

    struct Point {
        let element: EpubXHTMLDocument.Node
        let text: TextPosition?

        func isSameLocation(as other: Point) -> Bool {
            element === other.element && text == other.text
        }
    }

    static func parse(_ value: String) -> Parsed? {
        guard let cfi = EpubLocationBridge.normalizedEPUBCFI(value) else { return nil }
        let characters = Array(cfi.dropFirst("epubcfi(".count).dropLast())
        var paths: [[Step]] = [[]]
        var commas = 0
        var index = 0

        func number() -> Int? {
            let start = index
            while index < characters.count, characters[index].isASCII, characters[index].isNumber { index += 1 }
            return index > start ? Int(String(characters[start..<index])) : nil
        }

        parsing: while index < characters.count {
            let character = characters[index]
            index += 1
            switch character {
            case "/":
                guard let value = number() else { return nil }
                paths[paths.count - 1].append(Step(index: value))
            case ":":
                guard let value = number(), !paths[paths.count - 1].isEmpty else { return nil }
                paths[paths.count - 1][paths[paths.count - 1].count - 1].offset = value
            case "[":
                var assertion = ""
                var isEscaped = false
                var hasParameters = false
                var closed = false
                while index < characters.count {
                    let next = characters[index]
                    index += 1
                    if isEscaped {
                        if !hasParameters { assertion.append(next) }
                        isEscaped = false
                    } else if next == "^" {
                        isEscaped = true
                    } else if next == "]" {
                        closed = true
                        break
                    } else if next == ";" {
                        hasParameters = true
                    } else if !hasParameters {
                        assertion.append(next)
                    }
                }
                guard closed, var step = paths[paths.count - 1].last else { return nil }
                // Only an element step's assertion is an id; text assertions and side bias are hints.
                if step.offset == nil, step.assertion == nil, step.index % 2 == 0, !assertion.isEmpty {
                    step.assertion = assertion
                    paths[paths.count - 1][paths[paths.count - 1].count - 1] = step
                }
            case "!":
                paths.append([])
            case ",":
                commas += 1
                if commas == 2 { break parsing }
            case "~", "@":
                while index < characters.count, characters[index].isNumber || characters[index] == "." || characters[index] == ":" {
                    index += 1
                }
            default:
                return nil
            }
        }

        guard paths.count == 2, paths[0].count >= 2, !paths[1].isEmpty else { return nil }
        return Parsed(package: paths[0], local: paths[1])
    }

    static func string(package: EpubPackage, spineIndex: Int, localPath: String) -> String {
        let itemref = package.spine[spineIndex]
        return "epubcfi(/\(package.spineStep)/\((spineIndex + 1) * 2)\(assertion(itemref.itemrefID))!\(localPath))"
    }

    static func assertion(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "" }
        var escaped = ""
        for character in id {
            if "^[](),;=".contains(character) { escaped.append("^") }
            escaped.append(character)
        }
        return "[\(escaped)]"
    }

    static func spineIndex(of parsed: Parsed, in package: EpubPackage) -> Int? {
        let itemref = parsed.package[parsed.package.count - 1]
        if let id = itemref.assertion, let match = package.spine.firstIndex(where: { $0.itemrefID == id }) {
            return match
        }
        guard itemref.index % 2 == 0 else { return nil }
        let index = itemref.index / 2 - 1
        return package.spine.indices.contains(index) ? index : nil
    }

    /// The id a media overlay narrates at `point`: its own, the nearest ancestor's, or the first descendant's.
    static func narratedFragment(at point: Point, overlayFragments: Set<String>) -> String? {
        guard !overlayFragments.isEmpty else { return nil }
        var ancestor: EpubXHTMLDocument.Node? = point.element
        while let node = ancestor {
            if let id = node.elementID, overlayFragments.contains(id) { return id }
            ancestor = node.parent
        }
        var pending = point.text.map { Array(point.element.children.dropFirst($0.chunk)) } ?? point.element.children
        while !pending.isEmpty {
            let node = pending.removeFirst()
            if let id = node.elementID, overlayFragments.contains(id) { return id }
            pending.insert(contentsOf: node.children, at: 0)
        }
        return nil
    }

    /// The CFI for one spine document, kept only if resolving it lands on the same place.
    static func verifiedCFI(
        to point: Point,
        in document: EpubXHTMLDocument,
        spineIndex: Int,
        package: EpubPackage
    ) -> String? {
        guard document.isWellFormed, let localPath = document.localPath(to: point) else { return nil }
        let cfi = string(package: package, spineIndex: spineIndex, localPath: localPath)
        guard let parsed = parse(cfi),
            EpubCFI.spineIndex(of: parsed, in: package) == spineIndex,
            let resolved = document.resolve(parsed.local),
            resolved.isSameLocation(as: point)
        else { return nil }
        return cfi
    }

    /// Picks the point a Readium or Foliate locator describes inside `document`.
    static func point(forLocator json: [String: Any], in document: EpubXHTMLDocument) -> Point? {
        let locations = json["locations"] as? [String: Any] ?? [:]
        if let cfi = EpubLocationBridge.canonicalFullEPUBCFI(EpubLocationBridge.epubCFI(from: jsonString(json))),
            let parsed = parse(cfi)
        {
            return document.walk(parsed.local)
        }

        var ids = (locations["fragments"] as? [Any] ?? []).compactMap { $0 as? String }
            .filter { !$0.hasPrefix("t=") && EpubLocationBridge.normalizedEPUBCFI($0) == nil && !$0.contains("=") }
        let domRangeStart = (locations["domRange"] as? [String: Any])?["start"] as? [String: Any]
        for selector in [locations["cssSelector"] as? String, domRangeStart?["cssSelector"] as? String] {
            if let selector, selector.hasPrefix("#"), selector.count > 1,
                !selector.dropFirst().contains(where: { " >.:[".contains($0) })
            {
                ids.append(String(selector.dropFirst()))
            }
        }
        for id in ids {
            if let element = document.element(withID: id.hasPrefix("#") ? String(id.dropFirst()) : id) {
                return Point(element: element, text: nil)
            }
        }

        let index = document.textIndex()
        if let text = json["text"] as? [String: Any],
            let highlight = text["highlight"] as? String,
            let point = index.point(matching: highlight, before: text["before"] as? String)
        {
            return point
        }
        let progression = (locations["progression"] as? NSNumber)?.doubleValue ?? 0
        return index.point(atFraction: progression)
    }

    static func readiumLocator(
        at point: Point,
        in document: EpubXHTMLDocument,
        href: String,
        totalProgression: Double,
        overlayFragments: Set<String>
    ) -> [String: Any] {
        let index = document.textIndex()
        let offset = index.offset(of: point)
        var locations: [String: Any] = [
            "progression": index.length > 0 ? min(max(Double(offset) / Double(index.length), 0), 1) : 0,
            "totalProgression": min(max(totalProgression, 0), 1),
        ]
        var locator: [String: Any] = ["href": href, "type": "application/xhtml+xml"]
        if let fragment = narratedFragment(at: point, overlayFragments: overlayFragments) {
            locations["fragments"] = [fragment]
        } else if let quote = index.quote(at: offset) {
            var text: [String: Any] = ["highlight": quote.highlight]
            if !quote.before.isEmpty { text["before"] = quote.before }
            locator["text"] = text
        }
        locator["locations"] = locations
        return locator
    }

    static func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func jsonObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    #if !os(tvOS)

    /// A provider-portable CFI for a stored locator, or nil when it would not round-trip in this EPUB.
    static func providerCFI(forLocatorJSON locatorJSON: String, epubFileURL: URL) async -> String? {
        let work = Task.detached(priority: .utility) { () -> String? in
            guard let json = jsonObject(locatorJSON) else { return nil }
            let archive = try await EpubArchive(url: epubFileURL)
            let spineIndex: Int?
            if let cfi = EpubLocationBridge.canonicalFullEPUBCFI(EpubLocationBridge.epubCFI(from: locatorJSON)),
                let parsed = parse(cfi)
            {
                spineIndex = EpubCFI.spineIndex(of: parsed, in: archive.package)
            } else {
                spineIndex = (json["href"] as? String).flatMap(archive.package.spineIndex(forHref:))
            }
            guard let spineIndex else { return nil }
            let document = try await archive.document(spineIndex: spineIndex)
            guard let point = point(forLocator: json, in: document) else { return nil }
            return verifiedCFI(to: point, in: document, spineIndex: spineIndex, package: archive.package)
        }
        return await outcome(of: work, describing: "EPUB CFI upload conversion failed")
    }

    static func readiumLocatorJSON(
        forCFI cfi: String,
        totalProgression: Double,
        selectedText: String? = nil,
        epubFileURL: URL
    ) async -> String? {
        let work = Task.detached(priority: .utility) { () -> String? in
            guard let parsed = parse(cfi) else { return nil }
            let archive = try await EpubArchive(url: epubFileURL)
            guard let spineIndex = EpubCFI.spineIndex(of: parsed, in: archive.package) else { return nil }
            let document = try await archive.document(spineIndex: spineIndex)
            guard document.isWellFormed, let point = document.resolve(parsed.local) else { return nil }
            let fragments = await archive.overlayFragmentIDs(spineIndex: spineIndex)
            var locator = readiumLocator(
                at: point,
                in: document,
                href: archive.package.spine[spineIndex].href,
                totalProgression: totalProgression,
                overlayFragments: fragments
            )
            if let selectedText = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                !selectedText.isEmpty
            {
                var text = locator["text"] as? [String: Any] ?? [:]
                text["highlight"] = selectedText
                locator["text"] = text
            }
            return jsonString(locator)
        }
        return await outcome(of: work, describing: "EPUB CFI resolution failed")
    }

    private static func outcome(of work: Task<String?, Error>, describing failure: String) async -> String? {
        do {
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch is CancellationError {
            return nil
        } catch {
            AppLogger.sync.warning("\(failure): \(error.localizedDescription)")
            return nil
        }
    }

    #endif
}

nonisolated enum EpubDocumentError: Error, LocalizedError {
    case missingOPFPath
    case entryNotFound(String)
    case undecodableDocument(String)
    case missingBody

    var errorDescription: String? {
        switch self {
        case .missingOPFPath: return "EPUB container.xml missing OPF path"
        case .entryNotFound(let path): return "EPUB entry not found: \(path)"
        case .undecodableDocument(let path): return "Could not decode HTML: \(path)"
        case .missingBody: return "Element not found at path: body"
        }
    }
}

nonisolated struct EpubPackage: Sendable {
    struct SpineItem: Sendable, Equatable {
        let itemrefID: String?
        let href: String
        let mediaOverlayHref: String?
        let isLinear: Bool
    }

    /// The CFI step of `<spine>` among the package element's children.
    let spineStep: Int
    let spine: [SpineItem]

    init(spineStep: Int, spine: [SpineItem]) {
        self.spineStep = spineStep
        self.spine = spine
    }

    init(opfData: Data, opfPath: String) {
        let parser = EpubSpineParser()
        let xmlParser = XMLParser(data: opfData)
        xmlParser.delegate = parser
        xmlParser.parse()

        let baseDirectory = (opfPath as NSString).deletingLastPathComponent
        func archivePath(_ href: String) -> String {
            let decoded = href.removingPercentEncoding ?? href
            return Self.resolvingDotSegments(baseDirectory.isEmpty ? decoded : "\(baseDirectory)/\(decoded)")
        }

        spineStep = parser.spineStep
        spine = parser.itemrefs.compactMap { itemref in
            guard let item = parser.manifest[itemref.idref] else { return nil }
            return SpineItem(
                itemrefID: itemref.id,
                href: archivePath(item.href),
                mediaOverlayHref: item.mediaOverlay.flatMap { parser.manifest[$0] }.map { archivePath($0.href) },
                isLinear: itemref.isLinear
            )
        }
    }

    func spineIndex(forHref href: String) -> Int? {
        let target = Self.normalized(href)
        guard !target.isEmpty else { return nil }
        if let exact = spine.firstIndex(where: { Self.normalized($0.href) == target }) { return exact }
        return spine.firstIndex { item in
            let candidate = Self.normalized(item.href)
            return candidate.hasSuffix("/" + target) || target.hasSuffix("/" + candidate)
        }
    }

    static func resolvingDotSegments(_ path: String) -> String {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(component))
            }
        }
        return components.joined(separator: "/")
    }

    private static func normalized(_ href: String) -> String {
        let path = EpubLocationBridge.normalizedHref(href)
        return resolvingDotSegments(path)
    }
}

#if !os(tvOS)

/// Reads single members of an EPUB. Unpacking the whole book costs seconds and a second copy on disk.
nonisolated struct EpubArchive {
    let archive: Archive
    let package: EpubPackage

    init(url: URL) async throws {
        archive = try await Archive(url: url, accessMode: .read)
        let opfPath = try Self.opfPath(from: try await Self.entryData("META-INF/container.xml", from: archive))
        package = EpubPackage(opfData: try await Self.entryData(opfPath, from: archive), opfPath: opfPath)
    }

    func html(at path: String) async throws -> String {
        let data = try await Self.entryData(path, from: archive)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw EpubDocumentError.undecodableDocument(path)
        }
        return html
    }

    func document(spineIndex: Int) async throws -> EpubXHTMLDocument {
        let document = EpubXHTMLDocument()
        try document.parse(html: try await html(at: package.spine[spineIndex].href))
        return document
    }

    /// Fragment ids the spine item's media overlay narrates, read from its SMIL `<text src>` references.
    func overlayFragmentIDs(spineIndex: Int) async -> Set<String> {
        let item = package.spine[spineIndex]
        guard let smilPath = item.mediaOverlayHref,
            let data = try? await Self.entryData(smilPath, from: archive),
            let smil = String(data: data, encoding: .utf8)
        else { return [] }
        let smilDirectory = (smilPath as NSString).deletingLastPathComponent
        let documentName = (item.href as NSString).lastPathComponent
        guard let regex = try? NSRegularExpression(pattern: #"<(?:\w+:)?text\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#) else {
            return []
        }
        var fragments: Set<String> = []
        for match in regex.matches(in: smil, range: NSRange(smil.startIndex..., in: smil)) {
            guard let range = Range(match.range(at: 1), in: smil) else { continue }
            let parts = smil[range].split(separator: "#", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let path = String(parts[0])
            let resolved = EpubPackage.resolvingDotSegments(
                smilDirectory.isEmpty ? (path.removingPercentEncoding ?? path) : "\(smilDirectory)/\(path.removingPercentEncoding ?? path)"
            )
            if resolved == item.href || (resolved as NSString).lastPathComponent == documentName {
                fragments.insert(String(parts[1]))
            }
        }
        return fragments
    }

    static func entryData(_ entryPath: String, from archive: Archive) async throws -> Data {
        try Task.checkCancellation()
        guard let entry = try await archive.get(entryPath) else {
            throw EpubDocumentError.entryNotFound(entryPath)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub_entry_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        _ = try await archive.extract(entry, to: destination)
        return try Data(contentsOf: destination)
    }

    private static func opfPath(from containerData: Data) throws -> String {
        let parser = EpubOPFPathParser()
        let xmlParser = XMLParser(data: containerData)
        xmlParser.delegate = parser
        xmlParser.parse()
        guard let path = parser.opfPath else {
            throw EpubDocumentError.missingOPFPath
        }
        return path
    }
}

#endif

final class EpubOPFPathParser: NSObject, XMLParserDelegate {
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

final class EpubSpineParser: NSObject, XMLParserDelegate {
    nonisolated struct ManifestItem {
        let href: String
        let mediaOverlay: String?
    }

    nonisolated struct Itemref {
        let idref: String
        let id: String?
        let isLinear: Bool
    }

    nonisolated(unsafe) var manifest: [String: ManifestItem] = [:]
    nonisolated(unsafe) var itemrefs: [Itemref] = []
    nonisolated(unsafe) var spineStep = 6
    nonisolated(unsafe) private var depth = 0
    nonisolated(unsafe) private var packageChildren = 0

    nonisolated override init() { super.init() }

    nonisolated func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        depth += 1
        let tag = (qualifiedName ?? elementName).components(separatedBy: ":").last ?? elementName
        if depth == 2 {
            packageChildren += 1
            if tag == "spine" { spineStep = packageChildren * 2 }
        }
        switch tag {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                manifest[id] = ManifestItem(href: href, mediaOverlay: attributes["media-overlay"])
            }
        case "itemref":
            if let idref = attributes["idref"] {
                itemrefs.append(Itemref(idref: idref, id: attributes["id"], isLinear: attributes["linear"] != "no"))
            }
        default:
            break
        }
    }

    nonisolated func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        depth -= 1
    }
}

final class EpubXHTMLDocument: NSObject, XMLParserDelegate {

    /// One run of character data. Runs split by a comment, processing instruction, or CDATA
    /// boundary are separate crengine text nodes but a single addressable CFI text node, so each
    /// run records where it starts inside that merged node.
    struct TextRun {
        let elementsBefore: Int
        let cfiOffset: Int
        let text: String
    }

    final class Node {
        let tagName: String
        let elementID: String?
        nonisolated(unsafe) weak var parent: Node?
        nonisolated(unsafe) var children: [Node] = []
        nonisolated(unsafe) var textRuns: [TextRun] = []

        nonisolated init(tagName: String, elementID: String?, parent: Node?) {
            self.tagName = tagName
            self.elementID = elementID
            self.parent = parent
        }
    }

    nonisolated(unsafe) private var root: Node?
    nonisolated(unsafe) private var body: Node?
    nonisolated(unsafe) private var stack: [Node] = []
    nonisolated(unsafe) private var pendingText = ""
    nonisolated(unsafe) private(set) var isWellFormed = false

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
        isWellFormed = parser.parse()
    }

    nonisolated func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        flushPendingText()
        let tag = elementName.lowercased()
        let node = Node(tagName: tag, elementID: attributes["id"], parent: stack.last)
        stack.last?.children.append(node)

        if root == nil { root = node }
        if body == nil, tag == "body" { body = node }
        stack.append(node)
    }

    nonisolated func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        flushPendingText()
        if !stack.isEmpty { stack.removeLast() }
    }

    nonisolated func parser(_ parser: XMLParser, foundCharacters string: String) {
        pendingText += string
    }

    nonisolated func parser(_ parser: XMLParser, foundComment comment: String) {
        flushPendingText()
    }

    nonisolated func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        flushPendingText()
    }

    nonisolated func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        flushPendingText()
        guard let text = String(data: CDATABlock, encoding: .utf8), !text.isEmpty else { return }
        pendingText = text
        flushPendingText()
    }

    nonisolated private func flushPendingText() {
        defer { pendingText = "" }
        guard !pendingText.isEmpty, let node = stack.last else { return }
        let elementsBefore = node.children.count
        let cfiOffset = node.textRuns.reduce(0) { total, run in
            run.elementsBefore == elementsBefore ? total + run.text.utf16.count : total
        }
        node.textRuns.append(TextRun(elementsBefore: elementsBefore, cfiOffset: cfiOffset, text: pendingText))
    }

    nonisolated func bodyNode() throws -> Node {
        guard let node = body ?? root else {
            throw EpubDocumentError.missingBody
        }
        return node
    }

    nonisolated func elementChild(of parent: Node, at position: Int, idHint: String?) -> Node? {
        if let idHint, !idHint.isEmpty, let matched = parent.children.first(where: { $0.elementID == idHint }) {
            return matched
        }
        guard position >= 1, position <= parent.children.count else { return nil }
        return parent.children[position - 1]
    }

    nonisolated func siblingIndex(of node: Node, in parent: Node) -> Int {
        var index = 0
        for child in parent.children where child.tagName == node.tagName {
            index += 1
            if child === node { return index }
        }
        return 1
    }

    nonisolated func cfiSteps(for node: Node) -> String {
        let stop = body ?? root
        var parts: [String] = []
        var current: Node? = node
        while let n = current, n !== stop, let parent = n.parent {
            let position = (parent.children.firstIndex { $0 === n } ?? 0) + 1
            parts.insert("/\(position * 2)", at: 0)
            current = parent
        }
        return parts.joined()
    }

    nonisolated func element(withID id: String) -> Node? {
        guard let root else { return nil }
        var pending = [root]
        while !pending.isEmpty {
            let node = pending.removeFirst()
            if node.elementID == id { return node }
            pending.insert(contentsOf: node.children, at: 0)
        }
        return nil
    }

    /// The path below the document element, with id assertions on every element step.
    nonisolated func localPath(to point: EpubCFI.Point) -> String? {
        var steps: [String] = []
        var current = point.element
        while current !== root {
            guard let parent = current.parent, let position = parent.children.firstIndex(where: { $0 === current }) else {
                return nil
            }
            steps.insert("/\((position + 1) * 2)\(EpubCFI.assertion(current.elementID))", at: 0)
            current = parent
        }
        if let text = point.text {
            steps.append("/\(text.chunk * 2 + 1):\(text.offset)")
        }
        return steps.isEmpty ? nil : steps.joined()
    }

    /// Foliate's resolution: an id asserted on the last step wins, otherwise the steps are walked by index.
    nonisolated func resolve(_ steps: [EpubCFI.Step]) -> EpubCFI.Point? {
        if let last = steps.last, last.index % 2 == 0, let id = last.assertion, let element = element(withID: id) {
            return EpubCFI.Point(element: element, text: nil)
        }
        return walk(steps)
    }

    nonisolated func walk(_ steps: [EpubCFI.Step]) -> EpubCFI.Point? {
        guard var node = root, !steps.isEmpty else { return nil }
        for (position, step) in steps.enumerated() {
            if step.index % 2 == 0 {
                let index = step.index / 2 - 1
                guard node.children.indices.contains(index) else { return nil }
                node = node.children[index]
            } else {
                let chunk = (step.index - 1) / 2
                guard position == steps.count - 1, chunk <= node.children.count else { return nil }
                return EpubCFI.Point(element: node, text: EpubCFI.TextPosition(chunk: chunk, offset: step.offset ?? 0))
            }
        }
        return EpubCFI.Point(element: node, text: nil)
    }

    nonisolated func textIndex() -> EpubTextIndex {
        EpubTextIndex(body: body ?? root)
    }
}

/// The body's character data in document order, addressable by UTF-16 offset.
nonisolated struct EpubTextIndex {
    struct Segment {
        let node: EpubXHTMLDocument.Node
        let chunk: Int
        let chunkOffset: Int
        let start: Int
        let length: Int
    }

    private(set) var segments: [Segment] = []
    private(set) var units: [UInt16] = []
    private var elementStarts: [ObjectIdentifier: Int] = [:]
    private var elementEnds: [ObjectIdentifier: Int] = [:]

    var length: Int { units.count }

    init(body: EpubXHTMLDocument.Node?) {
        if let body { visit(body) }
    }

    private mutating func visit(_ node: EpubXHTMLDocument.Node) {
        elementStarts[ObjectIdentifier(node)] = units.count
        defer { elementEnds[ObjectIdentifier(node)] = units.count }
        guard node.tagName != "script", node.tagName != "style" else { return }
        var runIndex = 0
        for chunk in 0...node.children.count {
            while runIndex < node.textRuns.count, node.textRuns[runIndex].elementsBefore == chunk {
                let run = node.textRuns[runIndex]
                let text = Array(run.text.utf16)
                segments.append(
                    Segment(node: node, chunk: chunk, chunkOffset: run.cfiOffset, start: units.count, length: text.count)
                )
                units.append(contentsOf: text)
                runIndex += 1
            }
            if chunk < node.children.count { visit(node.children[chunk]) }
        }
    }

    func offset(of point: EpubCFI.Point) -> Int {
        let node = point.element
        guard let text = point.text else { return elementStarts[ObjectIdentifier(node)] ?? 0 }
        if let segment = segments.last(where: {
            $0.node === node && $0.chunk == text.chunk && $0.chunkOffset <= text.offset
        }) {
            return segment.start + min(text.offset - segment.chunkOffset, segment.length)
        }
        if text.chunk < node.children.count {
            return elementStarts[ObjectIdentifier(node.children[text.chunk])] ?? 0
        }
        return elementEnds[ObjectIdentifier(node)] ?? length
    }

    func point(atOffset target: Int) -> EpubCFI.Point? {
        var offset = min(max(target, 0), length)
        while offset < length, Self.isWhitespace(units[offset]) { offset += 1 }
        guard let segment = segments.last(where: { $0.start <= offset && $0.length > 0 }) ?? segments.first else {
            return nil
        }
        let within = min(max(offset - segment.start, 0), segment.length)
        return EpubCFI.Point(
            element: segment.node,
            text: EpubCFI.TextPosition(chunk: segment.chunk, offset: segment.chunkOffset + within)
        )
    }

    func point(atFraction fraction: Double) -> EpubCFI.Point? {
        point(atOffset: Int((min(max(fraction, 0), 1) * Double(length)).rounded(.down)))
    }

    /// Matches ignoring whitespace, since readers join and collapse text runs differently.
    func point(matching quote: String, before: String?) -> EpubCFI.Point? {
        let needle = Array(quote.utf16).filter { !Self.isWhitespace($0) }
        guard needle.count >= 8 else { return nil }
        var haystack: [UInt16] = []
        var rawOffsets: [Int] = []
        for (offset, unit) in units.enumerated() where !Self.isWhitespace(unit) {
            haystack.append(unit)
            rawOffsets.append(offset)
        }
        guard haystack.count >= needle.count else { return nil }
        let context = Array((before ?? "").utf16).filter { !Self.isWhitespace($0) }

        var firstMatch: Int?
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            guard haystack[start..<(start + needle.count)].elementsEqual(needle) else { continue }
            if firstMatch == nil { firstMatch = start }
            if context.isEmpty || haystack[..<start].suffix(context.count).elementsEqual(context) {
                return point(atOffset: rawOffsets[start])
            }
        }
        return firstMatch.flatMap { point(atOffset: rawOffsets[$0]) }
    }

    func quote(at offset: Int) -> (highlight: String, before: String)? {
        var start = min(max(offset, 0), length)
        while start < length, Self.isWhitespace(units[start]) { start += 1 }
        let end = Self.boundary(min(start + 60, length), in: units)
        guard end > start else { return nil }
        let beforeStart = Self.boundary(max(start - 30, 0), in: units)
        return (
            String(decoding: units[start..<end], as: UTF16.self),
            String(decoding: units[beforeStart..<start], as: UTF16.self)
        )
    }

    private static func boundary(_ index: Int, in units: [UInt16]) -> Int {
        index > 0 && index < units.count && UTF16.isTrailSurrogate(units[index]) ? index - 1 : index
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0C || unit == 0xA0
    }
}
