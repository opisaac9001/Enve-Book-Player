import Foundation

struct InlineFileposTOCEntry: Equatable, Sendable {
    let label: String
    let position: Int

    var anchorID: String {
        "enve-filepos-\(position)"
    }
}

enum InlineFileposTOCHelper {
    static func parseEntries(from htmlData: Data, encoding: String.Encoding) -> [InlineFileposTOCEntry] {
        let html =
            String(data: htmlData, encoding: encoding)
            ?? String(data: htmlData, encoding: .isoLatin1)
            ?? ""
        return parseEntries(from: html)
    }

    static func parseEntries(from html: String) -> [InlineFileposTOCEntry] {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"<a\s+filepos\s*=\s*"?([0-9]+)"?[^>]*>(.*?)</a>"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
        else {
            return []
        }

        let nsRange = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: nsRange)
        var entries: [InlineFileposTOCEntry] = []
        var seenPositions = Set<Int>()

        for match in matches {
            guard
                let positionRange = Range(match.range(at: 1), in: html),
                let labelRange = Range(match.range(at: 2), in: html),
                let position = Int(html[positionRange]),
                position >= 0
            else {
                continue
            }

            let label = cleanedLabel(from: String(html[labelRange]))
            guard !label.isEmpty, seenPositions.insert(position).inserted else {
                continue
            }

            entries.append(InlineFileposTOCEntry(label: label, position: position))
        }

        return entries.sorted { $0.position < $1.position }
    }

    static func injectAnchorsAndRewriteLinks(in html: String, entries: [InlineFileposTOCEntry]) -> String {
        guard !entries.isEmpty else { return html }

        var result = html
        for entry in entries.sorted(by: { $0.position > $1.position }) {
            guard
                let utf8Index = result.utf8.index(result.utf8.startIndex, offsetBy: entry.position, limitedBy: result.utf8.endIndex),
                let stringIndex = String.Index(utf8Index, within: result)
            else {
                continue
            }

            result.insert(contentsOf: #"<a id="\#(entry.anchorID)"></a>"#, at: stringIndex)
        }

        guard
            let fileposRegex = try? NSRegularExpression(
                pattern: #"\bfilepos\s*=\s*"?([0-9]+)"?"#,
                options: [.caseInsensitive]
            )
        else {
            return result
        }

        let nsRange = NSRange(result.startIndex..., in: result)
        let matches = fileposRegex.matches(in: result, range: nsRange)
        for match in matches.reversed() {
            guard
                let attributeRange = Range(match.range(at: 0), in: result),
                let valueRange = Range(match.range(at: 1), in: result),
                let position = Int(result[valueRange])
            else {
                continue
            }

            result.replaceSubrange(attributeRange, with: "href=\"#enve-filepos-\(position)\"")
        }

        return result
    }

    private static func cleanedLabel(from html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return
            withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
