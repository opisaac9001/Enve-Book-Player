import Foundation
import ReadiumZIPFoundation

struct ReadAloudLyricLine: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let clipIndex: Int
    let start: TimeInterval
    let end: TimeInterval
}

enum ReadAloudLyricsBuilder {

    static func lines(
        for clips: [AudioOverlayClip],
        inHTML html: String,
        matching textHref: String
    ) -> [ReadAloudLyricLine] {
        let texts = elementTexts(inHTML: html)
        let target = normalized(textHref)
        var lines: [ReadAloudLyricLine] = []
        for (index, clip) in clips.enumerated() {
            guard normalized(clip.textHref) == target else { continue }
            guard let text = texts[clip.fragmentId]?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else { continue }
            lines.append(
                ReadAloudLyricLine(
                    id: clip.fragmentId,
                    text: text,
                    clipIndex: index,
                    start: clip.clipBegin,
                    end: clip.clipEnd
                )
            )
        }
        return lines
    }

    // EPUB content is well-formed XHTML, so a tag stack is enough to recover the text of every
    // element carrying an id, including sentences that wrap styling spans of their own.
    static func elementTexts(inHTML html: String) -> [String: String] {
        var result: [String: String] = [:]
        var stack: [(id: String?, text: String)] = []
        let scalars = Array(html)
        var index = 0

        func appendText(_ piece: String) {
            guard !stack.isEmpty else { return }
            for depth in stack.indices {
                stack[depth].text.append(piece)
            }
        }

        while index < scalars.count {
            let character = scalars[index]
            if character != "<" {
                appendText(String(character))
                index += 1
                continue
            }

            guard let close = nextIndex(of: ">", in: scalars, from: index) else { break }
            let raw = String(scalars[(index + 1)..<close])
            index = close + 1

            if raw.hasPrefix("!") || raw.hasPrefix("?") { continue }

            if raw.hasPrefix("/") {
                if let finished = stack.popLast(), let id = finished.id {
                    result[id] = collapseWhitespace(decodeEntities(finished.text))
                }
                continue
            }

            let selfClosing = raw.hasSuffix("/")
            let identifier = attributeValue("id", in: raw)
            if selfClosing {
                if let identifier { result[identifier] = "" }
                continue
            }
            stack.append((id: identifier, text: ""))
        }

        return result
    }

    private static func nextIndex(of needle: Character, in scalars: [Character], from start: Int) -> Int? {
        var cursor = start + 1
        while cursor < scalars.count {
            if scalars[cursor] == needle { return cursor }
            cursor += 1
        }
        return nil
    }

    private static func attributeValue(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
        let rest = tag[range.upperBound...]
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        let afterQuote = rest.dropFirst()
        guard let end = afterQuote.firstIndex(of: quote) else { return nil }
        let value = String(afterQuote[..<end])
        return value.isEmpty ? nil : value
    }

    private static func decodeEntities(_ value: String) -> String {
        var text = value
        for (entity, replacement) in [
            ("&nbsp;", "\u{00a0}"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&mdash;", "—"), ("&hellip;", "…"),
        ] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = decodeNumericReferences(text)
        // Ampersand last, so a literal "&amp;#225;" never turns into a second decode pass.
        return text.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func decodeNumericReferences(_ value: String) -> String {
        guard value.contains("&#") else { return value }
        var out = ""
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "&" else {
                out.append(value[index])
                index = value.index(after: index)
                continue
            }

            let limit = value.index(index, offsetBy: 12, limitedBy: value.endIndex) ?? value.endIndex
            let window = value[index..<limit]
            guard window.hasPrefix("&#"),
                let semicolon = window.firstIndex(of: ";")
            else {
                out.append(value[index])
                index = value.index(after: index)
                continue
            }

            let body = window[window.index(window.startIndex, offsetBy: 2)..<semicolon]
            let raw: UInt32? =
                (body.first == "x" || body.first == "X")
                ? UInt32(body.dropFirst(), radix: 16)
                : UInt32(body, radix: 10)
            guard let raw, let scalar = Unicode.Scalar(raw) else {
                out.append(value[index])
                index = value.index(after: index)
                continue
            }
            out.append(Character(scalar))
            index = value.index(after: semicolon)
        }
        return out
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func normalized(_ href: String) -> String {
        let withoutFragment = href.components(separatedBy: "#").first ?? href
        return withoutFragment.components(separatedBy: "/").last ?? withoutFragment
    }

    // The player has no open Publication, so the chapter is read straight out of the EPUB archive.
    static func chapterHTML(epubURL: URL, href: String) async -> String? {
        let wanted = normalized(href).lowercased()
        guard let archive = try? await Archive(url: epubURL, accessMode: .read),
            let entries = try? await archive.entries(),
            let entry = entries.first(where: {
                $0.type == .file && normalized($0.path).lowercased() == wanted
            })
        else { return nil }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-lyrics-\(UUID().uuidString).xhtml")
        defer { try? FileManager.default.removeItem(at: destination) }

        guard (try? await archive.extract(entry, to: destination)) != nil,
            let data = try? Data(contentsOf: destination)
        else { return nil }

        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }
}
