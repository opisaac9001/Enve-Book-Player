import Foundation
import Logging

extension URLSession {
    nonisolated func retryingData(for request: URLRequest, retryCount: Int = 3) async throws -> (Data, URLResponse) {
        var currentRetry = 0
        while true {
            do {
                if currentRetry > 0 {
                    AppLogger.network.warning(
                        "Executing request: \(request.url?.redacted.absoluteString ?? "unknown") (Attempt \(currentRetry + 1))"
                    )
                }
                return try await data(for: request)
            } catch {
                let nsError = error as NSError
                let retryableCodes = [-1001, -1003, -1005, -1009]

                if currentRetry < retryCount && retryableCodes.contains(nsError.code) {
                    currentRetry += 1
                    let delay = pow(2.0, Double(currentRetry))
                    AppLogger.network.error(
                        "Request failed with error \(nsError.code). Retrying in \(delay)s... (Attempt \(currentRetry + 1)/\(retryCount + 1))"
                    )
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
    }
}
