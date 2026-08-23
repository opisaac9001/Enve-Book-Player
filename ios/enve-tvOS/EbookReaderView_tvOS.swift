import SwiftUI
import Zip

struct EbookReaderView_tvOS: View {
    let book: Book

    @Environment(\.dismiss) private var dismiss

    @State private var chapters: [TVEpubChapter] = []
    @State private var chapterIndex = 0
    @State private var pageIndex = 0
    @State private var loadState: LoadState = .loading
    @State private var fontSize: CGFloat = 32

    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    var body: some View {
        ZStack {
            Color(white: 0.06).ignoresSafeArea()
            content
        }
        .focusable()
        .onMoveCommand { dir in
            guard loadState == .ready else { return }
            switch dir {
            case .left: turnBack()
            case .right: turnForward()
            default: break
            }
        }
        .task { await load() }
        .onDisappear { saveProgress() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            VStack(spacing: 24) {
                ProgressView().progressViewStyle(.circular).scaleEffect(2)
                Text("Preparing book…").font(.title3).foregroundStyle(.secondary)
            }
        case .failed(let message):
            failedState(message: message)
        case .ready:
            readerBody
        }
    }

    private func failedState(message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 80))
                .foregroundStyle(.orange)
            Text("Can't open this book")
                .font(.title.weight(.bold))
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 800)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 24)
        }
    }

    private var readerBody: some View {
        let chapter = chapters[chapterIndex]
        let safePageIndex = min(pageIndex, max(0, chapter.pages.count - 1))
        let pageText = chapter.pages.indices.contains(safePageIndex) ? chapter.pages[safePageIndex] : ""

        return VStack(alignment: .leading, spacing: 28) {
            Text(chapter.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            ScrollView {
                Text(pageText)
                    .font(.system(size: fontSize, design: .serif))
                    .lineSpacing(14)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text("Chapter \(chapterIndex + 1) of \(chapters.count)  ·  Page \(safePageIndex + 1) of \(max(chapter.pages.count, 1))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("◂ / ▸ to turn pages")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(80)
    }

    private func turnForward() {
        let chapter = chapters[chapterIndex]
        if pageIndex + 1 < chapter.pages.count {
            pageIndex += 1
        } else if chapterIndex + 1 < chapters.count {
            chapterIndex += 1
            pageIndex = 0
        }
    }

    private func turnBack() {
        if pageIndex > 0 {
            pageIndex -= 1
        } else if chapterIndex > 0 {
            chapterIndex -= 1
            pageIndex = max(0, chapters[chapterIndex].pages.count - 1)
        }
    }

    private func load() async {
        do {
            let loaded = try await TVEpubLoader.load(book: book)
            await MainActor.run {
                self.chapters = loaded
                if let saved = TVEpubProgressStore.load(bookId: book.stableId),
                    loaded.indices.contains(saved.chapter)
                {
                    self.chapterIndex = saved.chapter
                    self.pageIndex = min(saved.page, max(0, loaded[saved.chapter].pages.count - 1))
                }
                self.loadState = loaded.isEmpty ? .failed("This book has no readable text.") : .ready
            }
        } catch let error as TVEpubLoader.LoadError {
            await MainActor.run { self.loadState = .failed(error.message) }
        } catch {
            await MainActor.run { self.loadState = .failed(error.localizedDescription) }
        }
    }

    private func saveProgress() {
        guard loadState == .ready, !chapters.isEmpty else { return }
        TVEpubProgressStore.save(bookId: book.stableId, chapter: chapterIndex, page: pageIndex)
    }
}

struct TVEpubChapter: Hashable, Identifiable {
    let id: Int
    let title: String
    let pages: [String]
}

enum TVEpubLoader {
    struct LoadError: Error {
        let message: String
    }

    @MainActor
    static func load(book: Book, pageCharSize: Int = 1800) async throws -> [TVEpubChapter] {
        let epubURL: URL
        if let local = book.ebookFileURL, FileManager.default.fileExists(atPath: local.path) {
            epubURL = local
        } else {
            do {
                epubURL = try await UnifiedDownloadService.shared.prepareReaderAsset(for: book)
            } catch {
                throw LoadError(message: "Couldn't fetch this book from your server: \(error.localizedDescription)")
            }
        }
        let bookId = book.stableId

        return try await Task.detached(priority: .userInitiated) {
            let unzippedDir = try unzipIfNeeded(epubURL: epubURL, bookId: bookId)
            let opfURL = try locateOPF(in: unzippedDir)
            return try parseChapters(opfURL: opfURL, pageCharSize: pageCharSize)
        }.value
    }

    nonisolated private static func unzipIfNeeded(epubURL: URL, bookId: String) throws -> URL {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EnveTV/epub", isDirectory: true)
        let bookDir = cacheRoot.appendingPathComponent(bookId, isDirectory: true)
        if FileManager.default.fileExists(atPath: bookDir.appendingPathComponent("META-INF/container.xml").path) {
            return bookDir
        }
        try? FileManager.default.removeItem(at: bookDir)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        Zip.addCustomFileExtension(epubURL.pathExtension)
        try Zip.unzipFile(epubURL, destination: bookDir, overwrite: true, password: nil)
        return bookDir
    }

    nonisolated private static func locateOPF(in unzippedDir: URL) throws -> URL {
        let containerURL = unzippedDir.appendingPathComponent("META-INF/container.xml")
        let xml = try String(contentsOf: containerURL, encoding: .utf8)
        guard let fullPath = firstRegexCapture(in: xml, pattern: #"<rootfile\b[^>]*\bfull-path="([^"]+)""#),
            !fullPath.isEmpty
        else {
            throw LoadError(message: "This book's structure is missing a rootfile entry.")
        }
        return unzippedDir.appendingPathComponent(fullPath)
    }

    nonisolated private static func parseChapters(opfURL: URL, pageCharSize: Int) throws -> [TVEpubChapter] {
        let opfDir = opfURL.deletingLastPathComponent()
        let opfXML = try String(contentsOf: opfURL, encoding: .utf8)

        var hrefForId: [String: String] = [:]
        for match in allRegexMatches(in: opfXML, pattern: #"<item\b([^>]*)/?>"#) {
            let attrs = match
            guard let id = firstRegexCapture(in: attrs, pattern: #"\bid="([^"]+)""#),
                let href = firstRegexCapture(in: attrs, pattern: #"\bhref="([^"]+)""#)
            else { continue }
            hrefForId[id] = href
        }

        var spineOrder: [String] = []
        for match in allRegexMatches(in: opfXML, pattern: #"<itemref\b([^>]*)/?>"#) {
            if let idref = firstRegexCapture(in: match, pattern: #"\bidref="([^"]+)""#) {
                spineOrder.append(idref)
            }
        }

        var chapters: [TVEpubChapter] = []
        for (i, idref) in spineOrder.enumerated() {
            guard let href = hrefForId[idref] else { continue }
            let chapterURL = opfDir.appendingPathComponent(href)
            guard let html = try? String(contentsOf: chapterURL, encoding: .utf8) else { continue }
            let title = extractTitle(from: html, fallback: "Chapter \(chapters.count + 1)")
            let bodyText = extractPlainText(from: html)
            let pages = paginate(text: bodyText, pageCharSize: pageCharSize)
            guard !pages.isEmpty else { continue }
            chapters.append(TVEpubChapter(id: i, title: title, pages: pages))
        }
        return chapters
    }

    nonisolated private static func extractTitle(from html: String, fallback: String) -> String {
        for pattern in [#"<h1\b[^>]*>([\s\S]*?)</h1>"#, #"<h2\b[^>]*>([\s\S]*?)</h2>"#, #"<title\b[^>]*>([\s\S]*?)</title>"#] {
            if let raw = firstRegexCapture(in: html, pattern: pattern) {
                let text = decodeEntities(stripTags(raw)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return fallback
    }

    nonisolated private static func extractPlainText(from html: String) -> String {
        var s = html

        s = regexReplace(in: s, pattern: #"<script\b[^>]*>[\s\S]*?</script>"#, with: " ")
        s = regexReplace(in: s, pattern: #"<style\b[^>]*>[\s\S]*?</style>"#, with: " ")

        s = regexReplace(in: s, pattern: #"</(p|div|h[1-6]|li|blockquote|br)\s*>"#, with: "\n\n")
        s = regexReplace(in: s, pattern: #"<br\s*/?>"#, with: "\n")
        s = stripTags(s)
        s = decodeEntities(s)

        s = regexReplace(in: s, pattern: #"[ \t]+"#, with: " ")
        s = regexReplace(in: s, pattern: #"\n{3,}"#, with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func stripTags(_ s: String) -> String {
        regexReplace(in: s, pattern: #"<[^>]+>"#, with: "")
    }

    nonisolated private static func decodeEntities(_ s: String) -> String {
        var out = s
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "),
            ("&mdash;", "\u{2014}"), ("&ndash;", "\u{2013}"), ("&hellip;", "…"),
            ("&lsquo;", "‘"), ("&rsquo;", "’"), ("&ldquo;", "“"), ("&rdquo;", "”"),
        ]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }

        out = replaceMatches(in: out, pattern: #"&#(\d+);"#) { capture in
            guard let n = Int(capture), let scalar = Unicode.Scalar(n) else { return "" }
            return String(scalar)
        }
        out = replaceMatches(in: out, pattern: #"&#x([0-9A-Fa-f]+);"#) { capture in
            guard let n = Int(capture, radix: 16), let scalar = Unicode.Scalar(n) else { return "" }
            return String(scalar)
        }
        return out
    }

    nonisolated private static func paginate(text: String, pageCharSize: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let paragraphs =
            trimmed
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var pages: [String] = []
        var current = ""
        for p in paragraphs {
            if !current.isEmpty, current.count + p.count + 2 > pageCharSize {
                pages.append(current)
                current = ""
            }
            if p.count > pageCharSize {
                if !current.isEmpty { pages.append(current); current = "" }
                var chunk = ""
                for sentence in p.split(separator: ". ", omittingEmptySubsequences: true) {
                    let piece = String(sentence) + ". "
                    if chunk.count + piece.count > pageCharSize {
                        if !chunk.isEmpty { pages.append(chunk.trimmingCharacters(in: .whitespaces)); chunk = "" }
                    }
                    chunk += piece
                }
                if !chunk.isEmpty { current = chunk.trimmingCharacters(in: .whitespaces) }
            } else {
                if !current.isEmpty { current += "\n\n" }
                current += p
            }
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }

    nonisolated private static func firstRegexCapture(in source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: range),
            match.numberOfRanges >= 2,
            let captureRange = Range(match.range(at: 1), in: source)
        else { return nil }
        return String(source[captureRange])
    }

    nonisolated private static func allRegexMatches(in source: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, options: [], range: range).compactMap { match in
            guard let r = Range(match.range, in: source) else { return nil }
            return String(source[r])
        }
    }

    nonisolated private static func regexReplace(in source: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.stringByReplacingMatches(in: source, options: [], range: range, withTemplate: replacement)
    }

    nonisolated private static func replaceMatches(in source: String, pattern: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return source }
        let nsSource = source as NSString
        var result = ""
        var cursor = 0
        let range = NSRange(location: 0, length: nsSource.length)
        for match in regex.matches(in: source, options: [], range: range) {
            if match.range.location > cursor {
                result += nsSource.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            let captureRange = match.range(at: 1)
            let captured = captureRange.location == NSNotFound ? "" : nsSource.substring(with: captureRange)
            result += transform(captured)
            cursor = match.range.location + match.range.length
        }
        if cursor < nsSource.length {
            result += nsSource.substring(with: NSRange(location: cursor, length: nsSource.length - cursor))
        }
        return result
    }
}

enum TVEpubProgressStore {
    private static let keyPrefix = "enveTV.epubReader.progress."

    struct Position: Codable {
        let chapter: Int
        let page: Int
    }

    static func load(bookId: String) -> Position? {
        guard let data = UserDefaults.standard.data(forKey: keyPrefix + bookId) else { return nil }
        return try? JSONDecoder().decode(Position.self, from: data)
    }

    static func save(bookId: String, chapter: Int, page: Int) {
        let pos = Position(chapter: chapter, page: page)
        guard let data = try? JSONEncoder().encode(pos) else { return }
        UserDefaults.standard.set(data, forKey: keyPrefix + bookId)
    }
}
