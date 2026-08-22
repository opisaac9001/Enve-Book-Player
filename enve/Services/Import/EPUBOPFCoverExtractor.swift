import Foundation

enum EPUBOPFCoverExtractor {

    struct CoverData {
        let bytes: Data
        let pathExtension: String
    }

    nonisolated static func extractCover(epubURL: URL) async -> CoverData? {
        await Task.detached(priority: .utility) {
            try? await extractCoverPayload(epubURL: epubURL)
        }.value
    }

    private nonisolated static func extractCoverPayload(epubURL: URL) async throws -> CoverData? {
        try ImportLimits.validateArchiveFile(epubURL)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-cover-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await ImportLimits.extractArchive(epubURL, to: tempDir)

        let containerURL = tempDir.appendingPathComponent("META-INF/container.xml")
        try ImportLimits.validateWholeFileRead(containerURL)
        let containerData = try Data(contentsOf: containerURL)
        guard let opfRelativePath = parseOPFPath(containerData: containerData) else {
            return nil
        }

        let opfURL = tempDir.appendingPathComponent(opfRelativePath)
        _ = try ImportLimits.validateArchiveEntryPath(opfRelativePath, destinationRoot: tempDir)
        try ImportLimits.validateWholeFileRead(opfURL)
        let opfData = try Data(contentsOf: opfURL)
        let opfBaseDir = (opfRelativePath as NSString).deletingLastPathComponent

        guard let parsedOPF = parseOPF(opfData: opfData) else {
            return nil
        }

        guard let coverHref = pickCoverHref(opf: parsedOPF) else {
            return nil
        }

        let resolvedPath =
            opfBaseDir.isEmpty
            ? coverHref
            : "\(opfBaseDir)/\(coverHref)"
        let coverFileURL = tempDir.appendingPathComponent(resolvedPath)
        _ = try ImportLimits.validateArchiveEntryPath(resolvedPath, destinationRoot: tempDir)

        try ImportLimits.validateWholeFileRead(coverFileURL)
        let bytes = try Data(contentsOf: coverFileURL)
        let ext = (coverHref as NSString).pathExtension.lowercased()
        return CoverData(bytes: bytes, pathExtension: ext.isEmpty ? "jpg" : ext)
    }

    fileprivate struct OPFManifestItem {
        let id: String
        let href: String
        let mediaType: String
        let properties: String
    }

    fileprivate struct ParsedOPF {
        let manifestItems: [OPFManifestItem]

        let coverMetaContentId: String?
    }

    private nonisolated static func parseOPFPath(containerData: Data) -> String? {
        let parser = ContainerParser()
        let xml = XMLParser(data: containerData)
        xml.delegate = parser
        xml.parse()
        return parser.opfPath
    }

    private nonisolated static func parseOPF(opfData: Data) -> ParsedOPF? {
        let parser = OPFParser()
        let xml = XMLParser(data: opfData)
        xml.delegate = parser
        xml.parse()
        if parser.manifestItems.isEmpty { return nil }
        return ParsedOPF(
            manifestItems: parser.manifestItems,
            coverMetaContentId: parser.coverMetaContentId
        )
    }

    private nonisolated static func pickCoverHref(opf: ParsedOPF) -> String? {
        let items = opf.manifestItems
        let isImage = { (item: OPFManifestItem) in item.mediaType.lowercased().hasPrefix("image/") }

        if let match = items.first(where: { $0.properties.contains("cover-image") && isImage($0) }) {
            return match.href
        }

        if let coverId = opf.coverMetaContentId,
            let match = items.first(where: { $0.id == coverId && isImage($0) })
        {
            return match.href
        }

        if let match = items.first(where: {
            let lower = $0.id.lowercased()
            return (lower == "cover" || lower == "cover-image") && isImage($0)
        }) {
            return match.href
        }

        if let match = items.first(where: { isImage($0) && $0.href.lowercased().contains("cover") }) {
            return match.href
        }

        if let match = items.first(where: { $0.properties.contains("cover-image") }) {
            return match.href
        }

        return nil
    }
}

private final class ContainerParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    nonisolated(unsafe) var opfPath: String?

    nonisolated override init() { super.init() }

    nonisolated func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard opfPath == nil, elementName.lowercased() == "rootfile" else { return }
        if let fullPath = attributeDict["full-path"] ?? attributeDict["FULL-PATH"] {
            opfPath = fullPath
        }
    }
}

private final class OPFParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    nonisolated(unsafe) var manifestItems: [EPUBOPFCoverExtractor.OPFManifestItem] = []
    nonisolated(unsafe) var coverMetaContentId: String?

    private nonisolated(unsafe) var inManifest = false

    nonisolated override init() { super.init() }

    nonisolated func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = localName(elementName)

        switch local {
        case "manifest":
            inManifest = true

        case "item" where inManifest:
            let id = attributeDict["id"] ?? ""
            let href = attributeDict["href"] ?? ""
            let mediaType = attributeDict["media-type"] ?? ""
            let properties = attributeDict["properties"] ?? ""
            guard !href.isEmpty else { return }
            manifestItems.append(
                EPUBOPFCoverExtractor.OPFManifestItem(
                    id: id,
                    href: href,
                    mediaType: mediaType,
                    properties: properties
                )
            )

        case "meta":

            if coverMetaContentId == nil,
                attributeDict["name"]?.lowercased() == "cover",
                let content = attributeDict["content"],
                !content.isEmpty
            {
                coverMetaContentId = content
            }

        default:
            break
        }
    }

    nonisolated func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if localName(elementName) == "manifest" {
            inManifest = false
        }
    }

    private nonisolated func localName(_ elementName: String) -> String {
        if let colonIdx = elementName.firstIndex(of: ":") {
            return String(elementName[elementName.index(after: colonIdx)...]).lowercased()
        }
        return elementName.lowercased()
    }
}
