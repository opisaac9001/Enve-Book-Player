import Foundation

struct DescriptionNormalizer {
    nonisolated static func normalize(_ text: String?) -> String? {
        guard var text = text else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var normalized = looksLikeHTML(text) ? htmlToPlainText(text) : text
        normalized = stripMarkdown(normalized)
        let collapsed = collapseWhitespace(normalized)
        return collapsed.isEmpty ? nil : collapsed
    }

    private nonisolated static func looksLikeHTML(_ text: String) -> Bool {
        text.contains("<") && text.contains(">")
    }

    private nonisolated static func htmlToPlainText(_ html: String) -> String {
        var result = ""
        result.reserveCapacity(html.count)
        var i = html.startIndex
        while i < html.endIndex {
            let c = html[i]
            if c == "<" {
                if let closeIdx = html[i...].firstIndex(of: ">") {
                    let tagContent = html[html.index(after: i)..<closeIdx].lowercased()
                    if tagContent.hasPrefix("br") || tagContent.hasPrefix("/p") || tagContent.hasPrefix("p") || tagContent.hasPrefix("/li")
                        || tagContent.hasPrefix("li") || tagContent.hasPrefix("/div") || tagContent.hasPrefix("/h")
                    {
                        result.append("\n")
                    }
                    i = html.index(after: closeIdx)
                } else {
                    result.append(c)
                    i = html.index(after: i)
                }
            } else if c == "&" {
                if let semi = html[i...].firstIndex(of: ";") {
                    let entityRange = html.index(after: i)..<semi
                    let entity = String(html[entityRange])
                    let decoded = decodeHTMLEntity(entity)
                    result.append(decoded)
                    i = html.index(after: semi)
                } else {
                    result.append(c)
                    i = html.index(after: i)
                }
            } else {
                result.append(c)
                i = html.index(after: i)
            }
        }
        return result
    }

    private nonisolated static func decodeHTMLEntity(_ entity: String) -> String {
        switch entity.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "mdash": return "\u{2014}"
        case "ndash": return "\u{2013}"
        case "hellip": return "…"
        case "ldquo": return "\u{201C}"
        case "rdquo": return "\u{201D}"
        case "lsquo": return "\u{2018}"
        case "rsquo": return "\u{2019}"
        default: break
        }
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            if let cp = UInt32(entity.dropFirst(2), radix: 16),
                let scalar = Unicode.Scalar(cp)
            {
                return String(scalar)
            }
        } else if entity.hasPrefix("#") {
            if let cp = UInt32(entity.dropFirst()),
                let scalar = Unicode.Scalar(cp)
            {
                return String(scalar)
            }
        }
        return "&\(entity);"
    }

    private nonisolated static func stripMarkdown(_ text: String) -> String {
        var result = text

        let patterns: [(String, String)] = [
            (#"\*{3}(.+?)\*{3}"#, "$1"),
            (#"\*{2}(.+?)\*{2}"#, "$1"),
            (#"(?<!\w)\*(.+?)\*(?!\w)"#, "$1"),
            (#"_{3}(.+?)_{3}"#, "$1"),
            (#"_{2}(.+?)_{2}"#, "$1"),
            (#"(?<!\w)_(.+?)_(?!\w)"#, "$1"),
            (#"~~(.+?)~~"#, "$1"),
            (#"`(.+?)`"#, "$1"),
            (#"^#{1,6}\s+"#, ""),
            (#"!\[.*?\]\(.*?\)"#, ""),
            (#"\[(.+?)\]\(.*?\)"#, "$1"),
        ]
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: replacement
                )
            }
        }
        return result
    }

    private nonisolated static func collapseWhitespace(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result = ""
        result.reserveCapacity(unified.count)
        var newlineRun = 0
        var spaceRun = false

        for c in unified {
            if c == "\n" {
                newlineRun += 1
                spaceRun = false
                if newlineRun <= 2 { result.append(c) }
            } else if c == " " || c == "\t" {
                if newlineRun == 0 {
                    if !spaceRun {
                        result.append(" ")
                        spaceRun = true
                    }
                }
            } else {
                newlineRun = 0
                spaceRun = false
                result.append(c)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
