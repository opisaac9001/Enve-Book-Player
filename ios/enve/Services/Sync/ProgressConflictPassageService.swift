#if !os(tvOS)
import Foundation
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer

struct ProgressConflictPassage: Equatable {
    enum Accuracy: Equatable {
        case exact
        case approximate

        var label: String {
            switch self {
            case .exact: "Exact spot"
            case .approximate: "Approximate spot"
            }
        }
    }

    let text: String
    let sectionTitle: String?
    let accuracy: Accuracy
}

@MainActor
enum ProgressConflictPassageService {
    private static let snippetLength = 240
    private static let minimumAnchorLength = 8
    private static let minimumSectionTextLength = 20

    static func passages(
        for book: Book,
        localLocator: String?,
        localProgress: Double,
        remoteLocator: String?,
        remoteProgress: Double
    ) async -> (local: ProgressConflictPassage?, remote: ProgressConflictPassage?) {
        guard let publication = await openPublication(for: book) else { return (nil, nil) }
        let readingOrder = publication.readingOrder
        guard !readingOrder.isEmpty else { return (nil, nil) }

        let localMatch = sectionIndex(forLocator: localLocator, in: readingOrder)
        let remoteMatch = sectionIndex(forLocator: remoteLocator, in: readingOrder)
        var positions: [[ReadiumShared.Locator]] = []
        if localMatch == nil || remoteMatch == nil {
            positions = (try? await publication.positionsByReadingOrder().get()) ?? []
        }

        let localPlacement = placement(
            matchedIndex: localMatch,
            locator: localLocator,
            progress: localProgress,
            positions: positions,
            sectionCount: readingOrder.count
        )
        let remotePlacement = placement(
            matchedIndex: remoteMatch,
            locator: remoteLocator,
            progress: remoteProgress,
            positions: positions,
            sectionCount: readingOrder.count
        )

        return (
            await passage(
                in: publication,
                link: readingOrder[localPlacement.index],
                locator: localLocator,
                fallbackFraction: localPlacement.fraction
            ),
            await passage(
                in: publication,
                link: readingOrder[remotePlacement.index],
                locator: remoteLocator,
                fallbackFraction: remotePlacement.fraction
            )
        )
    }

    private static func sectionIndex(
        forLocator locator: String?,
        in readingOrder: [ReadiumShared.Link]
    ) -> Int? {
        guard let target = href(from: locator) else { return nil }
        let normalized = EpubLocationBridge.normalizedHref(target)
        return readingOrder.firstIndex { EpubLocationBridge.normalizedHref($0.href) == normalized }
    }

    private static func placement(
        matchedIndex: Int?,
        locator: String?,
        progress: Double,
        positions: [[ReadiumShared.Locator]],
        sectionCount: Int
    ) -> (index: Int, fraction: Double) {
        if let matchedIndex {
            return (matchedIndex, resourceProgression(from: locator) ?? 0)
        }
        return place(progress: progress, positions: positions, sectionCount: sectionCount)
    }

