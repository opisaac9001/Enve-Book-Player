import Foundation

@MainActor
enum PlaybackStartupDeadline {
    static func run<Value: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let race = Race<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                race.start(seconds: seconds, continuation: continuation, operation: operation)
            }
        } onCancel: {
            Task { @MainActor in race.cancel() }
        }
    }

    // A task group would wait for an uncooperative network operation after its deadline.
    // Resume the caller immediately; the cancelled operation must validate before publishing state.
    @MainActor
    private final class Race<Value: Sendable> {
        private var continuation: CheckedContinuation<Value, Error>?
        private var operationTask: Task<Void, Never>?
        private var timerTask: Task<Void, Never>?
        private var finished = false

        func start(
            seconds: TimeInterval,
            continuation: CheckedContinuation<Value, Error>,
            operation: @escaping @MainActor () async throws -> Value
        ) {
            guard !finished else {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            operationTask = Task { @MainActor in
                do { finish(.success(try await operation())) }
                catch { finish(.failure(error)) }
            }
            timerTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(seconds))
                    finish(.failure(URLError(.timedOut)))
                } catch {}
            }
        }

        func cancel() { finish(.failure(CancellationError())) }

        private func finish(_ result: Result<Value, Error>) {
            guard !finished else { return }
            finished = true
            operationTask?.cancel()
            timerTask?.cancel()
            operationTask = nil
            timerTask = nil
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(with: result)
        }
    }
}
