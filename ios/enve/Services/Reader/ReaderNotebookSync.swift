import Foundation
import Logging

enum ReaderNotebookSyncOutcome: Equatable {
    case unchanged
    case bookmarkRemoteID(localID: String, remoteID: Int)
    case annotationRemoteRecord(localID: String, remoteID: Int, updatedAt: Date?)
    case replace(bookmarks: [Bookmark], annotations: [ReaderAnnotation])
    case reload
}

@MainActor
protocol ReaderNotebookSyncing: AnyObject {
    // Read local artifacts after the remote fetch because reader restoration may still be loading them.
    func pull(localArtifacts: () -> ReaderNotebookMerge.Snapshot) async -> ReaderNotebookSyncOutcome
    func bookmarkAdded(_ bookmark: Bookmark) async -> ReaderNotebookSyncOutcome
    func bookmarkUpdated(_ bookmark: Bookmark) async -> ReaderNotebookSyncOutcome
    func bookmarkRemoved(_ bookmark: Bookmark) async -> ReaderNotebookSyncOutcome
    func annotationUpserted(_ annotation: ReaderAnnotation) async -> ReaderNotebookSyncOutcome
    func annotationRemoved(_ annotation: ReaderAnnotation) async -> ReaderNotebookSyncOutcome
}

@MainActor
final class ProviderReaderNotebookSync: ReaderNotebookSyncing {
    private let book: Book
    private let providerResolver: any LibraryProviderResolving
    private let siloIDMap: any SiloReaderArtifactIDMapping
    private let bookOrbitQueue: BookOrbitReaderArtifactSync

    private var bookDiagnosticID: String { DiagnosticLogSanitizer.identifier(for: book.stableId) }

    init(
        book: Book,
        providerResolver: any LibraryProviderResolving,
        siloIDMap: any SiloReaderArtifactIDMapping = SiloReaderArtifactIDStore.shared,
        bookOrbitQueue: BookOrbitReaderArtifactSync = .shared
    ) {
        self.book = book
        self.providerResolver = providerResolver
        self.siloIDMap = siloIDMap
        self.bookOrbitQueue = bookOrbitQueue
    }

    func pull(localArtifacts: () -> ReaderNotebookMerge.Snapshot) async -> ReaderNotebookSyncOutcome {
        switch book.source {
        case .silo:
            return await pullSilo(mergingInto: localArtifacts)
        case .bookOrbit:
            return await syncBookOrbit()
        case .booklore:
            return await pullBooklore(mergingInto: localArtifacts)
        default:
            return .unchanged
        }
    }

