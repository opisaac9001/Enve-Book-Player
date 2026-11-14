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
    private let bookNoteIDs: any GrimmoryBookNoteIDMapping
    private let allowsExternalSync: Bool
    private let bookOrbitQueue: BookOrbitReaderArtifactSync?
    var bookOrbitSpineHrefs: (() -> [String: String])?
    var activeReaderEngine: (() -> ReaderEngineKind)?
    var epubFileURL: (() -> URL?)?

    private var bookDiagnosticID: String { DiagnosticLogSanitizer.identifier(for: book.stableId) }

    init(
        book: Book,
        providerResolver: any LibraryProviderResolving,
        siloIDMap: any SiloReaderArtifactIDMapping = SiloReaderArtifactIDStore.shared,
        bookNoteIDs: any GrimmoryBookNoteIDMapping = GrimmoryBookNoteIDStore.shared,
        bookOrbitQueue: BookOrbitReaderArtifactSync? = .shared,
        allowsExternalSync: Bool = true
    ) {
        self.allowsExternalSync = allowsExternalSync
        self.book = book
        self.providerResolver = providerResolver
        self.siloIDMap = siloIDMap
        self.bookNoteIDs = bookNoteIDs
        self.bookOrbitQueue = bookOrbitQueue
    }

    func pull(localArtifacts: () -> ReaderNotebookMerge.Snapshot) async -> ReaderNotebookSyncOutcome {
        switch book.source {
        case .silo:
            return await pullSilo(mergingInto: localArtifacts)
        case .bookOrbit:
            guard allowsExternalSync else { return .unchanged }
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
            guard allowsExternalSync else { return .unchanged }
            bookOrbitQueue?.enqueueBookmarkUpsert(book: book, localId: bookmark.id)
            return await syncBookOrbit()
        case .silo:
            guard let silo = await siloContext() else { return .unchanged }
            _ = await pushSiloBookmark(bookmark, provider: silo.provider, scope: silo.scope)
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
            guard allowsExternalSync else { return .unchanged }
            bookOrbitQueue?.enqueueBookmarkUpsert(book: book, localId: bookmark.id)
            return await syncBookOrbit()
        case .silo:
            guard let silo = await siloContext() else { return .unchanged }
            _ = await pushSiloBookmark(bookmark, provider: silo.provider, scope: silo.scope)
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
            guard allowsExternalSync else { return .unchanged }
            guard let remoteID = bookmark.remoteID else { return .unchanged }
            bookOrbitQueue?.enqueueBookmarkDelete(book: book, remoteId: remoteID)
            return await syncBookOrbit()
        case .silo:
            guard let silo = await siloContext() else { return .unchanged }
            await removeSiloArtifact(localID: bookmark.id, isBookmark: true, provider: silo.provider, scope: silo.scope)
            return .unchanged
        default:
            return .unchanged
        }
    }

    func annotationUpserted(_ annotation: ReaderAnnotation) async -> ReaderNotebookSyncOutcome {
        switch book.source {
        case .booklore:
            guard let provider = bookloreProvider else { return .unchanged }
            let connectionID = provider.connection.id
            if let noteID = bookNoteIDs.noteID(connectionID: connectionID, bookID: book.stableId, localID: annotation.id) {
                do {
                    if annotation.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        _ = try await provider.updateBookNote(id: noteID, annotation: annotation)
                        return .unchanged
                    }
                    // A cleared note leaves a plain highlight, which Grimmory stores as an annotation.
                    try await provider.deleteBookNote(id: noteID)
                    bookNoteIDs.removeNoteID(connectionID: connectionID, bookID: book.stableId, localID: annotation.id)
                } catch {
                    AppLogger.general.error("Failed to sync book note bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
                    return .unchanged
                }
            }
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
            guard allowsExternalSync else { return .unchanged }
            bookOrbitQueue?.enqueueAnnotationUpsert(book: book, localId: annotation.id)
            return await syncBookOrbit()
        case .silo:
            guard let silo = await siloContext() else { return .unchanged }
            _ = await pushSiloAnnotation(annotation, provider: silo.provider, scope: silo.scope)
            return .unchanged
        default:
            return .unchanged
        }
    }

    func annotationRemoved(_ annotation: ReaderAnnotation) async -> ReaderNotebookSyncOutcome {
        switch book.source {
        case .booklore:
            guard let provider = bookloreProvider else { return .unchanged }
            let connectionID = provider.connection.id
            if let noteID = bookNoteIDs.noteID(connectionID: connectionID, bookID: book.stableId, localID: annotation.id) {
                try? await provider.deleteBookNote(id: noteID)
                bookNoteIDs.removeNoteID(connectionID: connectionID, bookID: book.stableId, localID: annotation.id)
                return .unchanged
            }
            guard let remoteID = annotation.remoteID else { return .unchanged }
            try? await provider.deleteRemoteAnnotation(id: remoteID)
            return .unchanged
        case .bookOrbit:
            guard allowsExternalSync else { return .unchanged }
            guard let remoteID = annotation.remoteID else { return .unchanged }
            bookOrbitQueue?.enqueueAnnotationDelete(book: book, remoteId: remoteID)
            return await syncBookOrbit()
        case .silo:
            guard let silo = await siloContext() else { return .unchanged }
            await removeSiloArtifact(localID: annotation.id, isBookmark: false, provider: silo.provider, scope: silo.scope)
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
        let pullStartedAt = Date()
        async let bookNotesTask = provider.fetchBookNotes(for: book)

        var merged: ReaderNotebookMerge.Snapshot
        var fetchedArtifacts = true
        do {
            async let remoteAnnotationsTask = provider.fetchRemoteAnnotations(for: book)
            async let remoteBookmarksTask = provider.fetchRemoteBookmarks(for: book)

            let remoteAnnotations = try await remoteAnnotationsTask
            let remoteBookmarks = try await remoteBookmarksTask

            merged = ReaderNotebookMerge.applyingBookloreRecords(
                annotations: remoteAnnotations,
                bookmarks: remoteBookmarks,
                to: localArtifacts(),
                bookID: book.id,
                bookStableID: book.stableId
            )
        } catch {
            AppLogger.general.error("Failed to fetch annotations bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
            do {
                let entries = try await provider.fetchNotebookEntries(for: book)
                merged = ReaderNotebookMerge.applyingBookloreNotebookEntries(
                    entries,
                    to: localArtifacts(),
                    bookID: book.id,
                    bookStableID: book.stableId
                )
            } catch {
                AppLogger.general.error("Fallback notebook fetch also failed: \(error.localizedDescription)")
                merged = localArtifacts()
                fetchedArtifacts = false
            }
        }

        let bookNotes: [BookloreProvider.RemoteBookNoteRecord]?
        do {
            bookNotes = try await bookNotesTask
        } catch {
            AppLogger.general.error("Failed to fetch book notes bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
            bookNotes = nil
        }
        guard fetchedArtifacts || bookNotes != nil else { return .unchanged }
        if let bookNotes {
            merged = ReaderNotebookMerge.applyingGrimmoryBookNotes(
                bookNotes,
                to: merged,
                bookID: book.id,
                bookStableID: book.stableId,
                connectionID: provider.connection.id,
                idMap: bookNoteIDs
            )
        }
        merged = await uploadingUnsyncedAnnotations(in: merged, createdBefore: pullStartedAt, provider: provider)
        let hydrated = await hydratingReadiumLocators(in: merged)
        return .replace(bookmarks: hydrated.bookmarks, annotations: hydrated.annotations)
    }

    // Retries highlights whose live push failed or had no CFI yet; newer ones are still owned by annotationUpserted.
    private func uploadingUnsyncedAnnotations(
        in snapshot: ReaderNotebookMerge.Snapshot,
        createdBefore cutoff: Date,
        provider: BookloreProvider
    ) async -> ReaderNotebookMerge.Snapshot {
        var updated = snapshot
        let connectionID = provider.connection.id
        for index in updated.annotations.indices {
            let annotation = updated.annotations[index]
            guard annotation.remoteID == nil,
                !annotation.isRemotePlaceholder,
                annotation.createdAt < cutoff,
                bookNoteIDs.noteID(connectionID: connectionID, bookID: book.stableId, localID: annotation.id) == nil,
                EpubLocationBridge.epubCFIForProviderUpload(from: annotation.locator) != nil
            else { continue }
            do {
                let record = try await provider.createRemoteAnnotation(for: book, annotation: annotation)
                updated.annotations[index].remoteID = record.id
                if let updatedAt = ReaderNotebookMerge.providerDate(record.updatedAt) {
                    updated.annotations[index].updatedAt = updatedAt
                }
            } catch {
                AppLogger.general.error("Failed to retry annotation upload bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
                break
            }
        }
        return updated
    }

    private func hydratingReadiumLocators(in snapshot: ReaderNotebookMerge.Snapshot) async -> ReaderNotebookMerge.Snapshot {
        guard activeReaderEngine?() == .readium,
            let fileURL = epubFileURL?(),
            EbookFormat.from(fileExtension: fileURL.pathExtension) == .epub
        else {
            return snapshot
        }

        var hydrated = snapshot
        for index in hydrated.annotations.indices {
            let annotation = hydrated.annotations[index]
            guard !EpubLocationBridge.canRestoreDirectly(annotation.locator),
                let cfi = EpubLocationBridge.epubCFI(from: annotation.locator),
                let locator = await EpubCFI.readiumLocatorJSON(
                    forCFI: cfi,
                    totalProgression: annotation.position,
                    selectedText: annotation.text,
                    epubFileURL: fileURL
                )
            else {
                continue
            }
            let marked = EpubLocationBridge.markingSourceEngine(.readium, in: locator) ?? locator
            hydrated.annotations[index].locator = EpubLocationBridge.markingEPUBCFI(cfi, in: marked) ?? marked
        }
        return hydrated
    }

    private func pullSilo(mergingInto localArtifacts: () -> ReaderNotebookMerge.Snapshot) async -> ReaderNotebookSyncOutcome {
        guard let silo = await siloContext() else { return .unchanged }
        let pullStartedAt = Date()
        do {
            let records = try await silo.provider.fetchReaderAnnotations(for: book)
            let original = localArtifacts()
            let merged = ReaderNotebookMerge.applyingSiloRecords(
                records,
                to: original,
                scope: silo.scope,
                idMap: siloIDMap
            )
            await flushSiloChanges(in: merged, createdBefore: pullStartedAt, provider: silo.provider, scope: silo.scope)
            guard localArtifacts() == original else { return .unchanged }
            return .replace(bookmarks: merged.bookmarks, annotations: merged.annotations)
        } catch {
            AppLogger.general.error("Failed to fetch Silo annotations bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
            return .unchanged
        }
    }

    private func siloContext() async -> (provider: SiloProvider, scope: SiloReaderArtifactScope)? {
        guard let provider = siloProvider else { return nil }
        do {
            return (provider, try await provider.readerArtifactScope(for: book))
        } catch {
            AppLogger.general.error("Silo reader sync unavailable bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
            return nil
        }
    }

    private func pushSiloAnnotation(_ annotation: ReaderAnnotation, provider: SiloProvider, scope: SiloReaderArtifactScope) async -> Bool {
        await pushSiloArtifact(
            localID: annotation.id,
            isBookmark: false,
            scope: scope,
            create: { try await provider.createReaderAnnotation(for: book, annotation: annotation) },
            update: { try await provider.updateReaderAnnotation(id: $0, etag: $1, for: book, annotation: annotation) }
        )
    }

    private func pushSiloBookmark(_ bookmark: Bookmark, provider: SiloProvider, scope: SiloReaderArtifactScope) async -> Bool {
        await pushSiloArtifact(
            localID: bookmark.id,
            isBookmark: true,
            scope: scope,
            create: { try await provider.createReaderBookmark(for: book, bookmark: bookmark) },
            update: { try await provider.updateReaderBookmark(id: $0, etag: $1, for: book, bookmark: bookmark) }
        )
    }

    // A stale validator parks the local edit instead of overwriting a remote revision.
    private func pushSiloArtifact(
        localID: String,
        isBookmark: Bool,
        scope: SiloReaderArtifactScope,
        create: () async throws -> SiloReaderAnnotationMutation,
        update: (_ remoteID: String, _ etag: String) async throws -> SiloReaderAnnotationRecord
    ) async -> Bool {
        if let remoteID = siloRemoteID(localID: localID, isBookmark: isBookmark, scope: scope) {
            let current = siloIDMap.artifactGuards(in: scope)[remoteID]
            if current?.state == .conflict || current?.state == .pendingDelete { return true }
            let recordedAt = Date()
            guard let etag = current?.etag, !etag.isEmpty else {
                siloIDMap.setArtifactGuard(SiloReaderArtifactGuard(etag: "", state: .pendingUpdate, recordedAt: recordedAt), remoteID: remoteID, in: scope)
                return true
            }
            siloIDMap.setArtifactGuard(.init(etag: etag, state: .pendingUpdate, recordedAt: recordedAt), remoteID: remoteID, in: scope)
            do {
                let record = try await update(remoteID, etag)
                acknowledgeSiloRecord(record, in: scope, startedAt: recordedAt)
                return true
            } catch SiloReaderAnnotationError.preconditionFailed {
                if siloIDMap.artifactGuards(in: scope)[remoteID]?.recordedAt == recordedAt {
                    siloIDMap.setArtifactGuard(.init(etag: etag, state: .conflict, recordedAt: recordedAt), remoteID: remoteID, in: scope)
                }
                AppLogger.general.info("Silo annotation changed on the server; keeping local copy bookDiagnosticID=\(bookDiagnosticID)")
                return true
            } catch SiloReaderAnnotationError.notFound {
                if siloIDMap.artifactGuards(in: scope)[remoteID]?.recordedAt == recordedAt {
                    siloIDMap.setArtifactGuard(.init(etag: etag, state: .conflict, recordedAt: recordedAt), remoteID: remoteID, in: scope)
                }
                return true
            } catch ProviderError.noCFI {
                return true
            } catch {
                AppLogger.general.error("Failed to update Silo annotation bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
                return false
            }
        }

        let createdAt = Date()
        do {
            let mutation = try await create()
            let record = mutation.record
            if siloIDMap.artifactGuards(in: scope)[record.id]?.state == .pendingDelete {
                if mutation.created { acknowledgeSiloRecord(record, in: scope, startedAt: createdAt) }
                return true
            }
            setSiloRemoteID(record.id, localID: localID, isBookmark: isBookmark, scope: scope)
            if mutation.created {
                acknowledgeSiloRecord(record, in: scope, startedAt: createdAt)
                return true
            }
            siloIDMap.setArtifactGuard(.init(etag: record.etag, state: .conflict, recordedAt: createdAt), remoteID: record.id, in: scope)
            return true
        } catch ProviderError.noCFI {
            return true
        } catch {
            AppLogger.general.error("Failed to create Silo annotation bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
            return false
        }
    }

    private func acknowledgeSiloRecord(_ record: SiloReaderAnnotationRecord, in scope: SiloReaderArtifactScope, startedAt: Date) {
        if var current = siloIDMap.artifactGuards(in: scope)[record.id],
            current.state == .pendingDelete || current.state == .conflict || current.recordedAt > startedAt
        {
            current.etag = record.etag
            siloIDMap.setArtifactGuard(current, remoteID: record.id, in: scope)
        } else {
            siloIDMap.setArtifactGuard(.init(etag: record.etag, state: .synced, recordedAt: startedAt), remoteID: record.id, in: scope)
        }
    }

    // Unmapped artifacts use their stable create ID so a lost response cannot resurrect a deletion.
    private func removeSiloArtifact(localID: String, isBookmark: Bool, provider: SiloProvider, scope: SiloReaderArtifactScope) async {
        let mappedRemoteID = siloRemoteID(localID: localID, isBookmark: isBookmark, scope: scope)
        let remoteID = mappedRemoteID ?? localID
        if mappedRemoteID != nil {
            setSiloRemoteID(nil, localID: localID, isBookmark: isBookmark, scope: scope)
        }
        let etag = siloIDMap.artifactGuards(in: scope)[remoteID]?.etag ?? ""
        siloIDMap.setArtifactGuard(SiloReaderArtifactGuard(etag: etag, state: .pendingDelete, recordedAt: Date()), remoteID: remoteID, in: scope)
        guard !etag.isEmpty else { return }
        _ = await deleteSiloTombstone(remoteID: remoteID, etag: etag, provider: provider, scope: scope)
    }

    private func deleteSiloTombstone(remoteID: String, etag: String, provider: SiloProvider, scope: SiloReaderArtifactScope) async -> Bool {
        do {
            try await provider.deleteReaderAnnotation(id: remoteID, etag: etag, for: book)
            siloIDMap.setArtifactGuard(nil, remoteID: remoteID, in: scope)
            return true
        } catch SiloReaderAnnotationError.preconditionFailed {
            return false
        } catch {
            AppLogger.general.error("Failed to delete Silo annotation bookDiagnosticID=\(bookDiagnosticID): \(error.localizedDescription)")
            return false
        }
    }

    // Retries deletions and edits that never reached the server, then uploads artifacts created before this pull.
    private func flushSiloChanges(
        in snapshot: ReaderNotebookMerge.Snapshot,
        createdBefore cutoff: Date,
        provider: SiloProvider,
        scope: SiloReaderArtifactScope
    ) async {
        for (remoteID, artifactGuard) in siloIDMap.artifactGuards(in: scope) {
            switch artifactGuard.state {
            case .pendingDelete:
                guard !artifactGuard.etag.isEmpty else { continue }
                guard await deleteSiloTombstone(remoteID: remoteID, etag: artifactGuard.etag, provider: provider, scope: scope) else { return }
            case .pendingUpdate where !artifactGuard.etag.isEmpty:
                if let annotation = snapshot.annotations.first(where: { siloRemoteID(localID: $0.id, isBookmark: false, scope: scope) == remoteID }) {
                    guard await pushSiloAnnotation(annotation, provider: provider, scope: scope) else { return }
                } else if let bookmark = snapshot.bookmarks.first(where: { siloRemoteID(localID: $0.id, isBookmark: true, scope: scope) == remoteID }) {
                    guard await pushSiloBookmark(bookmark, provider: provider, scope: scope) else { return }
                }
            case .pendingUpdate, .synced, .conflict:
                continue
            }
        }

        for annotation in snapshot.annotations
        where annotation.createdAt < cutoff
            && !annotation.isRemotePlaceholder
            && EpubLocationBridge.epubCFI(from: annotation.locator) != nil
            && siloRemoteID(localID: annotation.id, isBookmark: false, scope: scope) == nil
        {
            guard await pushSiloAnnotation(annotation, provider: provider, scope: scope) else { return }
        }
        for bookmark in snapshot.bookmarks
        where bookmark.timestamp < cutoff
            && bookmark.mediaType == .ebook
            && !bookmark.isRemotePlaceholder
            && siloRemoteID(localID: bookmark.id, isBookmark: true, scope: scope) == nil
        {
            guard await pushSiloBookmark(bookmark, provider: provider, scope: scope) else { return }
        }
    }

    private func siloRemoteID(localID: String, isBookmark: Bool, scope: SiloReaderArtifactScope) -> String? {
        isBookmark
            ? siloIDMap.bookmarkRemoteID(connectionID: scope.connectionID, bookID: scope.bookID, localID: localID)
            : siloIDMap.annotationRemoteID(connectionID: scope.connectionID, bookID: scope.bookID, localID: localID)
    }

    private func setSiloRemoteID(_ remoteID: String?, localID: String, isBookmark: Bool, scope: SiloReaderArtifactScope) {
        switch (remoteID, isBookmark) {
        case (let remoteID?, true):
            siloIDMap.setBookmarkRemoteID(remoteID, connectionID: scope.connectionID, bookID: scope.bookID, localID: localID)
        case (let remoteID?, false):
            siloIDMap.setAnnotationRemoteID(remoteID, connectionID: scope.connectionID, bookID: scope.bookID, localID: localID)
        case (nil, true):
            siloIDMap.removeBookmarkRemoteID(connectionID: scope.connectionID, bookID: scope.bookID, localID: localID)
        case (nil, false):
            siloIDMap.removeAnnotationRemoteID(connectionID: scope.connectionID, bookID: scope.bookID, localID: localID)
        }
    }

    private func syncBookOrbit() async -> ReaderNotebookSyncOutcome {
        guard allowsExternalSync, let provider = providerResolver.provider(for: book.providerId) as? BookOrbitProvider else { return .unchanged }
        _ = await bookOrbitQueue?.sync(
            book: book,
            provider: provider,
            spineHrefs: bookOrbitSpineHrefs?() ?? [:]
        )
        return .reload
    }
}
