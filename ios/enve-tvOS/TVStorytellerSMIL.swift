import Foundation

nonisolated struct TVAudioOverlayClip: Sendable, Hashable, Identifiable {
    let fragmentId: String
    let textHref: String
    let audioSrc: String
    let clipBegin: TimeInterval
    let clipEnd: TimeInterval
    let skippableRole: String?

    var duration: TimeInterval { clipEnd - clipBegin }
    var id: String { TVStorytellerPaths.normalizeHref(textHref) + "#" + fragmentId }
}

nonisolated struct TVStorytellerTimeline {
    struct AudioGroup {
        let audioSrc: String
        let clipRange: Range<Int>
    }

    let clips: [TVAudioOverlayClip]
    let starts: [TimeInterval]
    let duration: TimeInterval
    let groups: [AudioGroup]
    let groupIndices: [Int]

    init(clips: [TVAudioOverlayClip]) {
        self.clips = clips
        var starts: [TimeInterval] = []
        var duration: TimeInterval = 0
        var groups: [AudioGroup] = []
        var groupIndices: [Int] = []
        var groupStart = 0
        for (index, clip) in clips.enumerated() {
            starts.append(duration)
            duration += clip.duration
            if index > 0 {
                let previous = clips[index - 1]
                if clip.audioSrc != previous.audioSrc || clip.clipBegin < previous.clipEnd - 0.02 {
                    groups.append(AudioGroup(audioSrc: previous.audioSrc, clipRange: groupStart..<index))
                    groupStart = index
                }
            }
            groupIndices.append(groups.count)
        }
        if let last = clips.last {
            groups.append(AudioGroup(audioSrc: last.audioSrc, clipRange: groupStart..<clips.count))
        }
        self.starts = starts
        self.duration = duration
        self.groups = groups
        self.groupIndices = groupIndices
    }

    func clipIndex(at elapsedTime: TimeInterval) -> Int? {
        guard !clips.isEmpty else { return nil }
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if starts[middle] <= elapsedTime { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }

    func clipIndex(atAudioTime time: TimeInterval, inGroup groupIndex: Int) -> Int {
        let range = groups[groupIndex].clipRange
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper {
            let middle = (lower + upper) / 2
            // Audio seeks round to a sample; keep a paused seek on its intended passage.
            if clips[middle].clipBegin <= time + 0.001 { lower = middle + 1 } else { upper = middle }
        }
        return max(range.lowerBound, lower - 1)
    }

    func elapsedTime(atAudioTime time: TimeInterval, clipIndex: Int) -> TimeInterval {
        let clip = clips[clipIndex]
        return starts[clipIndex] + min(max(time - clip.clipBegin, 0), clip.duration)
    }
}

nonisolated final class TVSmilXMLParser: NSObject, XMLParserDelegate {
    enum ParseError: Error { case malformedXML }
    private let data: Data
    private let baseHref: String
    private(set) var clips: [TVAudioOverlayClip] = []

    private var currentTextHref: String?
    private var currentFragmentId: String?
    private var currentAudioSrc: String?
    private var currentClipBegin: TimeInterval?
    private var currentClipEnd: TimeInterval?
    private var skippableRoleStack: [String?] = []

    private static let skippableRoles: Set<String> = [
        "footnote", "endnote", "pagebreak", "note",
        "rearnote", "sidebar", "marginalia", "annotation",
    ]
    private var currentSkippableRole: String? {
        skippableRoleStack.last(where: { $0 != nil }) ?? nil
    }

    init(data: Data, baseHref: String) {
        self.data = data
        self.baseHref = baseHref
    }

    func parseAndReturn() throws -> [TVAudioOverlayClip] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        guard parser.parse() else { throw ParseError.malformedXML }
        return clips
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        let localName = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
        switch localName {
        case "seq":
            let epubType = attributes["epub:type"] ?? attributes["type"] ?? ""
            let skippable = epubType.components(separatedBy: .whitespacesAndNewlines)
                .first(where: { TVSmilXMLParser.skippableRoles.contains($0) })
            skippableRoleStack.append(skippable)

        case "par":
            currentTextHref = nil
            currentFragmentId = nil
            currentAudioSrc = nil
            currentClipBegin = nil
            currentClipEnd = nil

        case "text":
            if let src = attributes["src"] {
                let parts = src.components(separatedBy: "#")
                let rawHref = parts.first ?? src
                currentTextHref = resolveHref(rawHref)
                if parts.count > 1 { currentFragmentId = parts[1].removingPercentEncoding ?? parts[1] }
            }

        case "audio":
            currentClipBegin = 0
            if let src = attributes["src"] {
                currentAudioSrc = resolveHref(src)
            }
            if let begin = attributes["clipBegin"] ?? attributes["clip-begin"] {
                currentClipBegin = Self.parseSmilClock(begin)
            }
            if let end = attributes["clipEnd"] ?? attributes["clip-end"] {
                currentClipEnd = Self.parseSmilClock(end)
            }

        default: break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let localName = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
        switch localName {
        case "seq":
            if !skippableRoleStack.isEmpty { skippableRoleStack.removeLast() }
        case "par":
            if let frag = currentFragmentId,
                let textHref = currentTextHref,
                let audioSrc = currentAudioSrc,
                let begin = currentClipBegin,
                let end = currentClipEnd, begin.isFinite, end.isFinite, begin >= 0, end > begin
            {
                clips.append(
                    TVAudioOverlayClip(
                        fragmentId: frag,
                        textHref: textHref,
                        audioSrc: audioSrc,
                        clipBegin: begin,
                        clipEnd: end,
                        skippableRole: currentSkippableRole
                    )
                )
            }
        default: break
        }
    }

    private func resolveHref(_ href: String) -> String {
        TVStorytellerPaths.resolve(href, relativeTo: baseHref)
    }

    static func parseSmilClock(_ value: String) -> TimeInterval? {
        var s = value.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("npt=") { s = String(s.dropFirst(4)) }
        if s.hasSuffix("ms"), let ms = Double(s.dropLast(2)) { return ms / 1000.0 }
        if s.hasSuffix("s"), let sec = Double(s.dropLast(1)) { return sec }
        if s.hasSuffix("min"), let min = Double(s.dropLast(3)) { return min * 60.0 }
        if s.hasSuffix("h"), let h = Double(s.dropLast(1)) { return h * 3600.0 }
        let parts = s.components(separatedBy: ":")
        switch parts.count {
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + sec
        case 2:
            guard let m = Double(parts[0]), let sec = Double(parts[1]) else { return nil }
            return m * 60 + sec
        default:
            return Double(s)
        }
    }
}

nonisolated struct TVStorytellerTextSegment: Hashable, Identifiable, Sendable {
    let id: Int
    let fragmentId: String?
    let text: String
}

nonisolated struct TVStorytellerChapter: Hashable, Identifiable, Sendable {
    let id: Int
    let title: String
    let href: String
    let segments: [TVStorytellerTextSegment]
}

nonisolated final class TVStorytellerPackageParser: NSObject, XMLParserDelegate {
    struct Item {
        let href: String
        let overlayID: String?
    }

    private(set) var rootfile: String?
    private(set) var items: [String: Item] = [:]
    private(set) var spine: [String] = []

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch elementName.components(separatedBy: ":").last {
        case "rootfile":
            if rootfile == nil { rootfile = attributes["full-path"] }
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                items[id] = Item(href: href, overlayID: attributes["media-overlay"])
            }
        case "itemref":
            if let id = attributes["idref"] { spine.append(id) }
        default: break
        }
    }
}