    func bookmarkAdded(_ bookmark: Bookmark) async -> ReaderNotebookSyncOutcome {
        switch book.source {
        case .booklore:
            guard let provider = bookloreProvider else { return .unchanged }
            do {
                let record = try await provider.createRemoteBookmark(
                    for: book,
                    title: bookmark.title,
                    note: bookmark.note,
                    locator: bookmark.locator
                )
                return .bookmarkRemoteID(localID: bookmark.id, remoteID: record.id)
            } catch {
                AppLogger.general.error("Failed to sync bookmark bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
                return .unchanged
            }
        case .bookOrbit:
            bookOrbitQueue.enqueueBookmarkUpsert(book: book, localId: bookmark.id)
            return await syncBookOrbit()
        case .silo:
            guard let provider = siloProvider else { return .unchanged }
            do {
                let record = try await provider.createReaderBookmark(for: book, bookmark: bookmark)
                siloIDMap.setBookmarkRemoteID(
                    record.id,
                    connectionID: provider.connection.id,
                    bookID: book.stableId,
                    localID: bookmark.id
                )
            } catch {
                AppLogger.general.error("Failed to sync Silo bookmark bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
            }
            return .unchanged
        default:
            return .unchanged
        }
    }

    func bookmarkUpdated(_ bookmark: Bookmark) async -> ReaderNotebookSyncOutcome {
        switch book.source {
        case .booklore:
            guard let provider = bookloreProvider else { return .unchanged }
            do {
                if let remoteID = bookmark.remoteID {
                    try await provider.deleteRemoteBookmark(id: remoteID)
                }
                let record = try await provider.createRemoteBookmark(
                    for: book,
                    title: bookmark.title,
                    note: bookmark.note,
                    locator: bookmark.locator
                )
                return .bookmarkRemoteID(localID: bookmark.id, remoteID: record.id)
            } catch {
                AppLogger.general.error("Failed to update bookmark bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
                return .unchanged
            }
        case .bookOrbit:
            bookOrbitQueue.enqueueBookmarkUpsert(book: book, localId: bookmark.id)
            return await syncBookOrbit()
        case .silo:
            guard let provider = siloProvider else { return .unchanged }
            let connectionID = provider.connection.id
            do {
                if let remoteID = siloIDMap.bookmarkRemoteID(connectionID: connectionID, bookID: book.stableId, localID: bookmark.id) {
                    try await provider.deleteReaderAnnotation(id: remoteID, for: book)
                    siloIDMap.removeBookmarkRemoteID(connectionID: connectionID, bookID: book.stableId, localID: bookmark.id)
                }
                let record = try await provider.createReaderBookmark(for: book, bookmark: bookmark)
                siloIDMap.setBookmarkRemoteID(record.id, connectionID: connectionID, bookID: book.stableId, localID: bookmark.id)
            } catch {
                AppLogger.general.error("Failed to update Silo bookmark bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
            }
            return .unchanged
        default:
            return .unchanged
        }
    }

    func bookmarkRemoved(_ bookmark: Bookmark) async -> ReaderNotebookSyncOutcome {
        switch book.source {
        case .booklore:
            guard let remoteID = bookmark.remoteID, let provider = bookloreProvider else { return .unchanged }
            try? await provider.deleteRemoteBookmark(id: remoteID)
            return .unchanged
        case .bookOrbit:
            guard let remoteID = bookmark.remoteID else { return .unchanged }
            bookOrbitQueue.enqueueBookmarkDelete(book: book, remoteId: remoteID)
            return await syncBookOrbit()
        case .silo:
            guard let provider = siloProvider else { return .unchanged }
            let connectionID = provider.connection.id
            guard let remoteID = siloIDMap.bookmarkRemoteID(connectionID: connectionID, bookID: book.stableId, localID: bookmark.id)
            else { return .unchanged }
            try? await provider.deleteReaderAnnotation(id: remoteID, for: book)
            siloIDMap.removeBookmarkRemoteID(connectionID: connectionID, bookID: book.stableId, localID: bookmark.id)
            return .unchanged
        default:
            return .unchanged
        }
    }

    func annotationUpserted(_ annotation: ReaderAnnotation) async -> ReaderNotebookSyncOutcome {
        switch book.source {
        case .booklore:
            guard let provider = bookloreProvider else { return .unchanged }
            do {
                let record: BookloreProvider.RemoteAnnotationRecord
                if let remoteID = annotation.remoteID {
                    record = try await provider.updateRemoteAnnotation(id: remoteID, annotation: annotation)
                } else {
                    record = try await provider.createRemoteAnnotation(for: book, annotation: annotation)
                }
                return .annotationRemoteRecord(
                    localID: annotation.id,
                    remoteID: record.id,
                    updatedAt: ReaderNotebookMerge.providerDate(record.updatedAt)
                )
            } catch ProviderError.noCFI {
                return .unchanged
            } catch {
                AppLogger.general.error("Failed to sync annotation bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
                return .unchanged
            }
        case .bookOrbit:
            bookOrbitQueue.enqueueAnnotationUpsert(book: book, localId: annotation.id)
            return await syncBookOrbit()
        case .silo:
            guard let provider = siloProvider else { return .unchanged }
            let connectionID = provider.connection.id
            do {
                let record: SiloReaderAnnotationRecord
                if let remoteID = siloIDMap.annotationRemoteID(connectionID: connectionID, bookID: book.stableId, localID: annotation.id) {
                    record = try await provider.updateReaderAnnotation(id: remoteID, for: book, annotation: annotation)
                } else {
                    record = try await provider.createReaderAnnotation(for: book, annotation: annotation)
                }
                siloIDMap.setAnnotationRemoteID(record.id, connectionID: connectionID, bookID: book.stableId, localID: annotation.id)
            } catch ProviderError.noCFI {
            } catch {
                AppLogger.general.error("Failed to sync Silo annotation bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
            }
            return .unchanged
        default:
            return .unchanged
        }
    }

    func annotationRemoved(_ annotation: ReaderAnnotation) async -> ReaderNotebookSyncOutcome {
        switch book.source {
        case .booklore:
            guard let remoteID = annotation.remoteID, let provider = bookloreProvider else { return .unchanged }
            try? await provider.deleteRemoteAnnotation(id: remoteID)
            return .unchanged
        case .bookOrbit:
            guard let remoteID = annotation.remoteID else { return .unchanged }
            bookOrbitQueue.enqueueAnnotationDelete(book: book, remoteId: remoteID)
            return await syncBookOrbit()
        case .silo:
            guard let provider = siloProvider else { return .unchanged }
            let connectionID = provider.connection.id
            guard let remoteID = siloIDMap.annotationRemoteID(connectionID: connectionID, bookID: book.stableId, localID: annotation.id)
            else { return .unchanged }
            try? await provider.deleteReaderAnnotation(id: remoteID, for: book)
            siloIDMap.removeAnnotationRemoteID(connectionID: connectionID, bookID: book.stableId, localID: annotation.id)
            return .unchanged
        default:
            return .unchanged
        }
    }

    private var bookloreProvider: BookloreProvider? {
        providerResolver.provider(for: book.providerId) as? BookloreProvider
    }

    private var siloProvider: SiloProvider? {
        providerResolver.provider(for: book.providerId) as? SiloProvider
    }

    private func pullBooklore(mergingInto localArtifacts: () -> ReaderNotebookMerge.Snapshot) async -> ReaderNotebookSyncOutcome {
        guard let provider = bookloreProvider else { return .unchanged }
        do {
            async let remoteAnnotationsTask = provider.fetchRemoteAnnotations(for: book)
            async let remoteBookmarksTask = provider.fetchRemoteBookmarks(for: book)

            let remoteAnnotations = try await remoteAnnotationsTask
            let remoteBookmarks = try await remoteBookmarksTask

            let merged = ReaderNotebookMerge.applyingBookloreRecords(
                annotations: remoteAnnotations,
                bookmarks: remoteBookmarks,
                to: localArtifacts(),
                bookID: book.id,
                bookStableID: book.stableId
            )
            return .replace(bookmarks: merged.bookmarks, annotations: merged.annotations)
        } catch {
            AppLogger.general.error("Failed to fetch annotations bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
            do {
                let entries = try await provider.fetchNotebookEntries(for: book)
                let merged = ReaderNotebookMerge.applyingBookloreNotebookEntries(
                    entries,
                    to: localArtifacts(),
                    bookID: book.id,
                    bookStableID: book.stableId
                )
                return .replace(bookmarks: merged.bookmarks, annotations: merged.annotations)
            } catch {
                AppLogger.general.error("Fallback notebook fetch also failed: \(error.localizedDescription)")
                return .unchanged
            }
        }
    }

    private func pullSilo(mergingInto localArtifacts: () -> ReaderNotebookMerge.Snapshot) async -> ReaderNotebookSyncOutcome {
        guard let provider = siloProvider else { return .unchanged }
        do {
            let records = try await provider.fetchReaderAnnotations(for: book)
            let merged = ReaderNotebookMerge.applyingSiloRecords(
                records,
                to: localArtifacts(),
                bookStableID: book.stableId,
                connectionID: provider.connection.id,
                idMap: siloIDMap
            )
            return .replace(bookmarks: merged.bookmarks, annotations: merged.annotations)
        } catch {
            AppLogger.general.error("Failed to fetch Silo annotations bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
            return .unchanged
        }
    }

    private func syncBookOrbit() async -> ReaderNotebookSyncOutcome {
        guard let provider = providerResolver.provider(for: book.providerId) as? BookOrbitProvider else { return .unchanged }
        _ = await bookOrbitQueue.sync(book: book, provider: provider)
        return .reload
    }
}
