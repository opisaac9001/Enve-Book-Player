import Foundation

enum AnnotationExportFormat: String, CaseIterable, Identifiable {
    case markdown = "Markdown"
    case plainText = "Plain Text"
    case json = "JSON"
    case csv = "CSV"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .json: return "json"
        case .csv: return "csv"
        }
    }

    var mimeType: String {
        switch self {
        case .markdown: return "text/markdown"
        case .plainText: return "text/plain"
        case .json: return "application/json"
        case .csv: return "text/csv"
        }
    }
}

struct AnnotationExporter {
    let bookTitle: String
    let bookAuthor: String?
    let annotations: [ReaderAnnotation]
    let bookmarks: [Bookmark]

    func export(format: AnnotationExportFormat) -> String {
        switch format {
        case .markdown: return exportMarkdown()
        case .plainText: return exportPlainText()
        case .json: return exportJSON()
        case .csv: return exportCSV()
        }
    }

    private func exportMarkdown() -> String {
        var md = "# \(bookTitle)\n"
        if let author = bookAuthor {
            md += "**\(author)**\n"
        }
        md += "\n---\n\n"

        if !annotations.isEmpty {
            md += "## Highlights & Annotations\n\n"
            let sorted = annotations.sorted { $0.position < $1.position }
            for annotation in sorted {
                let pos = Int(annotation.position * 100)
                md += "### \(annotation.style.label) at \(pos)%\n\n"
                md += "> \(annotation.text)\n\n"
                if let note = normalizedNote(annotation.note) {
                    md += "**Annotation:**\n\n"
                    md += markdownQuotedLines(note)
                    md += "\n"
                }
                md += "*\(annotation.formattedTimestamp)*\n\n"
                md += "---\n\n"
            }
        }

        if !bookmarks.isEmpty {
            md += "## Bookmarks\n\n"
            let ebookBookmarks = bookmarks.filter { $0.mediaType == .ebook }
            for bookmark in ebookBookmarks {
                md += "- **\(bookmark.chapterTitle ?? bookmark.title)** "
                md += "(\(bookmark.formattedTime))\n"
                if let note = bookmark.note, !note.isEmpty {
                    md += "  - \(note)\n"
                }
            }
        }

        md += "\n*Exported from Enve on \(DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short))*\n"
        return md
    }

    private func exportPlainText() -> String {
        var txt = "\(bookTitle)\n"
        if let author = bookAuthor {
            txt += "by \(author)\n"
        }
        txt += String(repeating: "=", count: 40) + "\n\n"

        if !annotations.isEmpty {
            txt += "HIGHLIGHTS & ANNOTATIONS\n"
            txt += String(repeating: "-", count: 30) + "\n\n"
            let sorted = annotations.sorted { $0.position < $1.position }
            for annotation in sorted {
                let pos = Int(annotation.position * 100)
                txt += "[\(annotation.style.label)] at \(pos)%:\n"
                txt += "\"\(annotation.text)\"\n"
                if let note = annotation.note, !note.isEmpty {
                    txt += "Note: \(note)\n"
                }
                txt += "(\(annotation.formattedTimestamp))\n\n"
            }
        }

        if !bookmarks.isEmpty {
            txt += "BOOKMARKS\n"
            txt += String(repeating: "-", count: 30) + "\n\n"
            let ebookBookmarks = bookmarks.filter { $0.mediaType == .ebook }
            for bookmark in ebookBookmarks {
                txt += "* \(bookmark.chapterTitle ?? bookmark.title) (\(bookmark.formattedTime))\n"
                if let note = bookmark.note, !note.isEmpty {
                    txt += "  Note: \(note)\n"
                }
            }
        }

        return txt
    }

    private func exportJSON() -> String {
        struct ExportData: Encodable {
            let bookTitle: String
            let bookAuthor: String?
            let exportDate: String
            let annotations: [AnnotationEntry]
            let bookmarks: [BookmarkEntry]
        }

        struct AnnotationEntry: Encodable {
            let text: String
            let note: String?
            let color: String
            let style: String
            let position: Double
            let createdAt: String
        }

        struct BookmarkEntry: Encodable {
            let title: String
            let chapter: String?
            let position: String
            let note: String?
            let createdAt: String
        }

        let formatter = ISO8601DateFormatter()

        let data = ExportData(
            bookTitle: bookTitle,
            bookAuthor: bookAuthor,
            exportDate: formatter.string(from: Date()),
            annotations: annotations.sorted { $0.position < $1.position }.map {
                AnnotationEntry(
                    text: $0.text,
                    note: $0.note,
                    color: $0.colorHex,
                    style: $0.style.rawValue,
                    position: $0.position,
                    createdAt: formatter.string(from: $0.createdAt)
                )
            },
            bookmarks: bookmarks.filter { $0.mediaType == .ebook }.map {
                BookmarkEntry(
                    title: $0.title,
                    chapter: $0.chapterTitle,
                    position: $0.formattedTime,
                    note: $0.note,
                    createdAt: formatter.string(from: $0.timestamp)
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let json = try? encoder.encode(data),
            let str = String(data: json, encoding: .utf8)
        else {
            return "{}"
        }
        return str
    }

    private func exportCSV() -> String {
        var csv = "Type,Text,Note,Color,Style,Position,Chapter,Date\n"

        let sorted = annotations.sorted { $0.position < $1.position }
        for a in sorted {
            let text = csvEscape(a.text)
            let note = csvEscape(a.note ?? "")
            csv += "annotation,\(text),\(note),\(a.colorHex),\(a.style.rawValue),\(Int(a.position * 100))%,,\(a.formattedTimestamp)\n"
        }

        let ebookBookmarks = bookmarks.filter { $0.mediaType == .ebook }
        for b in ebookBookmarks {
            let title = csvEscape(b.title)
            let note = csvEscape(b.note ?? "")
            let chapter = csvEscape(b.chapterTitle ?? "")
            csv += "bookmark,\(title),\(note),,,\(b.formattedTime),\(chapter),\(b.formattedDate)\n"
        }

        return csv
    }

    private func csvEscape(_ str: String) -> String {
        let escaped = str.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") {
            return "\"\(escaped)\""
        }
        return escaped
    }

    private func normalizedNote(_ note: String?) -> String? {
        guard let note else { return nil }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func markdownQuotedLines(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let lineText = String(line)
                return lineText.isEmpty ? ">" : "> \(lineText)"
            }
            .joined(separator: "\n") + "\n\n"
    }
}
