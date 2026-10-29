import Foundation

nonisolated struct ProgressValidationError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}
