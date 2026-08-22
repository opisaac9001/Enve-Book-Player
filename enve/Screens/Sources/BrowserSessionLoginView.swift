// AGENT-LOCKED
import Logging
import SwiftUI
import WebKit

struct BrowserSessionLoginView: View {
    let url: URL
    var onAuthenticated: ([String: String]) -> Void
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = true
    @State private var error: String?
    @State private var statusMessage = "Sign in, then tap Use Session."
    @State private var sessionHeaders: [String: String]?

    var body: some View {
        NavigationStack {
            ZStack {
                BrowserSessionWebView(
                    url: url,
                    onCookiesChanged: { sessionHeaders = $0 },
                    isLoading: $isLoading,
                    error: $error,
                    statusMessage: $statusMessage
                )
                .edgesIgnoringSafeArea(.bottom)

                VStack {
                    if isLoading || error != nil {
                        VStack(spacing: 10) {
                            if isLoading {
                                ProgressView()
                                    .tint(hearth.ember)
                                    .scaleEffect(1.1)
                            } else {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(hearth.statusWarn)
                            }

                            Text(error ?? statusMessage)
                                .font(.hearthUI(13))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(hearth.text)

                            if error != nil {
                                Text("The page did not finish loading. You can cancel and use service tokens or custom headers instead.")
                                    .font(.hearthUI(11))
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(hearth.textSecondary)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: 320)
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(hearth.bgElevated)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(hearth.hairline, lineWidth: 1)
                                }
                        }
                        .padding(.top, 20)
                    }

                    Spacer()
                }
            }
            .navigationTitle("Browser Sign-In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(hearth.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Session") {
                        guard let sessionHeaders else { return }
                        onAuthenticated(sessionHeaders)
                        dismiss()
                    }
                    .disabled(sessionHeaders == nil)
                }
            }
        }
    }
}

struct BrowserSessionWebView: UIViewRepresentable {
    let url: URL
    let onCookiesChanged: ([String: String]?) -> Void
    @Binding var isLoading: Bool
    @Binding var error: String?
    @Binding var statusMessage: String

    func makeUIView(context: Context) -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"

        let request = URLRequest(url: url)
        webView.load(request)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: BrowserSessionWebView
        private var pollingTask: Task<Void, Never>?
        private var loadingTimeoutTask: Task<Void, Never>?
        private var lastCookieHeader: String?

        init(_ parent: BrowserSessionWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            parent.error = nil
            parent.statusMessage = "Loading sign-in page..."
            startLoadingTimeout()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.isLoading = false
            parent.statusMessage = "Waiting for sign-in to complete..."
            startCookiePolling(webView: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.statusMessage = "Waiting for sign-in to complete..."
            loadingTimeoutTask?.cancel()

            startCookiePolling(webView: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.error = "Failed to load sign-in page: \(error.localizedDescription)"
            loadingTimeoutTask?.cancel()
            AppLogger.general.error("Provisional navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.error = "Failed to load sign-in page: \(error.localizedDescription)"
            loadingTimeoutTask?.cancel()
            AppLogger.general.error("Navigation failed: \(error.localizedDescription)")
        }

        private func startLoadingTimeout() {
            loadingTimeoutTask?.cancel()
            loadingTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self else { return }
                await MainActor.run {
                    if self.parent.isLoading {
                        self.parent.isLoading = false
                        self.parent.statusMessage =
                            "If the page appears below, continue signing in there. This screen closes automatically when session cookies are detected."
                    }
                }
            }
        }

        @MainActor
        private func getCookies(from webView: WKWebView) async -> [HTTPCookie] {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            return await withCheckedContinuation { continuation in
                store.getAllCookies { cookies in
                    continuation.resume(returning: cookies)
                }
            }
        }

        private func startCookiePolling(webView: WKWebView) {
            pollingTask?.cancel()
            pollingTask = Task { [weak self, weak webView] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)

                    guard let self = self, let webView = webView else { break }

                    let cookies = await self.getCookies(from: webView)

                    let headerValue = self.cookieHeaderValue(from: cookies)
                    guard headerValue != self.lastCookieHeader else { continue }
                    self.lastCookieHeader = headerValue

                    await MainActor.run {
                        self.parent.onCookiesChanged(headerValue.map { ["Cookie": $0] })
                    }
                }
            }
        }

        private func cookieHeaderValue(from cookies: [HTTPCookie]) -> String? {
            guard let host = parent.url.host?.lowercased() else {
                return nil
            }

            let matchingCookies = cookies.filter { cookie in
                guard cookie.expiresDate.map({ $0 > Date() }) ?? true else { return false }
                guard !cookie.isSecure || parent.url.scheme?.lowercased() == "https" else { return false }
                let domain = cookie.domain
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .lowercased()

                let matchesHost = domain.isEmpty || host == domain || host.hasSuffix(".\(domain)")
                let requestPath = parent.url.path.isEmpty ? "/" : parent.url.path
                return matchesHost && requestPath.hasPrefix(cookie.path)
            }

            let headerValue =
                matchingCookies
                .sorted { lhs, rhs in lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            return headerValue.isEmpty ? nil : headerValue
        }

        deinit {
            pollingTask?.cancel()
            loadingTimeoutTask?.cancel()
        }
    }
}
