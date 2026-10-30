#if !os(tvOS)
import Foundation
@preconcurrency import WebKit

nonisolated enum WebStoryImportError: LocalizedError {
    case invalidURL, unreadablePage, accessRequired, loadFailed, pageTooLarge, missingChapter, downloadFailed, unsupportedFile

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a complete http or https link without a username or password."
        case .unreadablePage: "No readable story or article was found. Open the page, then preview it again."
        case .accessRequired: "This site needs your attention. Open the page, complete any sign-in or verification, then preview it again."
        case .loadFailed: "The page couldn't be loaded. Check the link or open it in the browser."
        case .pageTooLarge: "This page is too large to import. Try a chapter link instead."
        case .missingChapter: "A chapter is no longer available at this address. The book hasn't been added."
        case .downloadFailed: "The book couldn't be downloaded. Check the link or open it in the browser."
        case .unsupportedFile: "This link doesn't contain a supported book file."
        }
    }
}

nonisolated struct WebStoryRemoteFile: Sendable {
    let url: URL
    let filename: String
}

nonisolated enum WebStoryPageResult: Sendable {
    case page(WebStoryPage)
    case file(WebStoryRemoteFile)
}

@MainActor
final class WebStoryPageLoader: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var onURLChange: ((URL?) -> Void)?
    private(set) var currentFile: WebStoryRemoteFile?

    private struct Pending {
        let id: UUID
        let navigation: WKNavigation?
        let continuation: CheckedContinuation<WebStoryPageResult, any Error>
    }

    private var pending: Pending?
    private var deadline: Task<Void, Never>?
    private var responseStatus: Int?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ url: URL) async throws -> WebStoryPageResult {
        cancel()
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let navigation = webView.load(URLRequest(url: url))
                pending = Pending(id: id, navigation: navigation, continuation: continuation)
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(35)) } catch { return }
                    self?.finish(id: id, result: .failure(WebStoryImportError.loadFailed))
                    self?.webView.stopLoading()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pending?.id == id else { return }
                self?.cancel()
            }
        }
    }

    func snapshot() async throws -> WebStoryPage {
        if let responseStatus, responseStatus >= 400 {
            if [401, 403, 429].contains(responseStatus) { throw WebStoryImportError.accessRequired }
            throw WebStoryImportError.loadFailed
        }
        let json: String = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(WebStoryExtraction.script, arguments: [:], in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value):
                    guard let json = value as? String else {
                        continuation.resume(throwing: WebStoryImportError.unreadablePage)
                        return
                    }
                    continuation.resume(returning: json)
                case .failure:
                    continuation.resume(throwing: WebStoryImportError.unreadablePage)
                }
            }
        }
        try Task.checkCancellation()
        guard json.utf8.count <= 4 * 1024 * 1024 else { throw WebStoryImportError.pageTooLarge }
        guard let page = try? JSONDecoder().decode(WebStoryPage.self, from: Data(json.utf8)) else {
            throw WebStoryImportError.unreadablePage
        }
        guard !page.html.isEmpty || !page.chapters.isEmpty else { throw WebStoryImportError.accessRequired }
        return page
    }

    func open(_ url: URL) {
        cancel()
        webView.load(URLRequest(url: url))
    }

    func cancel() {
        deadline?.cancel()
        deadline = nil
        let completion = pending?.continuation
        pending = nil
        webView.stopLoading()
        completion?.resume(throwing: CancellationError())
    }

    private func finish(id: UUID, result: Result<WebStoryPageResult, any Error>) {
        guard pending?.id == id else { return }
        let completion = pending?.continuation
        pending = nil
        deadline?.cancel()
        deadline = nil
        completion?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        currentFile = nil
        responseStatus = nil
        onURLChange?(webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onURLChange?(webView.url)
        guard let pending, navigation === pending.navigation else { return }
        Task {
            do { finish(id: pending.id, result: .success(.page(try await snapshot()))) }
            catch { finish(id: pending.id, result: .failure(error)) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard let pending, navigation === pending.navigation else { return }
        finish(id: pending.id, result: .failure(WebStoryImportError.loadFailed))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url,
            url.user == nil, url.password == nil,
            let scheme = url.scheme?.lowercased(), ["http", "https", "about"].contains(scheme)
        else { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame else { return .allow }
        let response = navigationResponse.response
        responseStatus = (response as? HTTPURLResponse)?.statusCode
        guard let url = response.url else { return .cancel }
        onURLChange?(url)
        if let response = response as? HTTPURLResponse, response.statusCode == 404 || response.statusCode == 410 {
            if let pending { finish(id: pending.id, result: .failure(WebStoryImportError.missingChapter)) }
            return .cancel
        }
        let type = response.mimeType?.lowercased() ?? ""
        if type.contains("html") || type == "text/plain" || type.isEmpty { return .allow }
        var filename = response.suggestedFilename ?? url.lastPathComponent
        if (filename as NSString).pathExtension.isEmpty,
            let format = EbookFormat.allCases.first(where: { $0.mimeType == type }) {
            filename += ".\(format.rawValue)"
        }
        let file = WebStoryRemoteFile(url: url, filename: filename)
        currentFile = file
        if let pending { finish(id: pending.id, result: .success(.file(file))) }
        return .cancel
    }
}
#endif
