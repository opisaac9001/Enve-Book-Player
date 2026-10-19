import Foundation
import Logging

extension BookloreProvider {
    private static func ebookCoverURL(forAudiobookCover url: URL) -> URL? {
        for (audiobookSuffix, ebookSuffix) in [("/audiobook-cover", "/cover"), ("/audiobook-thumbnail", "/thumbnail")]
        where url.path.hasSuffix(audiobookSuffix) {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.path = String(url.path.dropLast(audiobookSuffix.count)) + ebookSuffix
            return components?.url
        }
        return nil
    }

    func fetchImageData(url: URL) async throws -> (Data, Int) {
        let requestedURL = BookloreBookMapper.rewriteCoverURL(url)

        if await coverCircuitBreaker.isOpen() {
            return (Data(), 503)
        }

        if await coverFailureCache.shouldSkip(requestedURL) {
            return (Data(), 503)
        }

        if requestedURL.path.contains("/audiobook-thumbnail") || requestedURL.path.contains("/audiobook-cover")
            || requestedURL.path.contains("/api/v1/audiobooks/")
        {
            AppLogger.network.info("[Booklore] Audiobook cover fetch original=\(url.redacted) rewritten=\(requestedURL.redacted)")
        }

        if connection.token == nil || connection.token?.isEmpty == true {
            if let username = connection.username,
                let password = connection.password,
                !username.isEmpty
            {
                try await loginCoalesced(username: username, password: password)
            } else if let refreshed = try? await refreshCoalesced() {
                connection.token = refreshed
                notifyTokenUpdated()
            }
        }

        guard let token = connection.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }

        func makeTokenURL(_ baseURL: URL, token: String) -> URL? {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name == "token" }
            queryItems.append(URLQueryItem(name: "token", value: token))
            components.queryItems = queryItems
            return components.url
        }

        func makeImageRequest(_ targetURL: URL, token: String) -> URLRequest {
            var request = URLRequest(url: targetURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let customHeaders = connection.customHeaders {
                for (key, value) in customHeaders {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            return request
        }

        func isMissingCoverResponse(_ data: Data, response: HTTPURLResponse, requestedURL: URL) -> Bool {
            let path = requestedURL.path
            guard path.contains("/api/v1/media/book/") else { return false }

            if response.statusCode == 404 { return true }
            guard response.statusCode == 200 else { return false }
            return Self.isMissingCoverPlaceholder(data)
        }

        guard let authenticatedURL = makeTokenURL(requestedURL, token: token) else {
            throw ProviderError.invalidURL
        }

        let request = makeImageRequest(authenticatedURL, token: token)

        await coverFetchLimiter.acquire()
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await send(request)
        } catch {
            Task { await coverFetchLimiter.release() }
            throw error
        }
        Task { await coverFetchLimiter.release() }
        let status = response.statusCode

        if status == 502 || status == 503 || status == 504 {
            await coverFailureCache.recordFailure(requestedURL)
            await coverCircuitBreaker.recordFailure()
        } else if status == 200 {
            await coverCircuitBreaker.recordSuccess()
        }

        if isMissingCoverResponse(data, response: response, requestedURL: requestedURL) {
            if let ebookCover = Self.ebookCoverURL(forAudiobookCover: requestedURL) {
                return try await fetchImageData(url: ebookCover)
            }
            return (Data(), 404)
        }

        if status == 401 || status == 403 {
            if let username = connection.username,
                let password = connection.password,
                !username.isEmpty
            {
                try await loginCoalesced(username: username, password: password)
            } else if let refreshed = try? await refreshCoalesced() {
                connection.token = refreshed
                notifyTokenUpdated()
            }

            guard let freshToken = connection.token, !freshToken.isEmpty else {
                return (data, status)
            }

            if let retryURL = makeTokenURL(requestedURL, token: freshToken) {
                let retryRequest = makeImageRequest(retryURL, token: freshToken)
                await coverFetchLimiter.acquire()
                let (retryData, retryResponse): (Data, HTTPURLResponse)
                do {
                    (retryData, retryResponse) = try await send(retryRequest)
                } catch {
                    Task { await coverFetchLimiter.release() }
                    throw error
                }
                Task { await coverFetchLimiter.release() }

                if isMissingCoverResponse(retryData, response: retryResponse, requestedURL: requestedURL) {
                    if let ebookCover = Self.ebookCoverURL(forAudiobookCover: requestedURL) {
                        return try await fetchImageData(url: ebookCover)
                    }
                    return (Data(), 404)
                }

                if retryResponse.statusCode >= 300 {
                    AppLogger.network.warning(
                        "[Booklore] Cover fetch retry failed HTTP \(retryResponse.statusCode) path=\(requestedURL.path)"
                    )
                }

                return (retryData, retryResponse.statusCode)
            }
        }

        if status >= 300 {
            AppLogger.network.warning("[Booklore] Cover fetch failed HTTP \(status) path=\(requestedURL.path)")
        }

        return (data, status)
    }
}
