import Foundation

@MainActor
final class ProfileDownloadActivity {
    var unifiedBookIDs: Set<String> = []
    var externalBookIDs: Set<String> = []

    func isActive(_ bookID: String) -> Bool {
        unifiedBookIDs.contains(bookID) || externalBookIDs.contains(bookID)
    }
}
