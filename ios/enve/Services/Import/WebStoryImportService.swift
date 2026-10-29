#if !os(tvOS)
import Foundation
import Observation
@preconcurrency import WebKit

nonisolated struct WebStoryImportProgress: Sendable {
    let completedChapters: Int
    let totalChapters: Int
    let chapterTitle: String

    var fraction: Double { Double(completedChapters) / Double(max(1, totalChapters)) }
}

nonisolated struct WebStoryStaging: Sendable {
    let url: URL
    let directory: URL

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
@Observable
final class WebStoryImportService {
    private let loader: WebStoryPageLoader
    private let session: URLSession
    private var pages: [String: WebStoryPage] = [:]
    private var remoteFile: WebStoryRemoteFile?
    private(set) var progress: WebStoryImportProgress?
    private(set) var currentURL: URL?

    var webView: WKWebView { loader.webView }

    init(loader: WebStoryPageLoader = WebStoryPageLoader(), session: URLSession? = nil) {
        self.loader = loader
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 1800
            self.session = URLSession(configuration: configuration)
        }
        loader.onURLChange = { [weak self] url in self?.currentURL = url }
    }

    static func validatedURL(from text: String) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { throw WebStoryImportError.invalidURL }
        return url
    }

    func preview(url: URL) async throws -> WebStoryPreview {
        _ = try Self.validatedURL(from: url.absoluteString)
        pages.removeAll()
        remoteFile = nil
        if Self.supportsFile(url.lastPathComponent) {
            return try filePreview(WebStoryRemoteFile(url: url, filename: url.lastPathComponent))
        }
        switch try await loader.load(url) {
        case .page(let page): return try await preview(page: page)
        case .file(let file): return try filePreview(file)
        }
    }

    func previewCurrentPage() async throws -> WebStoryPreview {
        if let file = loader.currentFile { return try filePreview(file) }
        return try await preview(page: loader.snapshot())
    }

    private func filePreview(_ file: WebStoryRemoteFile) throws -> WebStoryPreview {
        guard Self.supportsFile(file.filename) else { throw WebStoryImportError.unsupportedFile }
        remoteFile = file
        let name = (file.filename as NSString).lastPathComponent
        let title = (name as NSString).deletingPathExtension
        return WebStoryPreview(
            title: title, author: nil, siteName: file.url.host ?? "", sourceURL: file.url,
            excerpt: "Save this book to your library for reading and listening.", wordCount: 0,
            chapters: [WebStoryChapter(title: title, url: file.url)], currentChapterIndex: 0,
            isStoryIndex: false, isDirectFile: true
        )
    }

    private static func supportsFile(_ filename: String) -> Bool {
        let extensionName = (filename as NSString).pathExtension.lowercased()
        return extensionName != "imagefolder" &&
            (EbookFormat.allExtensions.contains(extensionName) || EbookFormat.mobiExtensions.contains(extensionName))
    }

    private func preview(page: WebStoryPage) async throws -> WebStoryPreview {
        _ = try Self.validatedURL(from: page.url.absoluteString)
        pages[page.chapter.id] = page
        var index = page
        if page.chapters.isEmpty, let storyURL = page.storyURL, storyURL != page.url {
            do {
                if case .page(let story) = try await loader.load(storyURL),
                    story.url.host == page.url.host, story.url.scheme == page.url.scheme, story.url.port == page.url.port {
                    index = story
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
            }
        }
        let chapters = index.chapters.isEmpty ? [page.chapter] : index.chapters
        let current = chapters.firstIndex { $0.id == page.chapter.id } ?? 0
        let isIndex = !page.chapters.isEmpty && !page.url.path.contains("/chapter/")
        guard isIndex || !page.html.isEmpty else { throw WebStoryImportError.unreadablePage }
        return WebStoryPreview(
            title: index.chapters.isEmpty ? (page.storyTitle.isEmpty ? page.title : page.storyTitle) : index.storyTitle,
            author: page.author ?? index.author, siteName: page.siteName, sourceURL: page.storyURL ?? page.url,
            excerpt: page.excerpt, wordCount: page.wordCount, chapters: chapters,
            currentChapterIndex: current, isStoryIndex: isIndex, isDirectFile: false
        )
    }

    func stage(preview: WebStoryPreview, chapters: Range<Int>) async throws -> WebStoryStaging {
        guard !chapters.isEmpty, chapters.lowerBound >= 0, chapters.upperBound <= preview.chapters.count else {
            throw WebStoryImportError.missingChapter
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WebImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { progress = nil }
        do {
            if preview.isDirectFile {
                guard let file = remoteFile else { throw WebStoryImportError.downloadFailed }
                progress = WebStoryImportProgress(completedChapters: 0, totalChapters: 1, chapterTitle: preview.title)
                let (temporary, response) = try await session.download(from: file.url)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                    !(response.mimeType?.lowercased().contains("html") ?? false)
                else { throw WebStoryImportError.downloadFailed }
                try Task.checkCancellation()
                try ImportLimits.validateImportedMediaFile(temporary)
                let url = directory.appendingPathComponent((file.filename as NSString).lastPathComponent)
                try FileManager.default.moveItem(at: temporary, to: url)
                progress = WebStoryImportProgress(completedChapters: 1, totalChapters: 1, chapterTitle: preview.title)
                return WebStoryStaging(url: url, directory: directory)
            }
            let builder = try await WebStoryEPUBBuilder(directory: directory, preview: preview)
            for (completed, index) in chapters.enumerated() {
                try Task.checkCancellation()
                let chapter = preview.chapters[index]
                progress = WebStoryImportProgress(completedChapters: completed, totalChapters: chapters.count, chapterTitle: chapter.title)
                let page: WebStoryPage
                if let cached = pages[chapter.id] {
                    page = cached
                } else {
                    if completed > 0 { try await Task.sleep(for: .milliseconds(800)) }
                    guard case .page(let loaded) = try await loader.load(chapter.url), loaded.chapter.id == chapter.id else {
                        throw WebStoryImportError.missingChapter
                    }
                    page = loaded
                }
                guard !page.html.isEmpty else { throw WebStoryImportError.accessRequired }
                try await builder.append(page: page)
                progress = WebStoryImportProgress(completedChapters: completed + 1, totalChapters: chapters.count, chapterTitle: chapter.title)
            }
            try Task.checkCancellation()
            return WebStoryStaging(url: try await builder.finish(), directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func openInBrowser(_ url: URL) { loader.open(url) }
    func cancel() { loader.cancel() }
}
#endif
