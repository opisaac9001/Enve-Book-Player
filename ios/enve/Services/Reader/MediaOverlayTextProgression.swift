#if os(iOS)
import Foundation
@preconcurrency import ReadiumShared

// Places narrated clips on Readium's position-based totalProgression scale so narration and paging agree.
enum MediaOverlayTextProgression {
    struct ChapterText: Sendable {
        let href: String
        let start: Double
        let end: Double
        let xhtml: String?
    }

    struct FragmentOffsets: Sendable {
        let offsetsById: [String: Int]
        let textLength: Int
    }

    static func clipProgressions(for clips: [AudioOverlayClip], publication: Publication) async -> [Double] {
        guard !clips.isEmpty,
            let positions = try? await publication.positionsByReadingOrder().get(),
            positions.count == publication.readingOrder.count
        else { return [] }

        let narratedHrefs = Set(clips.map(\.textHref))
        var chapters: [ChapterText] = []
        for (index, link) in publication.readingOrder.enumerated() {
            guard let start = positions[index].first?.locations.totalProgression else { continue }
            let end = positions.indices.contains(index + 1)
                ? positions[index + 1].first?.locations.totalProgression ?? 1.0
                : 1.0
            var xhtml: String?
            if narratedHrefs.contains(where: { MediaOverlayTimeline.hrefMatches($0, link.href) }),
                let resource = publication.get(link)
            {
                nonisolated(unsafe) let unsafeResource = resource
                xhtml = try? await unsafeResource.read().asString().get()
            }
            chapters.append(ChapterText(href: link.href, start: start, end: end, xhtml: xhtml))
        }

        return await Task.detached(priority: .utility) {
            clipProgressions(for: clips, chapters: chapters)
        }.value
    }

    nonisolated static func clipProgressions(for clips: [AudioOverlayClip], chapters: [ChapterText]) -> [Double] {
        var chapterIndexByHref: [String: Int?] = [:]
        var offsetsByChapter: [Int: FragmentOffsets] = [:]
        var clipIndicesByChapter: [Int: [Int]] = [:]
        var chapterIndexByClip: [Int?] = []
        chapterIndexByClip.reserveCapacity(clips.count)

        for (clipIndex, clip) in clips.enumerated() {
            let chapterIndex: Int?
            if let cached = chapterIndexByHref[clip.textHref] {
                chapterIndex = cached
            } else {
                chapterIndex = chapters.firstIndex { MediaOverlayTimeline.hrefMatches($0.href, clip.textHref) }
                chapterIndexByHref[clip.textHref] = chapterIndex
            }
            chapterIndexByClip.append(chapterIndex)
            if let chapterIndex {
                clipIndicesByChapter[chapterIndex, default: []].append(clipIndex)
            }
        }

        var progressions: [Double] = []
        progressions.reserveCapacity(clips.count)
        for (clipIndex, clip) in clips.enumerated() {
            guard let chapterIndex = chapterIndexByClip[clipIndex] else {
                progressions.append(progressions.last ?? 0)
                continue
            }
            let chapter = chapters[chapterIndex]
            if offsetsByChapter[chapterIndex] == nil, let xhtml = chapter.xhtml {
                offsetsByChapter[chapterIndex] = fragmentOffsets(in: xhtml)
            }

            let withinChapter: Double
            if let offsets = offsetsByChapter[chapterIndex],
                offsets.textLength > 0,
                let offset = offsets.offsetsById[clip.fragmentId]
            {
                withinChapter = Double(offset) / Double(offsets.textLength)
            } else {
                let siblings = clipIndicesByChapter[chapterIndex] ?? [clipIndex]
                let position = siblings.firstIndex(of: clipIndex) ?? 0
                withinChapter = Double(position) / Double(max(siblings.count, 1))
            }
            let progression = chapter.start + min(max(withinChapter, 0), 1) * (chapter.end - chapter.start)
            progressions.append(min(max(progression, 0), 1))
        }
        return progressions
    }

