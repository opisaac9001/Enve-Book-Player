import Foundation
import os

nonisolated final class ProviderURLSession: Sendable {
    private let session: URLSession
    private let invalidated = OSAllocatedUnfairLock(initialState: false)

    init(_ session: URLSession) {
        self.session = session
    }

    func invalidateAndCancel() {
        invalidated.withLock { retired in
            guard !retired else { return }
            retired = true
            session.invalidateAndCancel()
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await perform { completion in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    completion(.failure(error))
                } else if let data, let response {
                    completion(.success((data, response)))
                } else {
                    completion(.failure(URLError(.badServerResponse)))
                }
            }
        }
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await perform { completion in
            session.downloadTask(with: request) { location, response, error in
                if let error {
                    completion(.failure(error))
                } else if let location, let response {
                    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString)")
                    do {
                        try FileManager.default.moveItem(at: location, to: destination)
                        completion(.success((destination, response)))
                    } catch {
                        completion(.failure(error))
                    }
                } else {
                    completion(.failure(URLError(.badServerResponse)))
                }
            }
        }
    }

    func downloadTask(with request: URLRequest) throws -> URLSessionDownloadTask {
        try invalidated.withLock { retired in
            guard !retired else { throw CancellationError() }
            return session.downloadTask(with: request)
        }
    }

    private func perform<Value: Sendable>(
        _ makeTask: @Sendable (@escaping @Sendable (Result<Value, Error>) -> Void) -> URLSessionTask
    ) async throws -> Value {
        let cancellation = OSAllocatedUnfairLock(initialState: (task: URLSessionTask?.none, cancelled: false))
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    // Task creation and invalidation must be atomic; iOS 17 raises an Objective-C exception otherwise.
                    let task = try invalidated.withLock { retired in
                        guard !retired else { throw CancellationError() }
                        return makeTask { continuation.resume(with: $0) }
                    }
                    cancellation.withLock { state in
                        state.task = task
                        if state.cancelled { task.cancel() }
                    }
                    task.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancellation.withLock { state in
                state.cancelled = true
                state.task?.cancel()
            }
        }
    }
}
