import Foundation

enum NotesTemplateEngine {

    static let maxTemplateBytes = 256 * 1024

    static let maxNestingDepth = 16

    static func render(template: String, payload: BookNotesPayload) -> String {
        let bounded = boundedTemplate(template)
        let context = TemplateContext(root: payloadToValue(payload))
        let nodes = parse(bounded)
        return renderNodes(nodes, context: context)
    }

    static func render(template: String, with values: [String: TemplateValue]) -> String {
        let bounded = boundedTemplate(template)
        let context = TemplateContext(root: .dict(values))
        let nodes = parse(bounded)
        return renderNodes(nodes, context: context)
    }

    private static func boundedTemplate(_ template: String) -> String {
        guard template.utf8.count > maxTemplateBytes else { return template }
        let prefix = template.prefix(maxTemplateBytes)
        return String(prefix)
    }

    enum TemplateValue: Sendable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case date(Date)
        case array([TemplateValue])
        case dict([String: TemplateValue])
        case null

        var isTruthy: Bool {
            switch self {
            case .null: return false
            case .bool(let b): return b
            case .string(let s): return !s.isEmpty
            case .int(let i): return i != 0
            case .double(let d): return d != 0
            case .date: return true
            case .array(let a): return !a.isEmpty
            case .dict(let d): return !d.isEmpty
            }
        }