    // Offsets count rendered characters (Unicode scalars, entities as one, whitespace runs collapsed) in <body>.
    nonisolated static func fragmentOffsets(in xhtml: String) -> FragmentOffsets {
        let bytes = Array(xhtml.utf8)
        var offsets: [String: Int] = [:]
        var length = 0
        var pendingSpace = false
        var index = bodyStart(in: bytes) ?? 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "<") {
                if hasPrefix(bytes, at: index, "<!--") {
                    index = end(of: "-->", in: bytes, from: index + 4)
                    continue
                }
                var tagEnd = index + 1
                while tagEnd < bytes.count, bytes[tagEnd] != UInt8(ascii: ">") { tagEnd += 1 }
                let tag = bytes[(index + 1)..<min(tagEnd, bytes.count)]
                index = tagEnd + 1
                guard let first = tag.first, first != UInt8(ascii: "/"), first != UInt8(ascii: "!"),
                    first != UInt8(ascii: "?")
                else { continue }

                if let id = idAttribute(in: tag), offsets[id] == nil {
                    offsets[id] = length + (pendingSpace ? 1 : 0)
                }
                let name = tagName(tag)
                if name == "script" || name == "style", tag.last != UInt8(ascii: "/") {
                    index = end(of: "</\(name)", in: bytes, from: index)
                }
                continue
            }

            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                pendingSpace = length > 0
                index += 1
                continue
            }
            if pendingSpace {
                length += 1
                pendingSpace = false
            }
            if byte == UInt8(ascii: "&") {
                var entityEnd = index + 1
                while entityEnd < bytes.count, entityEnd - index <= 10, bytes[entityEnd] != UInt8(ascii: ";") {
                    entityEnd += 1
                }
                length += 1
                index = entityEnd < bytes.count && bytes[entityEnd] == UInt8(ascii: ";") ? entityEnd + 1 : index + 1
                continue
            }
            if byte & 0xC0 != 0x80 {
                length += 1
            }
            index += 1
        }
        return FragmentOffsets(offsetsById: offsets, textLength: length)
    }

    private nonisolated static func bodyStart(in bytes: [UInt8]) -> Int? {
        var index = 0
        while index + 5 <= bytes.count {
            if bytes[index] == UInt8(ascii: "<"),
                lowercased(bytes[index + 1...index + 4]) == "body",
                index + 5 == bytes.count || !isNameByte(bytes[index + 5])
            {
                return index
            }
            index += 1
        }
        return nil
    }

    private nonisolated static func tagName(_ tag: ArraySlice<UInt8>) -> String {
        lowercased(tag.prefix(while: isNameByte))
    }

    private nonisolated static func idAttribute(in tag: ArraySlice<UInt8>) -> String? {
        var index = tag.startIndex
        while index + 2 < tag.endIndex {
            defer { index += 1 }
            guard isSpace(tag[index]),
                tag[index + 1] | 0x20 == UInt8(ascii: "i"),
                tag[index + 2] | 0x20 == UInt8(ascii: "d")
            else { continue }
            var cursor = index + 3
            while cursor < tag.endIndex, isSpace(tag[cursor]) { cursor += 1 }
            guard cursor < tag.endIndex, tag[cursor] == UInt8(ascii: "=") else { continue }
            cursor += 1
            while cursor < tag.endIndex, isSpace(tag[cursor]) { cursor += 1 }
            guard cursor < tag.endIndex, tag[cursor] == UInt8(ascii: "\"") || tag[cursor] == UInt8(ascii: "'") else {
                continue
            }
            let quote = tag[cursor]
            let valueStart = cursor + 1
            guard let valueEnd = tag[valueStart...].firstIndex(of: quote) else { return nil }
            return String(decoding: tag[valueStart..<valueEnd], as: UTF8.self)
        }
        return nil
    }

    private nonisolated static func end(of marker: String, in bytes: [UInt8], from start: Int) -> Int {
        let needle = Array(marker.utf8)
        var index = start
        while index + needle.count <= bytes.count {
            if hasPrefix(bytes, at: index, needle, caseInsensitive: true) {
                return marker.hasPrefix("</")
                    ? (bytes[index...].firstIndex(of: UInt8(ascii: ">")).map { $0 + 1 } ?? bytes.count)
                    : index + needle.count
            }
            index += 1
        }
        return bytes.count
    }

    private nonisolated static func hasPrefix(_ bytes: [UInt8], at index: Int, _ prefix: String) -> Bool {
        hasPrefix(bytes, at: index, Array(prefix.utf8), caseInsensitive: false)
    }

    private nonisolated static func hasPrefix(
        _ bytes: [UInt8],
        at index: Int,
        _ prefix: [UInt8],
        caseInsensitive: Bool
    ) -> Bool {
        guard index + prefix.count <= bytes.count else { return false }
        for offset in prefix.indices {
            let lhs = bytes[index + offset]
            let rhs = prefix[offset]
            if lhs == rhs { continue }
            guard caseInsensitive, isLetter(lhs), lhs | 0x20 == rhs | 0x20 else { return false }
        }
        return true
    }

    private nonisolated static func lowercased(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.map { isLetter($0) ? $0 | 0x20 : $0 }, as: UTF8.self)
    }

    private nonisolated static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte | 0x20)
    }

    private nonisolated static func isNameByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-")
            || byte == UInt8(ascii: ":")
    }

    private nonisolated static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
#endif
