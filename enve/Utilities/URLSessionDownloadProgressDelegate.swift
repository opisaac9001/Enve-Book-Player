import Foundation

final class URLSessionDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let progressHandler: @Sendable (Double) -> Void
    private let credential: URLCredential?
    private let lock = NSLock()
    private var lastReportedProgress: Double = 0
    private var lastReportTime: CFAbsoluteTime = 0

    private var copiedTempURL: URL?
    private var capturedResponse: HTTPURLResponse?
    private var capturedError: Error?
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
    private weak var activeTask: URLSessionDownloadTask?

    init(progressHandler: @escaping @Sendable (Double) -> Void, credential: URLCredential? = nil) {
        self.progressHandler = progressHandler
        self.credential = credential
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
            method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest
        {
            completionHandler(.useCredential, credential)
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }
}
