import Foundation
import Logging
import WebKit

#if os(iOS)
import UIKit
#endif

@MainActor
final class CloudflareSilentRefreshService: NSObject {
    static let shared = CloudflareSilentRefreshService()
    private override init() { super.init() }

    private var inFlight: [String: Task<String?, Never>] = [:]
    private var retainedWebView: WKWebView?

    func refreshedCookieHeader(for serverURL: URL, timeout: TimeInterval = 15) async -> String? {
        guard let host = serverURL.host?.lowercased() else { return nil }
        if let existing = inFlight[host] { return await existing.value }

        let task = Task { [weak self] () -> String? in
            guard let self else { return nil }
            return await self.performRefresh(serverURL: serverURL, host: host, timeout: timeout)
        }
        inFlight[host] = task
        let result = await task.value
        inFlight[host] = nil
        return result
    }

    private func performRefresh(serverURL: URL, host: String, timeout: TimeInterval) async -> String? {
        let config = WKWebViewConfiguration()

        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: config)
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
        retainedWebView = webView

        #if os(iOS)

        if let window = Self.keyWindow {
            webView.alpha = 0.01
            webView.isUserInteractionEnabled = false
            window.addSubview(webView)
        }
        #endif
        defer {
            #if os(iOS)
            webView.removeFromSuperview()
            #endif
            retainedWebView = nil
        }

        webView.load(URLRequest(url: serverURL))

        let store = config.websiteDataStore.httpCookieStore
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 700_000_000)
            let cookies = await allCookies(from: store)
            if let header = Self.validCookieHeader(from: cookies, host: host) {
                AppLogger.network.info("[Cloudflare] Silently re-minted CF_Authorization for \(host)")
                return header
            }
        }
        AppLogger.network.warning("[Cloudflare] Silent CF_Authorization refresh timed out for \(host)")
        return nil
    }

    private func allCookies(from store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private static func validCookieHeader(from cookies: [HTTPCookie], host: String) -> String? {
        let matching = cookies.filter { cookie in
            let domain = cookie.domain
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            return domain.isEmpty || host == domain || host.hasSuffix(".\(domain)")
        }
        guard let cf = matching.first(where: { $0.name == "CF_Authorization" }) else { return nil }
        if let expires = cf.expiresDate, expires <= Date() { return nil }

        let header =
            matching
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        return header.isEmpty ? nil : header
    }

    #if os(iOS)
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
    #endif
}
