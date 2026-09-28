import Foundation

enum CloudProgressEligibility {
    static func includes(_ book: Book) -> Bool {
        switch book.source {
        case .local, .smb, .webdav, .realdebrid, .torbox, .oneDrive:
            return true
        case .plex, .audiobookshelf, .jellyfin, .emby, .booklore, .komga, .kavita,
            .opds, .storyteller, .bookOrbit, .silo:
            return false
        }
    }
}

@MainActor
enum CloudBookContentIdentity {
    static func hash(for book: Book) -> String? {
        guard book.source == .local else { return nil }
        let storedBooks = LocalLibraryStorageStore.shared.loadBooks(libraryId: book.libraryId)
        return hash(for: book, storedBooks: storedBooks)
    }

    static func hashes(for books: [Book]) -> [String: String] {
        var result: [String: String] = [:]
        let localBooks = books.filter { $0.source == .local }
        for (libraryID, libraryBooks) in Dictionary(grouping: localBooks, by: \.libraryId) {
            let storedBooks = LocalLibraryStorageStore.shared.loadBooks(libraryId: libraryID)
            for book in libraryBooks {
                if let hash = hash(for: book, storedBooks: storedBooks) {
                    result[book.stableId] = hash
                }
            }
        }
        return result
    }

    static func hash(for book: Book, storedBooks: [LocalBookFile]) -> String? {
        guard book.source == .local else { return nil }
        let bookPath = book.filePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let stored = storedBooks.first { candidate in
            candidate.id == book.id
                || bookPath == URL(fileURLWithPath: candidate.filePath).standardizedFileURL.path
        }
        guard let hash = stored?.fileHash?.trimmingCharacters(in: .whitespacesAndNewlines), !hash.isEmpty else {
            return nil
        }
        return hash
    }
}

extension CloudKitProgressSync: SyncSink {
    static func shouldPushAudiobookPosition(
        _ position: TimeInterval,
        storedLocalPosition: TimeInterval?
    ) -> Bool {
        position > 0 || storedLocalPosition == 0
    }

    var id: String { "cloudkit.progress" }
    var displayName: String { "iCloud" }

    func isApplicable(to book: Book, domain: ProgressSyncDomain) -> Bool {
        SyncCoordinator.shared.isCloudKitAvailable && CloudProgressEligibility.includes(book)
    }

    func pull(book: Book, domain: ProgressSyncDomain) async -> SyncSnapshot? {
        let identity = CanonicalBookIdentity(from: book)
        guard
            let record = try? await fetchProgress(
                for: identity,
                domain: domain,
                contentHash: CloudBookContentIdentity.hash(for: book)
            )
        else { return nil }
        return SyncSnapshot(
            progress: record.normalizedProgress,
            positionSeconds: record.playbackPosition,
            locator: record.locator,
            lastUpdate: record.lastUpdated,
            isFinished: record.completed,
            source: "iCloud"
        )
    }

    func push(_ update: ProgressUpdate) async throws {
        let userProgress = UserProgressStore.shared.progress(for: update.book)
        if update.domain == .audiobook,
            !Self.shouldPushAudiobookPosition(
                update.positionSeconds,
                storedLocalPosition: userProgress?.currentTime
            )
        {
            return
        }
        let identity = CanonicalBookIdentity(from: update.book)
        let duration = update.book.duration ?? 0
        let completed = update.isFinished
            || (update.domain == .ebook
                ? update.progress >= Book.finishedProgressThreshold
                : duration > 0 && update.positionSeconds >= duration * Book.finishedProgressThreshold)
        let lastInteractionDate: Date = if update.domain == .ebook {
            update.book.lastUpdate
        } else if let saved = BookProgressStore.shared.loadProgress(for: update.book) {
            Date(timeIntervalSince1970: saved.lastUpdated)
        } else if let userProgress {
            userProgress.lastUpdate
        } else {
            Date()
        }
        try await saveProgress(
            identity: identity,
            contentHash: CloudBookContentIdentity.hash(for: update.book),
            position: update.positionSeconds,
            progress: update.progress,
            locator: update.locator,
            domain: update.domain,
            playbackRate: update.playbackRate,
            completed: completed,
            lastInteractionDate: lastInteractionDate
        )
    }
}
