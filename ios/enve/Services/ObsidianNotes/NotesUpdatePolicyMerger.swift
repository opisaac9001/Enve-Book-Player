import Foundation

enum NotesUpdatePolicyMerger {

    static func merge(
        existing: String?,
        rendered: String,
        policy: UserPreferences.ObsidianUpdatePolicy
    ) -> String {
        guard let existing = existing, !existing.isEmpty else {
            return rendered
        }

        switch policy {
        case .replace:
            return rendered
        case .append:
            return appendNewBlocks(existing: existing, rendered: rendered)
        case .smartInsert:
            return smartInsertNewBlocks(existing: existing, rendered: rendered)
        case .magic:
            return magicMerge(existing: existing, rendered: rendered)
        }
    }

    struct HighlightBlock: Equatable {
        var id: String

        var body: String

        var userTail: String
    }

    struct ParsedDocument: Equatable {
        var preamble: String
        var blocks: [HighlightBlock]
        var epilogue: String
    }

    static func parse(_ source: String) -> ParsedDocument {
        let startPattern = "<!-- enve-highlight:"
        let startSuffix = " start -->"
        let endSuffix = " end -->"

        var blocks: [HighlightBlock] = []
        var preamble = ""
        var cursor = source.startIndex

        guard let firstStart = source.range(of: startPattern, range: cursor..<source.endIndex) else {
            return ParsedDocument(preamble: source, blocks: [], epilogue: "")
        }
        preamble = String(source[cursor..<firstStart.lowerBound])
        cursor = firstStart.lowerBound

        while cursor < source.endIndex {

            guard let startRange = source.range(of: startPattern, range: cursor..<source.endIndex) else {
                break
            }

            guard let startEnd = source.range(of: startSuffix, range: startRange.upperBound..<source.endIndex) else {
                break
            }
            let id = String(source[startRange.upperBound..<startEnd.lowerBound])

            let endMarker = "<!-- enve-highlight:\(id)\(endSuffix)"
            guard let endRange = source.range(of: endMarker, range: startEnd.upperBound..<source.endIndex) else {

                break
            }

            var bodyEnd = endRange.upperBound
            if bodyEnd < source.endIndex, source[bodyEnd] == "\n" {
                bodyEnd = source.index(after: bodyEnd)
            }
            let body = String(source[startRange.lowerBound..<bodyEnd])

            let nextStart = source.range(of: startPattern, range: bodyEnd..<source.endIndex)
            let tailEnd = nextStart?.lowerBound ?? source.endIndex
            let userTail = String(source[bodyEnd..<tailEnd])

            blocks.append(HighlightBlock(id: id, body: body, userTail: userTail))

            cursor = tailEnd
        }

        return ParsedDocument(preamble: preamble, blocks: blocks, epilogue: "")
    }

    private static func appendNewBlocks(existing: String, rendered: String) -> String {
        let existingDoc = parse(existing)
        let renderedDoc = parse(rendered)
        let existingIds = Set(existingDoc.blocks.map { $0.id })

        let newBlocks = renderedDoc.blocks.filter { !existingIds.contains($0.id) }
        if newBlocks.isEmpty { return existing }

        var out = existing
        if !out.hasSuffix("\n") { out += "\n" }
        for block in newBlocks {
            out += block.body
            if !block.userTail.isEmpty {
                out += block.userTail
            } else {
                out += "\n"
            }
        }
        return out
    }

    private static func smartInsertNewBlocks(existing: String, rendered: String) -> String {
        let existingDoc = parse(existing)
        let renderedDoc = parse(rendered)
        let existingIds = Set(existingDoc.blocks.map { $0.id })
        let hasNew = renderedDoc.blocks.contains { !existingIds.contains($0.id) }
        if !hasNew { return existing }
        return appendNewBlocks(existing: existing, rendered: rendered)
    }

    private static func magicMerge(existing: String, rendered: String) -> String {
        if !existing.contains("<!-- enve-highlight:") {
            return appendNewBlocks(existing: existing, rendered: rendered)
        }

        let existingDoc = parse(existing)
        let renderedDoc = parse(rendered)
        let userTailById: [String: String] = Dictionary(
            uniqueKeysWithValues: existingDoc.blocks.map { ($0.id, $0.userTail) }
        )

        var out = renderedDoc.preamble
        for block in renderedDoc.blocks {
            out += block.body
            if let userTail = userTailById[block.id], !userTail.isEmpty {
                out += userTail
            } else {
                out += block.userTail
            }
        }
        return out
    }
}
