// AGENT-LOCKED
import SwiftUI
import UIKit

final class KomgaLoginDelegate: UnifiedLoginDelegate {
    private let appState: AppState
    private let validatedLogin: ValidatedConnectionLoginDelegate

    init(appState: AppState) {
        self.appState = appState
        self.validatedLogin = ValidatedConnectionLoginDelegate(
            appState: appState,
            providerType: .komga,
            defaultName: "Komga"
        )
    }

    func authenticate(
        serverURL: String,
        username: String,
        password: String,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection {
        try await validatedLogin.authenticate(
            serverURL: serverURL,
            username: username,
            password: password,
            customHeaders: customHeaders
        )
    }

    func authenticateWithToken(
        serverURL: String,
        token: String,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection {
        try await validatedLogin.authenticateWithToken(
            serverURL: serverURL,
            token: token,
            customHeaders: customHeaders
        )
    }

    func authenticateWithOIDC(
        serverURL: String,
        redirectURIOverride: String?,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection {
        try await authenticateWithOIDC(
            serverURL: serverURL,
            preferredProviderId: nil,
            customHeaders: customHeaders
        )
    }

    func authenticateWithOIDC(
        serverURL: String,
        preferredProviderId: String?,
        customHeaders: [String: String]?
    ) async throws -> ServerConnection {
        let normalizedURL = normalize(serverURL)
        guard let url = URL(string: normalizedURL) else {
            throw ProviderError.invalidURL
        }

        let providers = try await fetchOAuthProviders(serverURL: normalizedURL, customHeaders: customHeaders)
        guard !providers.isEmpty else {
            throw KomgaOAuthLoginError.noProviders
        }

        let session = try await presentOAuthLogin(
            serverURL: url,
            providers: providers,
            preferredProviderId: preferredProviderId,
            customHeaders: customHeaders
        )

        var sessionHeaders = customHeaders ?? [:]
        ServerConnection.setHeaderValue(session.cookieHeader, for: "Cookie", in: &sessionHeaders)

        let temporaryConnection = ServerConnection(
            name: "Komga",
            url: normalizedURL,
            type: .komga,
            username: session.username,
            isConnected: false,
            customHeaders: sessionHeaders,
            authMode: .sso,
            komgaOAuthProviderId: session.provider.registrationId
        )
        let (isValid, validatedConnection) = try await appState.validateConnection(temporaryConnection)
        guard isValid else {
            throw ProviderError.unauthorized
        }

        var finalConnection = validatedConnection
        finalConnection.isConnected = true
        finalConnection.lastVerified = Date()
        return finalConnection
    }

    func fetchLibraries(connection: ServerConnection) async throws -> [LibraryMetadata] {
        try await validatedLogin.fetchLibraries(connection: connection)
    }

    private func fetchOAuthProviders(
        serverURL: String,
        customHeaders: [String: String]?
    ) async throws -> [KomgaOAuthProvider] {
        guard let url = URL(string: "\(serverURL)/api/v1/oauth2/providers") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in customHeaders ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await InsecureURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw OAuthError.authorizationFailed("Komga couldn't provide its single sign-on options (HTTP \(http.statusCode)).")
        }

        return try JSONDecoder().decode([KomgaOAuthProvider].self, from: data)
    }

    private func verifySession(
        serverURL: URL,
        cookieHeader: String,
        customHeaders: [String: String]?
    ) async throws -> String? {
        let base = serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let profileURL = URL(string: "\(base)/api/v2/users/me") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: profileURL)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in customHeaders ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await InsecureURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ProviderError.unauthorized
            }
            throw ProviderError.serverError("Komga session verification failed (HTTP \(http.statusCode))")
        }

        let profile = try JSONDecoder().decode(KomgaOAuthUserProfile.self, from: data)
        return profile.email ?? profile.username
    }

    @MainActor
    private func presentOAuthLogin(
        serverURL: URL,
        providers: [KomgaOAuthProvider],
        preferredProviderId: String?,
        customHeaders: [String: String]?
    ) async throws -> KomgaOAuthSession {
        guard let presenter = Self.activeViewController() else {
            throw KomgaOAuthLoginError.presentationUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let box = KomgaOAuthPresentationBox()
            let existingCookie = ServerConnection.headerValue(in: customHeaders, for: "Cookie")
            let content = KomgaOAuthLoginView(
                serverURL: serverURL,
                providers: providers,
                preferredProviderId: preferredProviderId,
                existingCookieHeader: existingCookie,
                verifySession: { [weak self] cookieHeader in
                    guard let self else { throw CancellationError() }
                    return try await self.verifySession(
                        serverURL: serverURL,
                        cookieHeader: cookieHeader,
                        customHeaders: customHeaders
                    )
                },
                onCompletion: { result in
                    guard !box.didFinish else { return }
                    box.didFinish = true
                    if let controller = box.controller {
                        controller.dismiss(animated: true) {
                            continuation.resume(with: result)
                        }
                    } else {
                        continuation.resume(with: result)
                    }
                }
            )
            .enveEnvironment()

            let controller = UIHostingController(rootView: content)
            controller.modalPresentationStyle = .pageSheet
            controller.isModalInPresentation = true
            box.controller = controller
            presenter.present(controller, animated: true)
        }
    }

    private func normalize(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if !value.isEmpty,
            !value.lowercased().hasPrefix("http://"),
            !value.lowercased().hasPrefix("https://")
        {
            value = "https://\(value)"
        }
        return value
    }

    @MainActor
    private static func activeViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard
            let root = windows.first(where: \.isKeyWindow)?.rootViewController
                ?? windows.first?.rootViewController
        else {
            return nil
        }
        return topViewController(from: root)
    }

    @MainActor
    private static func topViewController(from controller: UIViewController) -> UIViewController {
        if let presented = controller.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = controller as? UINavigationController,
            let visible = navigation.visibleViewController
        {
            return topViewController(from: visible)
        }
        if let tabs = controller as? UITabBarController,
            let selected = tabs.selectedViewController
        {
            return topViewController(from: selected)
        }
        return controller
    }
}

private struct KomgaOAuthUserProfile: Decodable {
    let email: String?
    let username: String?
}

@MainActor
private final class KomgaOAuthPresentationBox {
    weak var controller: UIViewController?
    var didFinish = false
}
