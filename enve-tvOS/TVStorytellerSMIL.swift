import Foundation

struct TVAudioOverlayClip: Sendable, Hashable {
    let fragmentId: String
    let textHref: String
    let audioSrc: String
    let clipBegin: TimeInterval
    let clipEnd: TimeInterval
    let skippableRole: String?

    var duration: TimeInterval { clipEnd - clipBegin }
}

nonisolated final class TVSmilXMLParser: NSObject, XMLParserDelegate {
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

    func parseAndReturn() -> [TVAudioOverlayClip] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.parse()
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
                if parts.count > 1 { currentFragmentId = parts[1] }
            }

        case "audio":
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
                let end = currentClipEnd, end > begin
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
        if href.hasPrefix("/") { return TVStorytellerPaths.resolvePathDots(href) }
        let baseDir = (baseHref as NSString).deletingLastPathComponent
        if baseDir.isEmpty || baseDir == "." {
            return TVStorytellerPaths.resolvePathDots(href)
        }
        return TVStorytellerPaths.resolvePathDots(baseDir + "/" + href)
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
        href.hasPrefix("/") ? String(href.dropFirst()) : href
    }

    static func localAudioFilename(for src: String) -> String {
        resolvePathDots(src).replacingOccurrences(of: "/", with: "_")
    }
}
