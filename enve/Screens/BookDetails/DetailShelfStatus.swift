import Combine
import Foundation

@Observable
final class DetailShelfStatus {
    private(set) var current: BookOrbitProvider.BookOrbitReadStatus?
    private(set) var message: String?
    private(set) var failed = false
    private(set) var isUpdating = false

    func load(book: Book, library: LibraryEngine) async {
        guard book.source == .bookOrbit,
            let provider = library.provider(for: book) as? BookOrbitProvider
        else { return }
        current = await provider.fetchReadStatus(for: book)
    }

    func set(_ status: BookOrbitProvider.BookOrbitReadStatus, book: Book, library: LibraryEngine) async {
        guard let provider = library.provider(for: book) as? BookOrbitProvider else {
            failed = true
            message = "BookOrbit isn't reachable right now"
            return
        }

        isUpdating = true
        failed = false
        message = nil
        defer { isUpdating = false }

        do {
            try await provider.updateReadStatus(for: book, status: status)
            let now = Date()

            switch status {
            case .read:
                _ = library.updateBook(uniqueId: book.uniqueId) {
                    $0.isFinished = true
                    $0.hideFromContinue = true
                    $0.serverReadStatus = status.rawValue.uppercased()
                    $0.lastUpdate = now
                    if $0.mediaType == .ebook {
                        $0.ebookProgress = max($0.ebookProgress ?? 0, 1.0)
                    } else if let duration = $0.duration, duration > 0 {
                        $0.currentTime = duration
                    }
                }
                BookProgressStore.shared.remove(stableId: book.stableId)
                message = "Shelved as finished on BookOrbit"
            case .abandoned:
                _ = library.updateBook(uniqueId: book.uniqueId) {
                    $0.isFinished = false
                    $0.hideFromContinue = true
                    $0.serverReadStatus = status.rawValue.uppercased()
                    $0.lastUpdate = now
                }
                BookProgressStore.shared.remove(stableId: book.stableId)
                message = "Set aside on BookOrbit"
            case .reading, .rereading:
                _ = library.updateBook(uniqueId: book.uniqueId) {
                    $0.isFinished = false
                    $0.hideFromContinue = false
                    $0.serverReadStatus = status.rawValue.uppercased()
                    $0.lastUpdate = now
                }
                message = status == .rereading ? "Reading again, says BookOrbit" : "Back on the reading shelf"
            case .wantToRead, .onHold:
                _ = library.updateBook(uniqueId: book.uniqueId) {
                    $0.isFinished = false
                    $0.hideFromContinue = true
                    $0.serverReadStatus = status.rawValue.uppercased()
                    $0.lastUpdate = now
                }
                BookProgressStore.shared.remove(stableId: book.stableId)
                message = status == .onHold ? "Resting on hold on BookOrbit" : "Shelved as want to read"
            case .skimmed:
                _ = library.updateBook(uniqueId: book.uniqueId) {
                    $0.isFinished = true
                    $0.hideFromContinue = true
                    $0.serverReadStatus = status.rawValue.uppercased()
                    $0.lastUpdate = now
                }
                BookProgressStore.shared.remove(stableId: book.stableId)
                message = "Shelved as skimmed on BookOrbit"
            case .unread:
                _ = library.updateBook(uniqueId: book.uniqueId) {
                    $0.currentTime = 0
                    $0.ebookProgress = $0.mediaType == .ebook ? 0 : nil
                    $0.epubLocator = nil
                    $0.isFinished = false
                    $0.hideFromContinue = false
                    $0.serverReadStatus = status.rawValue.uppercased()
                    $0.lastUpdate = now
                }
                BookProgressStore.shared.remove(stableId: book.stableId)
                message = "Shelved as unread on BookOrbit"
            }

            current = status
            library.notifyLibraryChanged()
            NotificationCenter.default.post(name: .continueListeningNeedsRefresh, object: nil)
        } catch {
            failed = true
            message = "Couldn't update BookOrbit"
        }
    }
}
