import Foundation

enum EnveLibrarianError: LocalizedError {
    case noTranscript
    case backendUnavailable(String)
    case emptyQuestion
    case responseTimedOut
    case contextTooLarge

    var errorDescription: String? {
        switch self {
        case .noTranscript:
            return "Prepare local book context before asking Enve Librarian."
        case .backendUnavailable(let reason):
            return reason
        case .emptyQuestion:
            return "Ask a question first."
        case .responseTimedOut:
            return "Enve Librarian took too long to answer. Try a narrower question."
        case .contextTooLarge:
            return "That passage is too large for the model. Try a narrower scope."
        }
    }
}

@MainActor
final class EnveLibrarianService {
    static let shared = EnveLibrarianService()

    private let contextRetriever = BookContextRetriever.shared

    private init() {}

    func answer(
        question rawQuestion: String,
        book: Book,
        scope: BookIntelligenceScope,
        currentTime: TimeInterval,
        contextRange: ClosedRange<TimeInterval>? = nil,
        history: [LibrarianMessage] = []
    ) async throws -> String {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw EnveLibrarianError.emptyQuestion }

        let context =
            if let contextRange {
                contextRetriever.context(for: book, scope: scope, range: contextRange)
            } else {
                contextRetriever.context(for: book, scope: scope, currentTime: currentTime)
            }
        guard !context.isEmpty else {
            throw EnveLibrarianError.noTranscript
        }

        let backend = BookIntelligenceSettingsStore.shared.activeBackend
        if let message = backend.availabilityMessage() {
            throw EnveLibrarianError.backendUnavailable(message)
        }

        let instructions = """
            You are Enve, a kind and wholesome male librarian inside Enve Book Player.
            You sound warm, calm, thoughtful, and well-read.
            Your tone is gently conversational, but never cutesy, theatrical, or overly wordy.
            Answer only from the supplied local book context.
            Do not reveal or invent events beyond the supplied context.
            If the answer is not present in the context, say that the local context does not show it yet.
            Keep answers concise, clear, and helpful for someone returning to a book.
            """

        func prompt(contextText: String) -> String {
            """
            Book: \(book.title)
            Author: \(book.author ?? "Unknown")
            Scope: \(context.scope.promptName(for: book.mediaType))
            \(rangeDescription(context))

            Local context:
            \(contextText)

            User question:
            \(question)
            """
        }

        let budget = backend.contextBudgetCharacters
        do {
            return try await backend.answer(
                instructions: instructions,
                prompt: prompt(contextText: truncatedContext(context.text, to: budget)),
                history: history
            )
        } catch EnveLibrarianError.contextTooLarge {

            return try await backend.answer(
                instructions: instructions,
                prompt: prompt(contextText: truncatedContext(context.text, to: budget / 2)),
                history: history
            )
        }
    }

    func availabilityMessage() -> String? {
        BookIntelligenceSettingsStore.shared.activeBackend.availabilityMessage()
    }

    private func truncatedContext(_ text: String, to maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let suffix = String(text.suffix(maxCharacters))
        guard let newline = suffix.firstIndex(of: "\n") else { return suffix }
        let trimmed = String(suffix[suffix.index(after: newline)...])
        return trimmed.isEmpty ? suffix : trimmed
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let total = Int(max(0, time))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func rangeDescription(_ context: BookContextResult) -> String {
        switch context.source {
        case .audiobookTranscript:
            return "Allowed time range: \(formatTime(context.range.lowerBound)) to \(formatTime(context.range.upperBound))"
        case .ebookText:
            return "Allowed reading range: \(formatProgress(context.range.lowerBound)) to \(formatProgress(context.range.upperBound))"
        }
    }

    private func formatProgress(_ progress: Double) -> String {
        "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }
}