    private static func openPublication(for book: Book) async -> Publication? {
        guard book.mediaType == .ebook,
            let fileURL = UnifiedDownloadService.shared.existingReaderAsset(for: book)
        else { return nil }

        let fileExtension = fileURL.pathExtension.lowercased()
        guard fileExtension.isEmpty || fileExtension == EbookFormat.epub.rawValue,
            let readiumURL = FileURL(url: fileURL)
        else { return nil }

        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let opener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )
        guard let asset = try? await assetRetriever.retrieve(url: readiumURL).get() else { return nil }
        return try? await opener.open(asset: asset, allowUserInteraction: false).get()
    }

    private static func passage(
        in publication: Publication,
        link: ReadiumShared.Link,
        locator: String?,
        fallbackFraction: Double
    ) async -> ProgressConflictPassage? {
        guard let resource = publication.get(link) else { return nil }
        nonisolated(unsafe) let unsafeResource = resource
        guard let data = try? await unsafeResource.read().get() else { return nil }
        let html =
            String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let text = plainText(fromHTML: html)
        guard text.count > minimumSectionTextLength else { return nil }

        let title = await sectionTitle(for: link, publication: publication)

        if let highlight = highlight(from: locator),
            highlight.count >= minimumAnchorLength,
            let range = text.range(of: highlight),
            text[range.upperBound...].range(of: highlight) == nil
        {
            return ProgressConflictPassage(
                text: snippet(text, from: range.lowerBound),
                sectionTitle: title,
                accuracy: .exact
            )
        }

        if let fragment = fragmentIdentifier(from: locator),
            let anchored = textFollowingElement(id: fragment, inHTML: html),
            anchored.count > minimumSectionTextLength
        {
            return ProgressConflictPassage(
                text: snippet(anchored, from: anchored.startIndex),
                sectionTitle: title,
                accuracy: .exact
            )
        }

        let offset = min(max(Int(Double(text.count) * fallbackFraction), 0), max(text.count - 1, 0))
        return ProgressConflictPassage(
            text: snippet(text, from: text.index(text.startIndex, offsetBy: offset)),
            sectionTitle: title,
            accuracy: .approximate
        )
    }

    private static func place(
        progress: Double,
        positions: [[ReadiumShared.Locator]],
        sectionCount: Int
    ) -> (index: Int, fraction: Double) {
        let clamped = min(max(progress, 0), 1)
        let starts = positions.prefix(sectionCount).map { $0.first?.locations.totalProgression ?? 0 }
        guard starts.count > 1 else {
            let index = min(Int(clamped * Double(sectionCount)), max(sectionCount - 1, 0))
            return (index, min(max(clamped * Double(sectionCount) - Double(index), 0), 1))
        }

        var index = 0
        for (candidate, start) in starts.enumerated() where clamped >= start {
            index = candidate
        }
        let start = starts[index]
        let end = index + 1 < starts.count ? starts[index + 1] : 1
        return (index, min(max((clamped - start) / max(end - start, 0.0001), 0), 1))
    }

    private static func sectionTitle(
        for link: ReadiumShared.Link,
        publication: Publication
    ) async -> String? {
        let target = EpubLocationBridge.normalizedHref(link.href)
        let toc = flattened((try? await publication.tableOfContents().get()) ?? [])
        let match = toc.first { entry in
            let href = EpubLocationBridge.normalizedHref(entry.href)
            return href == target || href.hasSuffix(target) || target.hasSuffix(href)
        }
        let title = (match?.title ?? link.title)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }

    private static func flattened(_ links: [ReadiumShared.Link]) -> [ReadiumShared.Link] {
        links.flatMap { [$0] + flattened($0.children) }
    }

    private static func snippet(_ text: String, from start: String.Index) -> String {
        var begin = start
        if begin > text.startIndex, let space = text[text.startIndex..<begin].lastIndex(of: " ") {
            begin = text.index(after: space)
        }
        let end = text.index(begin, offsetBy: snippetLength, limitedBy: text.endIndex) ?? text.endIndex
        var slice = String(text[begin..<end])
        if end < text.endIndex, let lastSpace = slice.lastIndex(of: " ") {
            slice = String(slice[slice.startIndex..<lastSpace])
        }
        slice = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slice.isEmpty else { return "" }
        return (begin > text.startIndex ? "…" : "") + slice + (end < text.endIndex ? "…" : "")
    }

    private static func textFollowingElement(id: String, inHTML html: String) -> String? {
        let pattern = "id\\s*=\\s*[\"']\(NSRegularExpression.escapedPattern(for: id))[\"']"
        guard let attribute = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
            let tagStart = html[html.startIndex..<attribute.lowerBound].lastIndex(of: "<")
        else { return nil }
        return plainText(fromHTML: String(html[tagStart...]))
    }

    private static func locatorJSON(_ locator: String?) -> [String: Any]? {
        guard let locator, let data = locator.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func href(from locator: String?) -> String? {
        guard let href = locatorJSON(locator)?["href"] as? String, !href.isEmpty else { return nil }
        return href
    }

    private static func highlight(from locator: String?) -> String? {
        guard let text = locatorJSON(locator)?["text"] as? [String: Any],
            let highlight = (text["highlight"] as? String)?.components(separatedBy: .whitespacesAndNewlines).filter({ !$0.isEmpty }).joined(separator: " "),
            !highlight.isEmpty
        else { return nil }
        return highlight
    }

    private static func fragmentIdentifier(from locator: String?) -> String? {
        var candidates: [String] = []
        if let href = href(from: locator),
            let fragment = href.split(separator: "#", maxSplits: 1).dropFirst().first
        {
            candidates.append(String(fragment))
        }
        if let locations = locatorJSON(locator)?["locations"] as? [String: Any],
            let fragments = locations["fragments"] as? [Any]
        {
            candidates.append(contentsOf: fragments.compactMap { $0 as? String })
        }
        return candidates.first {
            !$0.isEmpty && !$0.hasPrefix("epubcfi(") && !$0.hasPrefix("/") && !$0.contains("=")
        }
    }

    private static func resourceProgression(from locator: String?) -> Double? {
        guard let locations = locatorJSON(locator)?["locations"] as? [String: Any],
            let progression = locations["progression"] as? Double
        else { return nil }
        return min(max(progression, 0), 1)
    }

    private static func plainText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        for (entity, replacement) in [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        ] {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

#endif
