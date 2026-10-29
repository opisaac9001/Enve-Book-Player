import Foundation
import ReadiumZIPFoundation
import Testing
@preconcurrency import WebKit

@testable import enve

@MainActor
@Suite(.serialized)
struct WebStoryImportTests {
    @Test func linksRequireAnHTTPAddressWithoutEmbeddedCredentials() throws {
        let url = try WebStoryImportService.validatedURL(from: "  https://www.royalroad.com/fiction/42/story\n")
        #expect(url.host == "www.royalroad.com")
        for invalid in ["royalroad.com/fiction/42", "javascript:alert(1)", "file:///tmp/book.epub", "https://name:secret@example.com/book", "https:///", ""] {
            #expect(throws: WebStoryImportError.self) {
                try WebStoryImportService.validatedURL(from: invalid)
            }
        }
        #expect(try WebStoryImportService.validatedURL(from: "http://127.0.0.1:18767/story").port == 18767)
    }

    @Test func royalRoadExtractionKeepsVisibleProseAndTables() async throws {
        let page = try await extract("""
        <html lang="en"><head><title>Chapter &amp; Stars</title>
        <meta name="author" content="Enve Fixture Author">
        <style>.hidden-message { display: none; } .hidden-parent { visibility: hidden; }</style>
        </head><body>
        <a href="/fiction/999/unrelated">Unrelated recommendation</a>
        <a href="/fiction/42/stars">Stars &amp; Stories</a>
        <h1 class="chapter-title">Chapter &amp; Stars</h1>
        <div class="chapter-content">
          <p>A traveler reached the observatory. <strong>The sky was clear.</strong> Every window framed a different constellation.</p>
          <p class="hidden-message">HIDDEN COPYRIGHT TRAP</p>
          <div class="hidden-parent"><p>HIDDEN ANCESTOR TRAP</p></div>
          <p aria-hidden="true">HIDDEN ACCESSIBILITY TEXT</p>
          <div class="comments">COMMENT SECTION TRAP</div>
          <script>window.JSON.stringify = () => 'poison'; window.XMLSerializer = null;</script>
          <p onclick="alert(1)">A <a href="javascript:alert(1)">bad link</a> and a <a href="/fiction/42/stars">story link</a>.</p>
          <table><tr><th>Skill</th><th>Level</th></tr><tr><td>Navigation &amp; charts</td><td>7</td></tr></table>
          <img src="missing.png" alt="A star chart">
          <iframe src="about:blank"></iframe>
        </div></body></html>
        """, at: "https://www.royalroad.com/fiction/42/stars/chapter/101/chapter-stars")

        #expect(page.title == "Chapter & Stars")
        #expect(page.storyTitle == "Stars & Stories")
        #expect(page.author == "Enve Fixture Author")
        #expect(page.storyURL?.path == "/fiction/42/stars")
        #expect(page.siteName == "Royal Road")
        #expect(page.html.contains("<strong>The sky was clear.</strong>"))
        #expect(page.html.contains("<table>"))
        #expect(page.html.contains("Navigation &amp; charts"))
        #expect(page.html.contains("A star chart"))
        #expect(page.html.contains("https://www.royalroad.com/fiction/42/stars"))
        for removed in ["HIDDEN", "COMMENT SECTION", "onclick", "javascript:", "<script", "<iframe", "missing.png"] {
            #expect(!page.html.contains(removed), "Unexpected imported content: \(removed)")
        }
        #expect(XMLParser(data: Data(page.html.utf8)).parse())
    }

    @Test func chapterListPreservesOrderAndRejectsUnrelatedLinks() async throws {
        let page = try await extract("""
        <html><head><meta name="description" content="A fictional story used to test chapter import."></head><body>
        <div class="fic-title"><h1>The Test Story</h1><h4><a href="/profile/1">Fixture Author</a></h4></div>
        <table id="chapters">
          <tr><td><a href="/fiction/42/story/chapter/102/the-beginning">The beginning</a></td></tr>
          <tr><td><a href="/fiction/chapter/102#duplicate">Duplicate mobile link</a></td></tr>
          <tr><td><a href="/fiction/42/story/chapter/101/afterward">Afterward</a></td></tr>
          <tr><td><a href="https://elsewhere.example/chapter/103">External chapter</a></td></tr>
          <tr><td><a href="/fiction/99/other/chapter/104">Other story</a></td></tr>
        </table>
        <ul class="pagination-small"><li class="page-active"><a>1</a></li><li><a id="second">2</a></li><li class="nav-arrow"><a id="next"><i class="fa-chevron-right"></i></a></li></ul>
        <script>
        const table = document.querySelector('#chapters');
        const secondPage = table.querySelector('tr:nth-child(3)');
        secondPage.remove();
        const showSecondPage = () => {
            table.replaceChildren(secondPage);
            document.querySelector('.page-active').className = '';
            document.querySelector('#second').parentElement.className = 'page-active';
            document.querySelector('.nav-arrow').remove();
        };
        document.querySelector('#next').addEventListener('click', showSecondPage);
        document.querySelector('#second').addEventListener('click', showSecondPage);
        </script></body></html>
        """, at: "https://www.royalroad.com/fiction/42/story")

        #expect(page.chapters.map(\.title) == ["The beginning", "Afterward"])
        #expect(page.chapters.map(\.id) == ["www.royalroad.com:/chapter/102", "www.royalroad.com:/chapter/101"])
        #expect(page.title == "The Test Story")
        #expect(page.author == "Fixture Author")
        #expect(page.excerpt == "A fictional story used to test chapter import.")
        #expect(page.html.isEmpty)
    }

    @Test func genericArticleDropsNavigationAndRetainsFormatting() async throws {
        let page = try await extract("""
        <html><head><meta name="author" content="Fixture Writer"></head><body>
        <nav>MENU TRAP</nav><h1>A useful article</h1>
        <article><h1>A useful article</h1><p>This article has enough visible prose to become an offline book. Its formatting should survive the import.</p>
        <h2>Second section</h2><ol start="3"><li>A useful point</li><li>Another useful point</li></ol>
        <pre>let stars = 3;\nprint(stars)</pre><aside>SIDEBAR TRAP</aside><footer>FOOTER TRAP</footer></article>
        </body></html>
        """, at: "https://example.com/article")

        #expect(page.title == "A useful article")
        #expect(page.html.contains("<h2>Second section</h2>"))
        #expect(page.html.contains("<ol start=\"3\">"))
        #expect(page.html.contains("let stars = 3;\nprint(stars)"))
        #expect(!page.html.contains("TRAP"))
        #expect(!page.html.contains("<h1>"))
        #expect(page.wordCount > 20)
    }

    @Test func epubRetainsChapterOrderMetadataAndWellFormedText() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let chapters = [
            WebStoryChapter(title: "Chapter 2 & Arrival", url: URL(string: "https://example.com/chapter/22")!),
            WebStoryChapter(title: "Chapter 3: <Stars>", url: URL(string: "https://example.com/chapter/23")!),
        ]
        let preview = preview(chapters: chapters, current: 0)
        let builder = try await WebStoryEPUBBuilder(directory: root, preview: preview)
        for chapter in chapters {
            try await builder.append(page: WebStoryPage(
                url: chapter.url, title: chapter.title, storyTitle: preview.title,
                author: preview.author, siteName: preview.siteName, language: "en", excerpt: "An excerpt.",
                html: "<div xmlns=\"http://www.w3.org/1999/xhtml\"><p>The traveler opened the atlas &amp; read its charts.</p></div>",
                wordCount: 12, storyURL: preview.sourceURL, chapters: []
            ))
        }
        let url = try await builder.finish()
        let data = try Data(contentsOf: url)
        #expect(String(data: data.subdata(in: 30..<38), encoding: .utf8) == "mimetype")
        #expect(data[8] == 0 && data[9] == 0)
        let expanded = root.appendingPathComponent("expanded", isDirectory: true)
        try await ImportLimits.extractArchive(url, to: expanded)
        let nav = try String(contentsOf: expanded.appendingPathComponent("OEBPS/nav.xhtml"), encoding: .utf8)
        let first = try #require(nav.range(of: "Chapter 2 &amp; Arrival"))
        let second = try #require(nav.range(of: "Chapter 3: &lt;Stars&gt;"))
        #expect(first.lowerBound < second.lowerBound)
        for path in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/toc.ncx", "OEBPS/Text/chapter-1.xhtml", "OEBPS/Text/chapter-2.xhtml"] {
            let content = try Data(contentsOf: expanded.appendingPathComponent(path))
            #expect(XMLParser(data: content).parse(), "Malformed EPUB document: \(path)")
        }
        let importer = try LocalEbookImporter(storage: ProfileStorageLocations(
            profileID: FamilyProfile.ownerID,
            documentsDirectory: root.appendingPathComponent("documents"),
            applicationSupportDirectory: root.appendingPathComponent("support"),
            cachesDirectory: root.appendingPathComponent("caches")
        ))
        let metadata = try await importer.extractMetadata(from: url)
        #expect(metadata.title == "Stars & Stories")
        #expect(metadata.author == "Enve Fixture Author")
    }

    @Test func chapterSelectionStartsAtThePastedChapter() {
        let model = SourcesWebImportModel()
        let chapters = (0..<4).map { WebStoryChapter(title: "Chapter \($0)", url: URL(string: "https://example.com/chapter/\($0)")!) }
        model.accept(preview(chapters: chapters, current: 2))
        #expect(model.scope == .chapter)
        #expect(model.chapters(for: .chapter) == 2..<3)
        #expect(model.chapters(for: .fromHere) == 2..<4)
        #expect(model.chapters(for: .whole) == 0..<4)
        model.accept(preview(chapters: chapters, current: 0, isIndex: true))
        #expect(model.scope == .whole)
        #expect(model.availableScopes == [.chapter, .whole])
        model.urlText = "https://example.com/another-story"
        #expect(model.preview == nil)
    }

    @Test func cancellationDoesNotLeaveAPartialBook() async throws {
        let service = WebStoryImportService()
        let preview = try await service.preview(url: URL(string: "http://127.0.0.1:9/cancelled.epub")!)
        let before = try stagingDirectories()
        let task = Task { try await service.stage(preview: preview, chapters: 0..<1) }
        task.cancel()
        do {
            let staged = try await task.value
            staged.remove()
            Issue.record("A cancelled import completed")
        } catch {
            #expect(SourcesWebImportModel.isCancellation(error))
        }
        #expect(try stagingDirectories() == before)
        #expect(service.progress == nil)
    }

    private func extract(_ html: String, at address: String) async throws -> WebStoryPage {
        let loader = WebStoryPageLoader()
        let navigation = WebStoryFixtureNavigation()
        loader.webView.navigationDelegate = navigation
        try await navigation.load(html, baseURL: URL(string: address)!, webView: loader.webView)
        loader.webView.navigationDelegate = loader
        return try await loader.snapshot()
    }

    private func preview(chapters: [WebStoryChapter], current: Int, isIndex: Bool = false) -> WebStoryPreview {
        WebStoryPreview(
            title: "Stars & Stories", author: "Enve Fixture Author", siteName: "Fixture",
            sourceURL: URL(string: "https://example.com/story")!, excerpt: "A test story.", wordCount: 50,
            chapters: chapters, currentChapterIndex: current, isStoryIndex: isIndex, isDirectFile: false
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WebStoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func stagingDirectories() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("WebImport-") })
    }
}

@MainActor
private final class WebStoryFixtureNavigation: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?

    func load(_ html: String, baseURL: URL, webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
}
