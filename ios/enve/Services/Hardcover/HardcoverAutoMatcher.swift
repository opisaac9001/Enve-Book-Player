import Foundation
import Logging

@MainActor
public final class HardcoverAutoMatcher {

    static let shared = HardcoverAutoMatcher()

    var onNeedManualMatch: ((Book) -> Void)?

    var onPendingConfirmation: ((Book) -> Void)?

    func attemptAutoMatch(for book: Book) async {
        guard SettingsManager.shared.hardcoverAutoSyncEnabled else {
            AppLogger.network.warning("Skipping Hardcover auto-match - auto-sync disabled")
            return
        }

        guard let author = book.author, !author.isEmpty else {
            AppLogger.network.warning("Skipping Hardcover auto-match - no author info")
            return
        }

        do {
            let searchResults = try await HardcoverService.shared.searchBooks(
                query: book.title,
                limit: 5
            )

            guard !searchResults.isEmpty else {
                AppLogger.network.debug(
                    "No Hardcover results bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                )
                return
            }

            let normalizedTitle = book.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedAuthor = author.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            let exactMatches = searchResults.filter { result in
                let titleMatch = result.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTitle

                let authorDisplay = result.authorDisplay.lowercased()
                let authorMatch = authorDisplay.contains(normalizedAuthor) || normalizedAuthor.contains(authorDisplay)

                return titleMatch && authorMatch
            }

            if exactMatches.count == 1 {
                let hardcoverBook = exactMatches[0]
                AppLogger.network.debug(
                    "Auto-matched bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) hardcoverId=\(DiagnosticLogSanitizer.identifier(for: String(hardcoverBook.id)))"
                )

                let match = HardcoverBookMatch(
                    localBookId: book.id,
                    hardcoverBookId: hardcoverBook.id,
                    matchType: .automatic,
                    localBookTitle: book.title,
                    hardcoverBookTitle: hardcoverBook.title
                )

                let userBookId = try await HardcoverService.shared.addBookToLibrary(
                    bookId: hardcoverBook.id,
                    startReading: true
                )

                let matchWithUserBookId = HardcoverBookMatch(
                    id: match.id,
                    localBookId: match.localBookId,
                    hardcoverBookId: match.hardcoverBookId,
                    hardcoverUserBookId: userBookId,
                    matchedAt: match.matchedAt,
                    matchType: match.matchType,
                    localBookTitle: match.localBookTitle,
                    hardcoverBookTitle: match.hardcoverBookTitle
                )
                SettingsManager.shared.addHardcoverMatch(matchWithUserBookId)
                AppLogger.network.info("Auto-matched book added to Hardcover library")

            } else {
                if exactMatches.isEmpty {
                    AppLogger.network.debug(
                        "No exact Hardcover match bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)); requesting confirmation"
                    )
                } else {
                    AppLogger.network.debug(
                        "Multiple exact Hardcover matches bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)); requesting confirmation"
                    )
                }
                onPendingConfirmation?(book)
            }

        } catch {
            AppLogger.network.error("Hardcover auto-match failed: \(error.localizedDescription)")
        }
    }
}
