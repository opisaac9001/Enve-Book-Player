// AGENT-LOCKED
import SwiftUI
import WebKit

struct KomgaOAuthProvider: Decodable, Hashable, Identifiable, Sendable {
    let name: String
    let registrationId: String

    var id: String { registrationId }
}

struct KomgaOAuthSession: Sendable {
    let provider: KomgaOAuthProvider
    let username: String?
    let cookieHeader: String
}

enum KomgaOAuthLoginError: LocalizedError {
    case noProviders
    case presentationUnavailable
    case userCancelled

    var errorDescription: String? {
        switch self {
        case .noProviders:
            return "Single sign-on is not enabled on this Komga server."
        case .presentationUnavailable:
            return "Enve couldn't open the Komga sign-in window."
        case .userCancelled:
            return "Sign-in was cancelled."
        }
    }
}

struct KomgaOAuthLoginView: View {
    let serverURL: URL
    let providers: [KomgaOAuthProvider]
    let preferredProviderId: String?
    let existingCookieHeader: String?
    let verifySession: (String) async throws -> String?
    let onCompletion: (Result<KomgaOAuthSession, Error>) -> Void

    @Environment(\.hearth) private var hearth

    @State private var selectedProvider: KomgaOAuthProvider?
    @State private var capturedCookieHeader: String?
    @State private var attemptId = UUID()
    @State private var isVerifying = false
    @State private var errorMessage: String?
    @State private var didComplete = false

