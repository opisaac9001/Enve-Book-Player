import Foundation

// Audio session changes must be ordered and kept off the UI thread.
enum AudioSessionQueue {
    nonisolated static let shared = DispatchQueue(label: "com.enve.audio-session", qos: .userInitiated)

    nonisolated static func perform(
        _ work: @escaping @Sendable () throws -> Void,
        completion: @escaping @MainActor @Sendable (Error?) -> Void
    ) {
        shared.async {
            let failure: Error?
            do {
                try work()
                failure = nil
            } catch {
                failure = error
            }
            Task { @MainActor in completion(failure) }
        }
    }
}
