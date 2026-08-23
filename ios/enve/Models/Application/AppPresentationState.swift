import Foundation
import Logging

@Observable
@MainActor
final class AppPresentationState {
    var isPlayerPresented = false
    var selectedEbookForDetail: Book?
    var userFacingError: UserFacingError?
    var zipFileAlertBook: Book?
    var orphanedBooks: [Book] = []
    var showOrphanedBooksSheet = false
    var embeddedScanProgress: Double = 0
    var embeddedScanStatusText = ""
    var libraryImportProgress: LibraryImportProgress?

    private var lastUserFacingError: (title: String, message: String, date: Date)?

    func presentError(title: String, message: String) {
        if let lastUserFacingError,
            lastUserFacingError.title == title,
            lastUserFacingError.message == message,
            Date().timeIntervalSince(lastUserFacingError.date) < 5
        {
            return
        }
        AppLogger.general.error("Presented user-facing error")
        lastUserFacingError = (title, message, Date())
        userFacingError = UserFacingError(title: title, message: message)
    }

    func dismissError() {
        userFacingError = nil
    }
}
