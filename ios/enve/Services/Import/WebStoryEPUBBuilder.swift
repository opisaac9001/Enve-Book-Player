#if !os(tvOS)
import Foundation
import ReadiumZIPFoundation

@MainActor
final class WebStoryEPUBBuilder {
    private let archive: Archive
    private let preview: WebStoryPreview
    private let url: URL
    private var chapters: [(title: String, path: String)] = []
    private var language = "en"

    init(directory: URL, preview: WebStoryPreview) async throws {
        self.preview = preview
        url = directory.appendingPathComponent("Web story.epub")
        archive = try await Archive(url: url, accessMode: .create)
        try await add("mimetype", data: Data("application/epub+zip".utf8), compression: .none)
        try await add("META-INF/container.xml", text: """
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """)
        try await add("OEBPS/style.css", text: """
        body { line-height: 1.5; }
        pre { white-space: pre-wrap; }
        table { border-collapse: collapse; max-width: 100%; }
        td, th { border: 1px solid currentColor; padding: .25em; }
        .source { font-size: .85em; }
        """)
    }

    func append(page: WebStoryPage) async throws {
        let path = "Text/chapter-\(chapters.count + 1).xhtml"
        if chapters.isEmpty, !page.language.isEmpty { language = page.language }
        try await add("OEBPS/\(path)", text: """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(escape(page.language))"><head><title>\(escape(page.title))</title><link rel="stylesheet" href="../style.css"/></head><body><h1>\(escape(page.title))</h1>\(page.html)<p class="source"><a href="\(escape(page.url.absoluteString))">Read on \(escape(page.siteName))</a></p></body></html>
        """)
        chapters.append((page.title, path))
    }

    func finish() async throws -> URL {
        guard !chapters.isEmpty else { throw WebStoryImportError.unreadablePage }
        let identifier = "urn:uuid:\(UUID().uuidString)"
        let modified = ISO8601DateFormatter().string(from: Date())
        let manifest = chapters.enumerated().map { index, chapter in
            "<item id=\"chapter-\(index)\" href=\"\(chapter.path)\" media-type=\"application/xhtml+xml\"/>"
        }.joined()
        let spine = chapters.indices.map { "<itemref idref=\"chapter-\($0)\"/>" }.joined()
        try await add("OEBPS/content.opf", text: """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">\(identifier)</dc:identifier><dc:title>\(escape(preview.title))</dc:title>\(preview.author.map { "<dc:creator>\(escape($0))</dc:creator>" } ?? "")<dc:language>\(escape(language))</dc:language><dc:source>\(escape(preview.sourceURL.absoluteString))</dc:source><dc:description>\(escape(preview.excerpt))</dc:description><meta property="dcterms:modified">\(modified)</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/><item id="style" href="style.css" media-type="text/css"/>\(manifest)</manifest><spine toc="ncx">\(spine)</spine></package>
        """)
        let links = chapters.map { "<li><a href=\"\($0.path)\">\(escape($0.title))</a></li>" }.joined()
        try await add("OEBPS/nav.xhtml", text: """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><h1>Contents</h1><ol>\(links)</ol></nav></body></html>
        """)
        let points = chapters.enumerated().map { index, chapter in
            "<navPoint id=\"chapter-\(index)\" playOrder=\"\(index + 1)\"><navLabel><text>\(escape(chapter.title))</text></navLabel><content src=\"\(chapter.path)\"/></navPoint>"
        }.joined()
        try await add("OEBPS/toc.ncx", text: """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="\(identifier)"/></head><docTitle><text>\(escape(preview.title))</text></docTitle><navMap>\(points)</navMap></ncx>
        """)
        return url
    }

    private func add(_ path: String, text: String) async throws {
        try await add(path, data: Data(text.utf8))
    }

    private func add(_ path: String, data: Data, compression: CompressionMethod = .deflate) async throws {
        try await archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: compression) { @Sendable position, count in
            let start = Int(position)
            return data.subdata(in: start..<min(data.count, start + count))
        }
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
#endif