    init(
        serverURL: URL,
        providers: [KomgaOAuthProvider],
        preferredProviderId: String?,
        existingCookieHeader: String?,
        verifySession: @escaping (String) async throws -> String?,
        onCompletion: @escaping (Result<KomgaOAuthSession, Error>) -> Void
    ) {
        self.serverURL = serverURL
        self.providers = providers
        self.preferredProviderId = preferredProviderId
        self.existingCookieHeader = existingCookieHeader
        self.verifySession = verifySession
        self.onCompletion = onCompletion

        let preferred = preferredProviderId.flatMap { id in
            providers.first { $0.registrationId == id }
        }
        _selectedProvider = State(initialValue: preferred ?? (providers.count == 1 ? providers[0] : nil))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let selectedProvider {
                    authenticationContent(for: selectedProvider)
                } else {
                    providerPicker
                }
            }
            .background(HearthBackground())
            .navigationTitle(selectedProvider == nil ? "Choose sign-in" : "Komga Sign-In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        finish(.failure(KomgaOAuthLoginError.userCancelled))
                    }
                    .foregroundStyle(hearth.textSecondary)
                }
            }
        }
        .task(id: capturedCookieHeader) {
            guard let capturedCookieHeader, let selectedProvider, !didComplete else { return }
            isVerifying = true
            errorMessage = nil
            do {
                let username = try await verifySession(capturedCookieHeader)
                finish(
                    .success(
                        KomgaOAuthSession(
                            provider: selectedProvider,
                            username: username,
                            cookieHeader: capturedCookieHeader
                        )
                    )
                )
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
                isVerifying = false
            }
        }
    }

    private var providerPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Overline("Single sign-on")
                    Text("Choose the account provider configured by your Komga administrator.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }

                ForEach(providers) { provider in
                    Button {
                        begin(provider)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .font(.hearthUI(20, weight: .semibold))
                                .foregroundStyle(hearth.ember)
                                .frame(width: 32)
                            Text(provider.name)
                                .font(.hearthBody.weight(.medium))
                                .foregroundStyle(hearth.text)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.hearthUI(12, weight: .semibold))
                                .foregroundStyle(hearth.textTertiary)
                        }
                        .padding(16)
                        .background(hearth.bgElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(hearth.hairline, lineWidth: 1)
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Continue with \(provider.name)")
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func authenticationContent(for provider: KomgaOAuthProvider) -> some View {
        if let authorizationURL = authorizationURL(for: provider) {
            ZStack(alignment: .top) {
                KomgaOAuthWebView(
                    serverURL: serverURL,
                    authorizationURL: authorizationURL,
                    existingCookieHeader: existingCookieHeader,
                    onCookieHeader: { capturedCookieHeader = $0 },
                    onError: { errorMessage = $0 }
                )
                .id(attemptId)
                .ignoresSafeArea(edges: .bottom)

                if isVerifying || errorMessage != nil {
                    statusCard
                        .padding(16)
                }
            }
        } else {
            SourcesErrorText(message: "Komga returned an invalid single sign-on provider.")
                .padding(24)
        }
    }

    private var statusCard: some View {
        VStack(spacing: 10) {
            if isVerifying {
                ProgressView()
                    .tint(hearth.ember)
                Text("Finishing your Komga sign-in…")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            } else if let errorMessage {
                SourcesErrorText(message: errorMessage)
                HStack(spacing: 10) {
                    QuietButton(title: "Try again", systemImage: "arrow.clockwise") {
                        restart()
                    }
                    if providers.count > 1 {
                        QuietButton(title: "Other provider", systemImage: "person.2") {
                            selectedProvider = nil
                            capturedCookieHeader = nil
                            self.errorMessage = nil
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 360)
        .background(hearth.bgElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(hearth.hairline, lineWidth: 1)
        }
    }

    private func authorizationURL(for provider: KomgaOAuthProvider) -> URL? {
        let base = serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let registrationId = provider.registrationId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        return registrationId.flatMap { URL(string: "\(base)/oauth2/authorization/\($0)") }
    }

    private func begin(_ provider: KomgaOAuthProvider) {
        selectedProvider = provider
        restart()
    }

    private func restart() {
        capturedCookieHeader = nil
        errorMessage = nil
        isVerifying = false
        attemptId = UUID()
    }

    private func finish(_ result: Result<KomgaOAuthSession, Error>) {
        guard !didComplete else { return }
        didComplete = true
        onCompletion(result)
    }
}

private struct KomgaOAuthWebView: UIViewRepresentable {
    let serverURL: URL
    let authorizationURL: URL
    let existingCookieHeader: String?
    let onCookieHeader: (String) -> Void
    let onError: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
        context.coordinator.prepareAndLoad(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: KomgaOAuthWebView
        private var completedOAuthRoundTrip = false
        private var lastCookieHeader: String?

        init(parent: KomgaOAuthWebView) {
            self.parent = parent
        }

        func prepareAndLoad(_ webView: WKWebView) {
            let cookies = seedCookies()
            set(cookies, at: 0, in: webView.configuration.websiteDataStore.httpCookieStore) { [weak self, weak webView] in
                guard let self, let webView else { return }
                var request = URLRequest(url: self.parent.authorizationURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let cookieHeader =
                    cookies
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                if !cookieHeader.isEmpty {
                    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                }
                webView.load(request)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            inspect(webView.url, webView: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            inspect(webView.url, webView: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            inspect(webView.url, webView: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.onError("Komga sign-in failed to load: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.onError("Komga sign-in failed: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                let scheme = url.scheme?.lowercased(),
                scheme != "http",
                scheme != "https"
            else {
                decisionHandler(.allow)
                return
            }

            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let method = challenge.protectionSpace.authenticationMethod
            let host = challenge.protectionSpace.host

            if method == NSURLAuthenticationMethodClientCertificate,
                let identity = NetworkHostUtils.findMTLSIdentity(forHost: host)
            {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
                return
            }

            if method == NSURLAuthenticationMethodServerTrust,
                NetworkHostUtils.isLocalNetworkHost(host),
                let trust = challenge.protectionSpace.serverTrust
            {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }

            completionHandler(.performDefaultHandling, nil)
        }

        private func inspect(_ url: URL?, webView: WKWebView) {
            guard let url else { return }

            if isOAuthCallback(url) || !isSameOrigin(url) || isKomgaSuccessRedirect(url) {
                completedOAuthRoundTrip = true
            }

            if let error = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "error" })?
                .value,
                isSameOrigin(url)
            {
                parent.onError("Komga sign-in failed: \(error)")
            }

            guard completedOAuthRoundTrip,
                isSameOrigin(url),
                !isAuthorizationStart(url),
                !isOAuthCallback(url)
            else {
                return
            }

            captureCookies(from: webView)
        }

        private func captureCookies(from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let matching = cookies.filter(self.cookieMatchesServer)
                guard matching.contains(where: { $0.name.caseInsensitiveCompare("KOMGA-SESSION") == .orderedSame }) else {
                    return
                }

                let header =
                    matching
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                guard !header.isEmpty, header != self.lastCookieHeader else { return }
                self.lastCookieHeader = header
                self.parent.onCookieHeader(header)
            }
        }

        private func cookieMatchesServer(_ cookie: HTTPCookie) -> Bool {
            guard let host = parent.serverURL.host?.lowercased() else { return false }
            guard cookie.expiresDate.map({ $0 > Date() }) ?? true else { return false }
            guard !cookie.isSecure || parent.serverURL.scheme?.lowercased() == "https" else { return false }

            let domain = cookie.domain
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            guard domain.isEmpty || host == domain || host.hasSuffix(".\(domain)") else { return false }

            let serverPath = parent.serverURL.path.isEmpty ? "/" : parent.serverURL.path
            return serverPath.hasPrefix(cookie.path)
        }

        private func isSameOrigin(_ url: URL) -> Bool {
            url.scheme?.caseInsensitiveCompare(parent.serverURL.scheme ?? "") == .orderedSame
                && url.host?.caseInsensitiveCompare(parent.serverURL.host ?? "") == .orderedSame
                && effectivePort(url) == effectivePort(parent.serverURL)
        }

        private func effectivePort(_ url: URL) -> Int {
            url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        }

        private func isAuthorizationStart(_ url: URL) -> Bool {
            url.path.lowercased().contains("/oauth2/authorization/")
        }

        private func isOAuthCallback(_ url: URL) -> Bool {
            url.path.lowercased().contains("/login/oauth2/code/")
        }

        private func isKomgaSuccessRedirect(_ url: URL) -> Bool {
            guard isSameOrigin(url) else { return false }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .contains { $0.name == "server_redirect" && $0.value == "Y" } == true
        }

        private func seedCookies() -> [HTTPCookie] {
            guard let header = parent.existingCookieHeader,
                let host = parent.serverURL.host
            else {
                return []
            }

            let path = parent.serverURL.path.isEmpty ? "/" : parent.serverURL.path
            return header.split(separator: ";").compactMap { pair in
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }

                let name = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedName = name.uppercased()
                guard normalizedName != "KOMGA-SESSION",
                    normalizedName != "SESSION",
                    normalizedName != "JSESSIONID"
                else {
                    return nil
                }

                var properties: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .domain: host,
                    .path: path,
                ]
                if parent.serverURL.scheme?.lowercased() == "https" {
                    properties[.secure] = "TRUE"
                }
                return HTTPCookie(properties: properties)
            }
        }

        private func set(
            _ cookies: [HTTPCookie],
            at index: Int,
            in store: WKHTTPCookieStore,
            completion: @escaping @MainActor () -> Void
        ) {
            guard index < cookies.count else {
                completion()
                return
            }
            store.setCookie(cookies[index]) { [weak self] in
                guard let self else { return }
                self.set(cookies, at: index + 1, in: store, completion: completion)
            }
        }
    }
}
