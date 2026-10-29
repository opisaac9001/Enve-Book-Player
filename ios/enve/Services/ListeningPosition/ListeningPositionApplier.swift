import Foundation

enum ListeningPositionServerRoute: Equatable {
    case server
    case noServer
    case syncDisabled
}

enum ListeningPositionServerStatus: Equatable {
    case saved
    case queued
    case rejected(String)
    case noServer
    case syncDisabled
}

struct ListeningPositionApplyResult: Equatable {
    let book: Book
    let position: TimeInterval
    let server: ListeningPositionServerStatus
}

enum ListeningPositionApplyError: Error, Equatable {
    case incompatibleMedia
    case bookUnavailable
    case positionBeyondEnd
}

@MainActor
protocol ListeningPositionProgressTarget: AnyObject {
    func reload(_ book: Book) async throws(ListeningPositionApplyError) -> Book
    func loadedBookUniqueId() -> String?
    func seekLoadedBook(to position: TimeInterval)
    func applyLocally(_ book: Book, payload: ListeningPositionPayload, isFinished: Bool, at date: Date) async -> Book
    func serverRoute(for book: Book) -> ListeningPositionServerRoute
    func recordPendingServerWrite(_ book: Book, payload: ListeningPositionPayload, isFinished: Bool)
    func pushToServer(_ book: Book, payload: ListeningPositionPayload, isFinished: Bool) async -> ListeningPositionServerStatus
}

@MainActor
final class ListeningPositionApplier {
    private let target: any ListeningPositionProgressTarget
    private let serialQueue = PerBookSerialQueue()
    private let now: () -> Date

    init(target: any ListeningPositionProgressTarget, now: @escaping () -> Date = Date.init) {
        self.target = target
        self.now = now
    }

    func apply(_ payload: ListeningPositionPayload, to book: Book) async throws(ListeningPositionApplyError) -> ListeningPositionApplyResult {
        var result: ListeningPositionApplyResult?
        var failure: ListeningPositionApplyError?
        await serialQueue.enqueue(bookId: book.stableId) { [self] in
            do throws(ListeningPositionApplyError) {
                let book = try await target.reload(book)
                guard (payload.readingLocation != nil) == (book.mediaType == .ebook) else { throw .incompatibleMedia }
                let duration = book.duration ?? 0
                let isFinished: Bool
                if let reading = payload.readingLocation {
                    if reading.format == ListeningPositionReadingLocation.format(for: book),
                        let page = reading.page, let count = ListeningPositionReadingLocation.pageCount(for: book), page > count {
                        throw .positionBeyondEnd
                    }
                    isFinished = reading.progression(for: book) >= Book.finishedProgressThreshold
                } else {
                    if duration > 0, payload.position > duration { throw .positionBeyondEnd }
                    isFinished = duration > 0 && payload.position >= duration * Book.finishedProgressThreshold
                }
                let acceptedAt = now()
                // Seek before persistence so periodic player saves carry the accepted position.
                if payload.readingLocation == nil, target.loadedBookUniqueId() == book.uniqueId {
                    target.seekLoadedBook(to: payload.position)
                }
                let updated = await target.applyLocally(book, payload: payload, isFinished: isFinished, at: acceptedAt)
                let server: ListeningPositionServerStatus
                switch target.serverRoute(for: updated) {
                case .syncDisabled:
                    server = .syncDisabled
                case .noServer:
                    server = .noServer
                case .server:
                    target.recordPendingServerWrite(updated, payload: payload, isFinished: isFinished)
                    server = await target.pushToServer(updated, payload: payload, isFinished: isFinished)
                }
                result = ListeningPositionApplyResult(book: updated, position: payload.position, server: server)
            } catch { failure = error }
        }
        if let failure { throw failure }
        // The applier never retires its queue, so the enqueued operation always runs.
        return result!
    }
}

@MainActor
final class LiveListeningPositionProgressTarget: ListeningPositionProgressTarget {
    private let session: ProfileSession

    init(session: ProfileSession) {
        self.session = session
    }

    private var controller: any PlaybackControlling { session.playback.composition.controller }

    func reload(_ book: Book) async throws(ListeningPositionApplyError) -> Book {
        guard !session.isRetired, let current = await session.bookStore.book(uniqueId: book.uniqueId) else { throw .bookUnavailable }
        return current
    }

    func loadedBookUniqueId() -> String? {
        controller.snapshot.currentBook?.uniqueId
    }

