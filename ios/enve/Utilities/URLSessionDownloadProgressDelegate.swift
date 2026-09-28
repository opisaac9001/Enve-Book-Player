import Foundation

/// Credentials are scoped by scheme, host, and effective port; incomplete URLs match no origin.
nonisolated struct HTTPOrigin: Hashable {
    let scheme: String
    let host: String
    let port: Int

    init(url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        scheme = components?.scheme?.lowercased() ?? ""
        host = components?.host?.lowercased() ?? ""
        port = components?.port ?? (components?.scheme?.lowercased() == "https" ? 443 : 80)
    }

    var isResolvable: Bool { !scheme.isEmpty && !host.isEmpty }

    func matches(_ url: URL) -> Bool {
        isResolvable && HTTPOrigin(url: url) == self
    }

    /// Older protection spaces may omit the scheme; accept them when the remaining origin fields match.
    func matches(_ space: URLProtectionSpace) -> Bool {
        guard isResolvable,
            space.host.caseInsensitiveCompare(host) == .orderedSame,
            space.port == port
        else { return false }
        guard let challengeScheme = space.protocol else { return true }
        return challengeScheme.caseInsensitiveCompare(scheme) == .orderedSame
    }
}

final class URLSessionDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let progressHandler: @Sendable (Double) -> Void
    private let credential: URLCredential?
    /// Default to the original request origin when the caller provides none.
    private let allowedOrigin: HTTPOrigin?
    private let sensitiveHeaderNames: Set<String>
    private let lock = NSLock()
    private var lastReportedProgress: Double = 0
    private var lastReportTime: CFAbsoluteTime = 0

    private var copiedTempURL: URL?
    private var capturedResponse: HTTPURLResponse?
    private var capturedError: Error?
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
    private weak var activeTask: URLSessionDownloadTask?

    init(
        progressHandler: @escaping @Sendable (Double) -> Void,
        credential: URLCredential? = nil,
        allowedOrigin: URL? = nil,
        sensitiveHeaderNames: Set<String> = []
    ) {
        self.progressHandler = progressHandler
        self.credential = credential
        self.allowedOrigin = allowedOrigin.map(HTTPOrigin.init(url:))
        self.sensitiveHeaderNames = sensitiveHeaderNames.union(HTTPRedirectPolicy.alwaysSensitiveHeaderNames)
        super.init()
    }

    func awaitResult(_ makeTask: () -> URLSessionDownloadTask) async throws -> (URL, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()

                let task = makeTask()
                lock.lock()
                activeTask = task
                lock.unlock()
                if Task.isCancelled {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.lock.lock()
            let task = self.activeTask
            self.lock.unlock()
            task?.cancel()
        }
    }

    private func fulfillIfReady() {
        lock.lock()
        defer { lock.unlock() }
        guard let c = continuation else { return }
        if let error = capturedError {
            continuation = nil
            activeTask = nil
            c.resume(throwing: error)
            return
        }
        if let url = copiedTempURL, let resp = capturedResponse {
            continuation = nil
            activeTask = nil
            c.resume(returning: (url, resp))
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(
            max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0),
            1
        )

        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let delta = progress - lastReportedProgress
        let elapsed = now - lastReportTime
        let shouldReport = delta >= 0.005 || elapsed >= 0.25 || progress >= 1.0
        if shouldReport {
            lastReportedProgress = progress
            lastReportTime = now
        }
        lock.unlock()
        guard shouldReport else { return }
        progressHandler(progress)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {

        lock.lock()
        let waiting = continuation != nil
        lock.unlock()
        guard waiting else { return }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            lock.lock()
            copiedTempURL = dest
            capturedResponse = downloadTask.response as? HTTPURLResponse
            lock.unlock()
        } catch {
            lock.lock()
            if capturedError == nil { capturedError = error }
            lock.unlock()
        }
        fulfillIfReady()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {

        lock.lock()
        let waiting = continuation != nil
        lock.unlock()
        guard waiting else { return }

        if let error {
            lock.lock()
            if capturedError == nil { capturedError = error }
            lock.unlock()
        }
        fulfillIfReady()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host

        if method == NSURLAuthenticationMethodClientCertificate {
            if let identity = NetworkHostUtils.findMTLSIdentity(forHost: host) {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        if method == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        {
            if NetworkHostUtils.isLocalNetworkHost(host) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        if let credential,
            method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
            allowedOrigin?.matches(challenge.protectionSpace) != false
        {
            completionHandler(.useCredential, credential)
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    /// Keep credentials on the scoped origin and reject unsafe redirect destinations.
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, HTTPRedirectPolicy.isFollowable(url, from: response.url) else {
            completionHandler(nil)
            return
        }
        completionHandler(
            HTTPRedirectPolicy.sanitized(
                request,
                keepingCredentialsFor: allowedOrigin ?? HTTPRedirectPolicy.origin(ofOriginalRequestIn: task),
                alsoStripping: sensitiveHeaderNames
            )
        )
    }
}