nonisolated final class TVStorytellerTextParser: NSObject, XMLParserDelegate {
    private let fragments: Set<String>
    private let counterStart: Int
    private var depth = 0
    private var bodyDepth: Int?
    private var skippedDepth: Int?
    private var anchors: [(depth: Int, id: String)] = []
    private var buffer = ""
    private var titleCapture: (depth: Int, rank: Int, text: String)?
    private var titleRank = Int.max
    private(set) var title: String?
    private(set) var segments: [TVStorytellerTextSegment] = []

    private static let blockElements: Set<String> = [
        "p", "div", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6",
        "li", "blockquote", "figcaption", "dt", "dd", "br", "tr",
    ]

    init(fragments: Set<String>, counterStart: Int) {
        self.fragments = fragments
        self.counterStart = counterStart
    }

    func parse(_ html: String) -> Bool {
        var xml = html
        let entities: [String: String] = [
            "nbsp": "160", "mdash": "8212", "ndash": "8211", "hellip": "8230",
            "lsquo": "8216", "rsquo": "8217", "ldquo": "8220", "rdquo": "8221",
            "copy": "169", "reg": "174", "trade": "8482", "bull": "8226",
            "ensp": "8194", "emsp": "8195", "thinsp": "8201", "shy": "173",
        ]
        for (name, number) in entities {
            xml = xml.replacingOccurrences(of: "&" + name + ";", with: "&#" + number + ";")
        }
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = self
        let success = parser.parse()
        flush()
        return success
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        depth += 1
        let name = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
        if name == "body" { bodyDepth = depth }
        guard skippedDepth == nil else { return }
        if ["script", "style", "svg"].contains(name) || attributes["aria-hidden"] == "true" || attributes["hidden"] != nil {
            skippedDepth = depth
            return
        }
        let rank = ["h1": 0, "h2": 1, "title": 2][name]
        if let rank, rank < titleRank, titleCapture == nil {
            titleCapture = (depth, rank, "")
        }
        guard bodyDepth != nil else { return }
        if Self.blockElements.contains(name) {
            if anchors.isEmpty { flush() } else { buffer.append(" ") }
        }
        if let id = attributes["id"] ?? attributes["xml:id"], fragments.contains(id) {
            flush()
            anchors.append((depth, id))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skippedDepth == nil else { return }
        if titleCapture != nil { titleCapture?.text.append(string) }
        if bodyDepth != nil { buffer.append(string) }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        defer { depth -= 1 }
        if let skippedDepth {
            if skippedDepth == depth { self.skippedDepth = nil }
            return
        }
        if let capture = titleCapture, capture.depth == depth {
            let text = Self.normalizedText(capture.text)
            if !text.isEmpty { title = text; titleRank = capture.rank }
            titleCapture = nil
        }
        let name = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
        if anchors.last?.depth == depth {
            flush()
            anchors.removeLast()
        }
        if Self.blockElements.contains(name) {
            if anchors.isEmpty { flush() } else { buffer.append(" ") }
        }
        if bodyDepth == depth { flush(); bodyDepth = nil }
    }

    private func flush() {
        let text = Self.normalizedText(buffer)
        buffer = ""
        guard !text.isEmpty else { return }
        segments.append(TVStorytellerTextSegment(
            id: counterStart + segments.count,
            fragmentId: anchors.last?.id,
            text: text
        ))
    }

    private static func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

nonisolated enum TVStorytellerPaths {
    static func resolvePathDots(_ path: String) -> String {
        var resolved: [String] = []
        for component in path.components(separatedBy: "/") {
            switch component {
            case "..":
                if !resolved.isEmpty { resolved.removeLast() }
            case ".", "":
                break
            default:
                resolved.append(component)
            }
        }
        return resolved.joined(separator: "/")
    }

    static func normalizeHref(_ href: String) -> String {
        resolvePathDots(href.removingPercentEncoding ?? href)
    }

    static func resolve(_ href: String, relativeTo documentHref: String) -> String {
        if href.hasPrefix("/") { return normalizeHref(href) }
        let directory = (documentHref as NSString).deletingLastPathComponent
        return normalizeHref(directory + "/" + href)
    }
}
