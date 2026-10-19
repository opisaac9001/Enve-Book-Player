import Foundation

@MainActor
struct BookUnreadMarker {
    static let confirmationListenedSeconds: TimeInterval = 120
    static let confirmationReadFraction = 0.01

    let lastOpened: LastOpenedBookStore
    let playerState: PlayerStateStore
    let session: any CurrentBookSession
    let playback: any PlaybackControlling
    let forgetRestoredBook: (String) -> Void
    let pairedStableId: (Book) async -> String?
    let resetProgress: (Book) -> Void

    static func isMeaningful(listenedSeconds: TimeInterval, readFraction: Double, isFinished: Bool) -> Bool {
        isFinished || listenedSeconds > confirmationListenedSeconds || readFraction > confirmationReadFraction
    }

    func needsConfirmation(_ book: Book) -> Bool {
        let snapshot = playback.snapshot
        let isLive = snapshot.currentBook?.stableId == book.stableId && snapshot.isLoaded
        return Self.isMeaningful(
            listenedSeconds: isLive ? snapshot.position : book.currentTime,
            readFraction: book.canonicalEbookProgress,
            isFinished: book.isFinished
        )
    }

    func canMarkUnread(_ book: Book) -> Bool {
        book.isFinished
            || book.currentTime > 0
            || book.canonicalEbookProgress > 0
            || lastOpened.stableId == book.stableId
            || session.currentBook?.stableId == book.stableId
            || playback.snapshot.currentBook?.stableId == book.stableId
    }

    func markUnread(_ book: Book) async {
        // Stop first so the player's closing progress save lands before the reset, not after it.
        if let playing = playback.snapshot.currentBook?.stableId {
            if playing == book.stableId {
                playback.stop()
            } else if await pairedStableId(book) == playing, playback.snapshot.currentBook?.stableId == playing {
                playback.stop()
            }
        }
        if session.currentBook?.stableId == book.stableId {
            session.currentBook = nil
        }
        if lastOpened.stableId == book.stableId {
            lastOpened.clear()
        }
        if let lastPlayed = playerState.loadLastPlayedBookId(), lastPlayed == book.stableId || lastPlayed == book.id {
            playerState.saveLastPlayedBookId(nil)
        }
        forgetRestoredBook(book.stableId)
        resetProgress(book)
    }
}