        var stringForOutput: String {
            switch self {
            case .string(let s): return s
            case .int(let i): return String(i)
            case .double(let d):
                if d == d.rounded() && abs(d) < 1e15 {
                    return String(format: "%g", d)
                }
                return String(d)
            case .bool(let b): return b ? "true" : "false"
            case .date(let d):
                let f = ISO8601DateFormatter()
                return f.string(from: d)
            case .array(let a):
                return a.map { $0.stringForOutput }.joined(separator: ", ")
            case .dict: return ""
            case .null: return ""
            }
        }
    }

    final class TemplateContext {
        var stack: [[String: TemplateValue]] = []
        let root: TemplateValue

        init(root: TemplateValue) {
            self.root = root
        }

        func push(_ frame: [String: TemplateValue]) { stack.append(frame) }
        func pop() { _ = stack.popLast() }

        func resolve(_ path: String) -> TemplateValue {
            let parts = path.split(separator: ".").map(String.init)
            guard let first = parts.first else { return .null }

            var cur: TemplateValue
            if let frame = stack.reversed().first(where: { $0[first] != nil }), let v = frame[first] {
                cur = v
            } else if case .dict(let rootDict) = root, let v = rootDict[first] {
                cur = v
            } else {
                return .null
            }

            for p in parts.dropFirst() {
                if case .dict(let d) = cur, let v = d[p] {
                    cur = v
                } else if case .array(let a) = cur {
                    if p == "size" || p == "count" {
                        cur = .int(a.count)
                    } else if let idx = Int(p), idx >= 0, idx < a.count {
                        cur = a[idx]
                    } else {
                        return .null
                    }
                } else {
                    return .null
                }
            }
            return cur
        }
    }

    private indirect enum Node {
        case text(String)
        case output(expression: String, filters: [(name: String, arg: String?)])
        case ifBlock(expr: IfExpr, thenBranch: [Node], elseBranch: [Node])
        case forBlock(itemName: String, collectionPath: String, body: [Node])
    }

    private enum IfExpr {
        case truthy(path: String)
        case equals(path: String, literal: String)
        case notEquals(path: String, literal: String)
    }

    private static func parse(_ template: String) -> [Node] {
        let (nodes, _) = parseNodes(template, startIndex: template.startIndex, terminators: [], depth: 0)
        return nodes
    }

    private static func parseNodes(
        _ template: String,
        startIndex: String.Index,
        terminators: [String],
        depth: Int
    ) -> (nodes: [Node], end: String.Index) {
        if depth > maxNestingDepth {

            return ([.text(String(template[startIndex..<template.endIndex]))], template.endIndex)
        }
        var nodes: [Node] = []
        var i = startIndex

        while i < template.endIndex {
            let nextOpenTag = template.range(of: "{%", range: i..<template.endIndex)
            let nextOpenExpr = template.range(of: "{{", range: i..<template.endIndex)

            let nextDelim: (range: Range<String.Index>, isTag: Bool)?
            switch (nextOpenTag, nextOpenExpr) {
            case (nil, nil): nextDelim = nil
            case (let t?, nil): nextDelim = (t, true)
            case (nil, let e?): nextDelim = (e, false)
            case (let t?, let e?):
                nextDelim = t.lowerBound < e.lowerBound ? (t, true) : (e, false)
            }

            guard let delim = nextDelim else {

                let rest = String(template[i..<template.endIndex])
                if !rest.isEmpty { nodes.append(.text(rest)) }
                return (nodes, template.endIndex)
            }

            if delim.range.lowerBound > i {
                let chunk = String(template[i..<delim.range.lowerBound])
                if !chunk.isEmpty { nodes.append(.text(chunk)) }
            }

            if delim.isTag {

                let close = template.range(of: "%}", range: delim.range.upperBound..<template.endIndex)
                guard let closeRange = close else {

                    let rest = String(template[delim.range.lowerBound..<template.endIndex])
                    nodes.append(.text(rest))
                    return (nodes, template.endIndex)
                }
                let inner = template[delim.range.upperBound..<closeRange.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                let afterClose = closeRange.upperBound

                if terminators.contains(inner) {
                    return (nodes, afterClose)
                }

                if inner.hasPrefix("if ") {
                    let exprStr = String(inner.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    let expr = parseIfExpr(exprStr)
                    let (thenBranch, afterThen) = parseNodes(
                        template,
                        startIndex: afterClose,
                        terminators: ["else", "endif"],
                        depth: depth + 1
                    )

                    if afterThen <= template.endIndex,
                        let elseTag = lastMatchedTag(template, before: afterThen),
                        elseTag == "else"
                    {
                        let (elseBranch, afterElse) = parseNodes(template, startIndex: afterThen, terminators: ["endif"], depth: depth + 1)
                        nodes.append(.ifBlock(expr: expr, thenBranch: thenBranch, elseBranch: elseBranch))
                        i = afterElse
                    } else {
                        nodes.append(.ifBlock(expr: expr, thenBranch: thenBranch, elseBranch: []))
                        i = afterThen
                    }
                } else if inner.hasPrefix("for ") {

                    let body = String(inner.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    let parts = body.components(separatedBy: " in ")
                    let itemName = parts.first?.trimmingCharacters(in: .whitespaces) ?? "item"
                    let collectionPath =
                        parts.count > 1
                        ? parts[1].trimmingCharacters(in: .whitespaces)
                        : ""
                    let (forBody, afterFor) = parseNodes(template, startIndex: afterClose, terminators: ["endfor"], depth: depth + 1)
                    nodes.append(.forBlock(itemName: itemName, collectionPath: collectionPath, body: forBody))
                    i = afterFor
                } else {

                    nodes.append(.text("{% \(inner) %}"))
                    i = afterClose
                }
            } else {

                let close = template.range(of: "}}", range: delim.range.upperBound..<template.endIndex)
                guard let closeRange = close else {
                    let rest = String(template[delim.range.lowerBound..<template.endIndex])
                    nodes.append(.text(rest))
                    return (nodes, template.endIndex)
                }
                let inner = String(template[delim.range.upperBound..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let parsed = parseExpression(inner)
                nodes.append(.output(expression: parsed.expression, filters: parsed.filters))
                i = closeRange.upperBound
            }
        }

        return (nodes, template.endIndex)
    }

    private static func lastMatchedTag(_ template: String, before position: String.Index) -> String? {

        let leading = template[template.startIndex..<position]
        guard let closeRange = leading.range(of: "%}", options: .backwards) else { return nil }

        guard let openRange = leading.range(of: "{%", options: .backwards, range: leading.startIndex..<closeRange.lowerBound) else {
            return nil
        }
        let inner = template[openRange.upperBound..<closeRange.lowerBound].trimmingCharacters(in: .whitespaces)
        return inner
    }

    private static func parseIfExpr(_ s: String) -> IfExpr {

        if let eq = s.range(of: " == ") {
            let left = String(s[s.startIndex..<eq.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(s[eq.upperBound..<s.endIndex]).trimmingCharacters(in: .whitespaces)
            return .equals(path: left, literal: stripQuotes(right))
        }
        if let neq = s.range(of: " != ") {
            let left = String(s[s.startIndex..<neq.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(s[neq.upperBound..<s.endIndex]).trimmingCharacters(in: .whitespaces)
            return .notEquals(path: left, literal: stripQuotes(right))
        }
        return .truthy(path: s)
    }

    private static func parseExpression(_ s: String) -> (expression: String, filters: [(name: String, arg: String?)]) {
        let parts = splitTopLevel(s, by: "|")
        let expression = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let filters: [(name: String, arg: String?)] = parts.dropFirst().map { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let colon = trimmed.firstIndex(of: ":") {
                let name = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let arg = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                return (name, stripQuotes(arg))
            }
            return (trimmed, nil)
        }
        return (expression, filters)
    }

    private static func splitTopLevel(_ s: String, by separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        for ch in s {
            if ch == "'" && !inDouble { inSingle.toggle(); current.append(ch); continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); current.append(ch); continue }
            if ch == separator && !inSingle && !inDouble {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result
    }

    private static func stripQuotes(_ s: String) -> String {
        var t = s
        if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
            t.removeFirst(); t.removeLast()
        } else if t.hasPrefix("'") && t.hasSuffix("'") && t.count >= 2 {
            t.removeFirst(); t.removeLast()
        }
        return t
    }

    private static func renderNodes(_ nodes: [Node], context: TemplateContext) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let t):
                out += t
            case .output(let expression, let filters):
                let value: TemplateValue =
                    expression.hasPrefix("\"") || expression.hasPrefix("'")
                    ? .string(stripQuotes(expression))
                    : context.resolve(expression)
                let after = applyFilters(value, filters: filters)
                out += after.stringForOutput
            case .ifBlock(let expr, let thenBranch, let elseBranch):
                if evaluateIf(expr, context: context) {
                    out += renderNodes(thenBranch, context: context)
                } else {
                    out += renderNodes(elseBranch, context: context)
                }
            case .forBlock(let itemName, let collectionPath, let body):
                let value = context.resolve(collectionPath)
                guard case .array(let items) = value, !items.isEmpty else { continue }
                let total = items.count
                for (idx, item) in items.enumerated() {
                    let forloop: TemplateValue = .dict([
                        "index": .int(idx + 1),
                        "index0": .int(idx),
                        "first": .bool(idx == 0),
                        "last": .bool(idx == total - 1),
                        "length": .int(total),
                    ])
                    context.push([itemName: item, "forloop": forloop])
                    out += renderNodes(body, context: context)
                    context.pop()
                }
            }
        }
        return out
    }

    private static func evaluateIf(_ expr: IfExpr, context: TemplateContext) -> Bool {
        switch expr {
        case .truthy(let path):
            return evaluateBoolExpression(path, context: context)
        case .equals(let path, let literal):
            return context.resolve(path).stringForOutput == literal
        case .notEquals(let path, let literal):
            return context.resolve(path).stringForOutput != literal
        }
    }

    private static func evaluateBoolExpression(_ raw: String, context: TemplateContext) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)

        if s == "true" { return true }
        if s == "false" { return false }

        return context.resolve(s).isTruthy
    }

    private static func applyFilters(
        _ value: TemplateValue,
        filters: [(name: String, arg: String?)]
    ) -> TemplateValue {
        var current = value
        for f in filters {
            current = applyFilter(name: f.name, arg: f.arg, value: current)
        }
        return current
    }

    private static func applyFilter(name: String, arg: String?, value: TemplateValue) -> TemplateValue {
        switch name {
        case "sanitize_filename":
            return .string(sanitizeFilename(value.stringForOutput))
        case "escape_md":
            return .string(escapeMarkdown(value.stringForOutput))
        case "date":
            guard case .date(let d) = value else {
                return value
            }
            let formatter = DateFormatter()
            formatter.dateFormat = arg ?? "yyyy-MM-dd"
            return .string(formatter.string(from: d))
        case "default":
            if value.isTruthy { return value }
            return .string(arg ?? "")
        case "join":
            guard case .array(let items) = value else { return value }
            let sep = arg ?? ", "
            return .string(items.map { $0.stringForOutput }.joined(separator: sep))
        case "truncate":
            let len = Int(arg ?? "") ?? 80
            let s = value.stringForOutput
            if s.count <= len { return .string(s) }
            return .string(String(s.prefix(len)))
        case "lower":
            return .string(value.stringForOutput.lowercased())
        case "upper":
            return .string(value.stringForOutput.uppercased())
        default:
            return value
        }
    }

    static func sanitizeFilename(_ raw: String) -> String {
        let illegal: Set<Character> = ["/", "\\", "?", "%", "*", "|", "\"", "<", ">", ":"]
        var s = String(raw.map { illegal.contains($0) || $0 == "\0" ? Character(" ") : $0 })
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "." || s == ".." { s = "Untitled" }

        while let last = s.last, last == "." || last == " " {
            s.removeLast()
        }
        if s.isEmpty { s = "Untitled" }
        return s.precomposedStringWithCanonicalMapping
    }

    private static func escapeMarkdown(_ s: String) -> String {

        return
            s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func payloadToValue(_ payload: BookNotesPayload) -> TemplateValue {
        return .dict([
            "book": bookValue(payload.book),
            "highlights": .array(payload.highlights.map(highlightValue)),
            "audiobookNotes": .array(payload.audiobookNotes.map(audiobookValue)),
            "ebookBookmarks": .array(payload.ebookBookmarks.map(bookmarkValue)),
            "chapters": .array(payload.chapters.map { .string($0) }),
            "exportedAt": .date(payload.exportedAt),
            "lastSyncedAt": payload.lastSyncedAt.map { TemplateValue.date($0) } ?? .null,
        ])
    }

    private static func bookValue(_ b: BookNotesPayload.BookMeta) -> TemplateValue {
        return .dict([
            "id": .string(b.id),
            "title": .string(b.title),
            "authors": .array(b.authors.map { .string($0) }),
            "narrator": b.narrator.map { TemplateValue.string($0) } ?? .null,
            "series": b.series.map { TemplateValue.string($0) } ?? .null,
            "seriesNumber": b.seriesNumber.map { TemplateValue.string($0) } ?? .null,
            "publishedYear": b.publishedYear.map { TemplateValue.int($0) } ?? .null,
            "publisher": b.publisher.map { TemplateValue.string($0) } ?? .null,
            "isbn": b.isbn.map { TemplateValue.string($0) } ?? .null,
            "asin": b.asin.map { TemplateValue.string($0) } ?? .null,
            "language": b.language.map { TemplateValue.string($0) } ?? .null,
            "genres": .array(b.genres.map { .string($0) }),
            "mediaType": .string(b.mediaType),
            "coverPath": b.coverPath.map { TemplateValue.string($0) } ?? .null,
            "progress": .double(b.progress),
        ])
    }

    private static func highlightValue(_ h: BookNotesPayload.HighlightItem) -> TemplateValue {
        return .dict([
            "id": .string(h.id),
            "text": .string(h.text),
            "note": h.note.map { TemplateValue.string($0) } ?? .null,
            "colorHex": .string(h.colorHex),
            "style": .string(h.style),
            "position": .double(h.position),
            "chapterTitle": h.chapterTitle.map { TemplateValue.string($0) } ?? .null,
            "createdAt": .date(h.createdAt),
            "updatedAt": .date(h.updatedAt),
        ])
    }

    private static func audiobookValue(_ n: BookNotesPayload.AudiobookNote) -> TemplateValue {
        return .dict([
            "id": .string(n.id),
            "title": .string(n.title),
            "note": n.note.map { TemplateValue.string($0) } ?? .null,
            "timestampSeconds": .double(n.timestampSeconds),
            "formattedTime": .string(n.formattedTime),
            "chapterTitle": n.chapterTitle.map { TemplateValue.string($0) } ?? .null,
            "createdAt": .date(n.createdAt),
        ])
    }

    private static func bookmarkValue(_ b: BookNotesPayload.EbookBookmarkItem) -> TemplateValue {
        return .dict([
            "id": .string(b.id),
            "title": .string(b.title),
            "chapterTitle": b.chapterTitle.map { TemplateValue.string($0) } ?? .null,
            "progress": .double(b.progress),
            "note": b.note.map { TemplateValue.string($0) } ?? .null,
            "createdAt": .date(b.createdAt),
        ])
    }
}
