import SwiftUI
import CoreText
import UIKit
import Zip

struct EbookReaderView_tvOS: View {
    @Environment(\.hearth) private var hearth
    let book: Book

    @Environment(\.dismiss) private var dismiss

    @State private var chapters: [TVEpubChapter] = []
    @State private var chapterIndex = 0
    @State private var pageIndex = 0
    @State private var pageOffset = 0
    @State private var fittedPages: [TVEpubPage] = []
    @State private var readingSize: CGSize = .zero
    @State private var loadState: LoadState = .loading
    @State private var fontSize: CGFloat = 32

    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    var body: some View {
        ZStack {
            hearth.bgSunken.ignoresSafeArea()
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
        .onChange(of: chapterIndex) { _, _ in fitPages() }
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
                Text("Preparing book…").font(.title3).foregroundStyle(hearth.textSecondary)
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
                .foregroundStyle(hearth.ember)
            Text("Can't open this book")
                .font(.title.weight(.bold))
                .foregroundStyle(hearth.text)
            Text(message)
                .font(.title3)
                .foregroundStyle(hearth.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 800)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 24)
        }
    }

    private var readerBody: some View {
        let chapter = chapters[chapterIndex]
        let fittedIndex = TVEpubPagination.pageIndex(in: fittedPages, sourcePage: pageIndex, offset: pageOffset)

        return VStack(alignment: .leading, spacing: 28) {
            Text(chapter.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(hearth.textSecondary)
                .lineLimit(1)

            GeometryReader { geometry in
                TVEpubPageSurface(page: fittedPages.indices.contains(fittedIndex) ? fittedPages[fittedIndex] : nil)
                    .onChange(of: geometry.size, initial: true) { _, size in
                        readingSize = size
                        fitPages()
                    }
            }

            HStack {
                Text("Chapter \(chapterIndex + 1) of \(chapters.count)  ·  Page \(fittedIndex + 1) of \(max(fittedPages.count, 1))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(hearth.textSecondary)
                Spacer()
                Text("◂ / ▸ to turn pages")
                    .font(.callout)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
        .padding(80)
    }

    private func fitPages() {
        guard chapters.indices.contains(chapterIndex) else { return }
        let descriptor = UIFont.systemFont(ofSize: fontSize).fontDescriptor.withDesign(.serif)!
        let font = UIFont(descriptor: descriptor, size: fontSize)
        fittedPages = TVEpubPagination.pages(
            chapters[chapterIndex].pages,
            size: readingSize,
            font: CTFontCreateWithName(font.fontName as CFString, fontSize, nil),
            lineSpacing: 14
        )
        let index = TVEpubPagination.pageIndex(in: fittedPages, sourcePage: pageIndex, offset: pageOffset)
        if fittedPages.indices.contains(index) { selectPage(fittedPages[index]) }
    }

    private func selectPage(_ page: TVEpubPage) {
        pageIndex = page.sourcePage
        pageOffset = page.range.location
    }

    private func turnForward() {
        guard !fittedPages.isEmpty else { return }
        let index = TVEpubPagination.pageIndex(in: fittedPages, sourcePage: pageIndex, offset: pageOffset)
        if index + 1 < fittedPages.count {
            selectPage(fittedPages[index + 1])
        } else if chapterIndex + 1 < chapters.count {
            chapterIndex += 1
            pageIndex = 0
            pageOffset = 0
        }
        saveProgress()
    }

    private func turnBack() {
        guard !fittedPages.isEmpty else { return }
        let index = TVEpubPagination.pageIndex(in: fittedPages, sourcePage: pageIndex, offset: pageOffset)
        if index > 0 {
            selectPage(fittedPages[index - 1])
        } else if chapterIndex > 0 {
            chapterIndex -= 1
            pageIndex = max(0, chapters[chapterIndex].pages.count - 1)
            pageOffset = Int.max
            fitPages()
        }
        saveProgress()
    }

    private func load() async {
        do {
            let (loaded, sourceChanged) = try await TVEpubLoader.load(book: book)
            await MainActor.run {
                self.chapters = loaded
                if let saved = TVEpubProgressStore.load(bookId: book.stableId),
                    loaded.indices.contains(saved.chapter)
                {
                    self.chapterIndex = saved.chapter
                    // Page and character offsets index the previous revision's text.
                    if !sourceChanged {
                        self.pageIndex = min(saved.page, max(0, loaded[saved.chapter].pages.count - 1))
                        self.pageOffset = saved.offset ?? 0
                    }
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
        TVEpubProgressStore.save(bookId: book.stableId, chapter: chapterIndex, page: pageIndex, offset: pageOffset)
    }
}

private struct TVEpubPageSurface: UIViewRepresentable {
    let page: TVEpubPage?
    @Environment(\.hearth) private var hearth

    func makeUIView(context: Context) -> TVEpubTextSurface {
        TVEpubTextSurface()
    }

    func updateUIView(_ view: TVEpubTextSurface, context: Context) {
        view.textColor = UIColor(hearth.text)
        view.page = page
    }
}

private final class TVEpubTextSurface: UIView {
    var textColor: UIColor = .label {
        didSet { setNeedsDisplay() }
    }

    var page: TVEpubPage? {
        didSet {
            accessibilityLabel = page?.text
            setNeedsDisplay()
        }
    }

    init() {
        super.init(frame: .zero)
        isOpaque = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let frame = page?.frame, let context = UIGraphicsGetCurrentContext() else { return }
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(textColor.cgColor)
        CTFrameDraw(frame, context)
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
    static func load(book: Book, pageCharSize: Int = 1800) async throws -> (chapters: [TVEpubChapter], sourceChanged: Bool) {
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
        Zip.addCustomFileExtension(epubURL.pathExtension)
        let bookId = book.stableId

        return try await Task.detached(priority: .userInitiated) {
            let (root, sourceChanged) = try unzipIfNeeded(epubURL: epubURL, bookId: bookId)
            return (try parseChapters(in: root, pageCharSize: pageCharSize), sourceChanged)
        }.value
    }

    nonisolated private static func unzipIfNeeded(epubURL: URL, bookId: String) throws -> (root: URL, sourceChanged: Bool) {
        let cacheRoot = URL.cachesDirectory.appendingPathComponent("EnveTV/epub", isDirectory: true)
        let bookDir = cacheRoot.appendingPathComponent(bookId, isDirectory: true)
        let values = try epubURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fingerprint = "\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let cachedFingerprint = try? String(contentsOf: bookDir.appendingPathComponent(".source-fingerprint"), encoding: .utf8)
        if cachedFingerprint == fingerprint,
            FileManager.default.fileExists(atPath: bookDir.appendingPathComponent("META-INF/container.xml").path)
        { return (bookDir, false) }
        let staging = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try Zip.unzipFile(epubURL, destination: staging, overwrite: true, password: nil)
        try fingerprint.write(to: staging.appendingPathComponent(".source-fingerprint"), atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: bookDir.path) { try FileManager.default.removeItem(at: bookDir) }
        try FileManager.default.moveItem(at: staging, to: bookDir)
        // Extractions cached before fingerprinting have no recorded source, so their offsets are kept.
        return (bookDir, cachedFingerprint != nil)
    }

    nonisolated private static func parseChapters(in root: URL, pageCharSize: Int) throws -> [TVEpubChapter] {
        let container = TVStorytellerPackageParser()
        guard container.parse(try Data(contentsOf: root.appendingPathComponent("META-INF/container.xml"))),
            let rootfile = container.rootfile, !rootfile.isEmpty
        else {
            throw LoadError(message: "This book's structure is missing a rootfile entry.")
        }
        let opfHref = TVStorytellerPaths.normalizeHref(rootfile)
        let package = TVStorytellerPackageParser()
        guard package.parse(try Data(contentsOf: root.appendingPathComponent(opfHref))) else {
            throw LoadError(message: "This book's package document could not be read.")
        }

        var chapters: [TVEpubChapter] = []
        for (i, idref) in package.spine.enumerated() {
            guard let item = package.items[idref] else { continue }
            let chapterURL = root.appendingPathComponent(TVStorytellerPaths.resolve(item.href, relativeTo: opfHref))
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
        let offset: Int?
    }

    static func load(bookId: String) -> Position? {
        guard let data = UserDefaults.standard.data(forKey: keyPrefix + bookId) else { return nil }
        return try? JSONDecoder().decode(Position.self, from: data)
    }

    static func save(bookId: String, chapter: Int, page: Int, offset: Int) {
        let pos = Position(chapter: chapter, page: page, offset: offset)
        guard let data = try? JSONEncoder().encode(pos) else { return }
        UserDefaults.standard.set(data, forKey: keyPrefix + bookId)
    }
}