    func seekLoadedBook(to position: TimeInterval) {
        controller.seek(to: position)
    }

    func applyLocally(_ book: Book, payload: ListeningPositionPayload, isFinished: Bool, at date: Date) async -> Book {
        if let reading = payload.readingLocation {
            session.ebookConflicts.remove(stableId: book.stableId)
            var updated = book
            updated.ebookProgress = reading.progression(for: updated)
            updated.epubLocator = reading.locatorJSON(for: updated)
            updated.isFinished = isFinished
            updated.lastUpdate = date
            if !isFinished, ["READ", "COMPLETED", "FINISHED"].contains(updated.serverReadStatus ?? "") {
                updated.serverReadStatus = "RE_READING"
            }
            await session.bookStore.applyAuthoritativeProgress([
                AuthoritativeProgressUpdate(
                    bookUniqueId: updated.uniqueId, stableId: updated.stableId,
                    currentTime: updated.currentTime, duration: updated.duration ?? 0,
                    ebookProgress: updated.ebookProgress, epubLocator: updated.epubLocator,
                    isFinished: isFinished, lastUpdate: date,
                    hideFromContinue: updated.hideFromContinue, serverReadStatus: updated.serverReadStatus
                )
            ])
            session.appState.mutateBook(uniqueId: updated.uniqueId) { $0 = updated }
            await session.linkedProgress.recordEbookProgress(
                book: updated, progression: updated.ebookProgress ?? 0, observedAt: date, authoritative: true
            )
            return updated
        }
        let position = payload.position
        let duration = book.duration ?? 0
        session.progress.update(
            UserMediaProgress(
                id: UUID().uuidString,
                libraryItemId: book.id,
                providerId: book.providerId,
                episodeId: book.episodeId,
                currentTime: position,
                progress: duration > 0 ? position / duration : 0,
                isFinished: isFinished,
                duration: duration,
                lastUpdate: date,
                ebookProgress: nil
            )
        )
        session.bookProgress.saveProgress(for: book, progress: position, duration: duration, at: date)

        var updated = session.appState.bookInMemory(uniqueId: book.uniqueId) ?? book
        updated.currentTime = position
        updated.isFinished = isFinished
        updated.lastUpdate = date
        await session.linkedProgress.recordAudiobookProgress(
            book: updated,
            currentTime: position,
            isFinished: isFinished,
            observedAt: date,
            authoritative: true
        )
        return updated
    }

    func serverRoute(for book: Book) -> ListeningPositionServerRoute {
        guard !session.isRetired, session.serverSyncEnabled, session.progress.syncProgressToServer else { return .syncDisabled }
        let hasProviderSink = session.registry
            .sinks(applicableTo: book, domain: book.mediaType == .ebook ? .ebook : .audiobook)
            .contains { $0.id == ProviderSyncSink.identifier }
        return hasProviderSink ? .server : .noServer
    }

    func recordPendingServerWrite(_ book: Book, payload: ListeningPositionPayload, isFinished: Bool) {
        let duration = book.duration ?? 0
        let reading = payload.readingLocation
        session.sync.enqueuePendingSync(
            book: book,
            position: reading == nil ? payload.position : 0,
            duration: duration,
            serverItemId: book.partKey ?? book.id,
            domain: reading == nil ? .audiobook : .ebook,
            progress: reading == nil ? (duration > 0 ? payload.position / duration : 0) : book.ebookProgress,
            locator: reading == nil ? nil : book.epubLocator,
            isFinished: isFinished
        )
    }

    func pushToServer(_ book: Book, payload: ListeningPositionPayload, isFinished: Bool) async -> ListeningPositionServerStatus {
        // forceImmediate also cancels any debounced push still carrying the previous position.
        if payload.readingLocation != nil {
            await session.sync.pushProgress(book: book, forceImmediate: true, domain: .ebook)
        } else {
            await session.sync.pushAudiobookProgress(
                book: book, position: payload.position, sessionId: nil, isFinished: isFinished,
                timeListened: 0, forceImmediate: true
            )
        }
        // Only provider acceptance removes the pending write.
        guard let pending = session.pendingSync.entries[book.stableId] else { return .saved }
        if pending.updatedAt == book.lastUpdate.timeIntervalSince1970, let message = pending.validationFailureMessage {
            return .rejected(message)
        }
        return .queued
    }
}
