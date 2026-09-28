import Foundation
import Testing

@testable import enve

@MainActor
struct BookOrbitArtifactMergeTests {
    private static let canonicalCFI = "epubcfi(/6/14!/4/2/2:0)"
    private static let sameSpineCFI = "epubcfi(/6/14!/4/2/8:3)"
    private static let assertedSpineCFI = "epubcfi(/6/14[chap05ref]!/4/2/2:0)"
    private static let otherCanonicalCFI = "epubcfi(/6/22!/4/2/6:12)"
    private static let partialCFI = "epubcfi(/4/2/2:0)"
    private static let chapterHref = "OEBPS/ch05.xhtml"

    @Test func cfiLessRemoteAnnotationDoesNotAdoptAnUnrelatedLocalHighlight() throws {
        let local = ReaderAnnotation(
            id: "local-1",
            bookId: "bookorbit:1",
            locator: nil,
            text: "Written on this device",
            note: "local note"
        )

        let merged = merge(
            annotations: [annotationRecord(id: 9, cfi: nil, text: "Remote highlight")],
            snapshot: snapshot(annotations: [local])
        )

        #expect(merged.annotations.count == 2)
        let kept = try #require(merged.annotations.first(where: { $0.id == "local-1" }))
        #expect(kept.text == "Written on this device")
        #expect(kept.note == "local note")
        #expect(kept.remoteID == nil)
        #expect(merged.annotations.contains(where: { $0.remoteID == 9 && $0.isRemotePlaceholder }))
    }

    @Test func remoteAnnotationStillAdoptsALocalHighlightAtTheSameCFI() {
        let local = ReaderAnnotation(
            id: "local-1",
            bookId: "bookorbit:1",
            locator: locator(cfi: Self.canonicalCFI),
            text: "Selected text"
        )

        let merged = merge(
            annotations: [annotationRecord(id: 9, cfi: Self.canonicalCFI, text: "Selected text")],
            snapshot: snapshot(annotations: [local])
        )

        #expect(merged.annotations.count == 1)
        #expect(merged.annotations[0].id == "local-1")
        #expect(merged.annotations[0].remoteID == 9)
    }

    @Test func emptyRemoteResponseKeepsArtifactsThatAlreadySynced() {
        let syncedBookmark = Bookmark(
            id: "bookmark-1",
            bookId: "bookorbit:1",
            position: 0,
            title: "Chapter 2",
            locator: locator(cfi: Self.canonicalCFI),
            mediaType: .ebook,
            remoteID: 4
        )
        let syncedAnnotation = ReaderAnnotation(
            id: "annotation-1",
            bookId: "bookorbit:1",
            locator: locator(cfi: Self.canonicalCFI),
            text: "Kept",
            remoteID: 7
        )

        let merged = merge(snapshot: snapshot(bookmarks: [syncedBookmark], annotations: [syncedAnnotation]))

        #expect(merged.bookmarks == [syncedBookmark])
        #expect(merged.annotations == [syncedAnnotation])
    }

    @Test func remoteDeletionStillPrunesWhenTheServerListedOtherArtifacts() {
        let stale = ReaderAnnotation(
            id: "annotation-1",
            bookId: "bookorbit:1",
            locator: locator(cfi: Self.canonicalCFI),
            text: "Deleted remotely",
            remoteID: 7
        )

        let merged = merge(
            annotations: [annotationRecord(id: 8, cfi: Self.otherCanonicalCFI, text: "Survivor")],
            snapshot: snapshot(annotations: [stale])
        )

        #expect(merged.annotations.map(\.remoteID) == [8])
    }

    @Test func partialRemoteCFIKeepsTheRicherLocalAnchor() {
        let rich = locator(cfi: Self.canonicalCFI)
        let local = ReaderAnnotation(
            id: "annotation-1",
            bookId: "bookorbit:1",
            locator: rich,
            text: "Anchored",
            remoteID: 7
        )

        let merged = merge(
            annotations: [annotationRecord(id: 7, cfi: Self.partialCFI, text: "Anchored")],
            snapshot: snapshot(annotations: [local])
        )

        #expect(merged.annotations[0].locator == rich)
        #expect(BookOrbitArtifactMerge.canonicalCFI(in: merged.annotations[0].locator) == Self.canonicalCFI)
        #expect(merged.annotations[0].isRemotePlaceholder == false)
    }

    @Test func partialRemoteCFIArrivesAsAPlaceholderRatherThanABrokenAnchor() {
        let merged = merge(
            annotations: [annotationRecord(id: 7, cfi: Self.partialCFI, text: "Unanchored")],
            snapshot: snapshot()
        )

        #expect(merged.annotations[0].locator == nil)
        #expect(merged.annotations[0].isRemotePlaceholder)
    }

    @Test func canonicalRemoteCFIMovesTheLocalAnchor() {
        let local = ReaderAnnotation(
            id: "annotation-1",
            bookId: "bookorbit:1",
            locator: locator(cfi: Self.canonicalCFI),
            text: "Anchored",
            remoteID: 7
        )

        let merged = merge(
            annotations: [annotationRecord(id: 7, cfi: Self.otherCanonicalCFI, text: "Anchored")],
            snapshot: snapshot(annotations: [local])
        )

        #expect(BookOrbitArtifactMerge.canonicalCFI(in: merged.annotations[0].locator) == Self.otherCanonicalCFI)
    }

    @Test func pendingDeleteIsNotResurrectedByAPull() {
        var pendingWork = BookOrbitArtifactQueue.PendingWork()
        pendingWork.deletedAnnotationRemoteIds = [7]

        let merged = merge(
            annotations: [annotationRecord(id: 7, cfi: Self.canonicalCFI, text: "Deleted here")],
            snapshot: snapshot(),
            pendingWork: pendingWork
        )

        #expect(merged.annotations.isEmpty)
    }

    @Test func pendingUpsertShieldsTheLocalCopyFromAnOlderRemoteRecord() {
        let local = ReaderAnnotation(
            id: "annotation-1",
            bookId: "bookorbit:1",
            locator: locator(cfi: Self.canonicalCFI),
            text: "Edited offline",
            note: "new note",
            remoteID: 7
        )
        var pendingWork = BookOrbitArtifactQueue.PendingWork()
        pendingWork.annotationIds = ["annotation-1"]

        let merged = merge(
            annotations: [annotationRecord(id: 7, cfi: Self.canonicalCFI, text: "Server copy")],
            snapshot: snapshot(annotations: [local]),
            pendingWork: pendingWork
        )

        #expect(merged.annotations == [local])
    }

    @Test func aPulledAnnotationAdoptsTheHrefProvenForItsSpineDocument() throws {
        let anchored = ReaderAnnotation(
            id: "annotation-1",
            bookId: "bookorbit:1",
            locator: locator(cfi: Self.canonicalCFI, href: Self.chapterHref),
            text: "Anchored here",
            remoteID: 4
        )

        let merged = merge(
            annotations: [
                annotationRecord(id: 4, cfi: Self.canonicalCFI, text: "Anchored here"),
                annotationRecord(id: 9, cfi: Self.sameSpineCFI, text: "From another device"),
            ],
            snapshot: snapshot(annotations: [anchored])
        )

        let pulled = try #require(merged.annotations.first(where: { $0.remoteID == 9 }))
        #expect(EpubLocationBridge.href(from: pulled.locator) == Self.chapterHref)
        #expect(BookOrbitArtifactMerge.canonicalCFI(in: pulled.locator) == Self.sameSpineCFI)
        #expect(pulled.isRemotePlaceholder == false)
    }

    @Test func aPulledAnnotationInAnUnprovenSpineDocumentStillKeepsItsCFI() throws {
        let anchored = ReaderAnnotation(
            id: "annotation-1",
            bookId: "bookorbit:1",
            locator: locator(cfi: Self.canonicalCFI, href: Self.chapterHref),
            text: "Anchored here",
            remoteID: 4
        )

        let merged = merge(
            annotations: [
                annotationRecord(id: 4, cfi: Self.canonicalCFI, text: "Anchored here"),
                annotationRecord(id: 9, cfi: Self.otherCanonicalCFI, text: "A chapter with nothing local"),
            ],
            snapshot: snapshot(annotations: [anchored])
        )

        let pulled = try #require(merged.annotations.first(where: { $0.remoteID == 9 }))
        #expect(EpubLocationBridge.href(from: pulled.locator) == nil)
        #expect(BookOrbitArtifactMerge.canonicalCFI(in: pulled.locator) == Self.otherCanonicalCFI)
    }

    @Test func aPulledAnnotationUsesTheOpenPublicationsSpineAndTextQuote() throws {
        let merged = merge(
            annotations: [annotationRecord(id: 9, cfi: Self.otherCanonicalCFI, text: "Rendered sentence")],
            snapshot: snapshot(),
            spineHrefs: ["/6/22": "Text/chapter-eight.xhtml"]
        )

        let pulled = try #require(merged.annotations.first)
        let locator = try #require(pulled.locator)
        #expect(EpubLocationBridge.href(from: locator) == "Text/chapter-eight.xhtml")
        #expect(locator.contains("Rendered sentence"))
    }

    @Test func anHreflessStoredAnnotationPicksUpItsHrefOnTheNextPull() throws {
        let stored = ReaderAnnotation(
            id: "annotation-1",
            bookId: "bookorbit:1",
            locator: locator(cfi: Self.canonicalCFI),
            text: "Pulled before anything was anchored",
            remoteID: 7
        )
        let anchoredBookmark = Bookmark(
            id: "bookmark-1",
            bookId: "bookorbit:1",
            position: 0,
            title: "Chapter 5",
            locator: locator(cfi: Self.assertedSpineCFI, href: Self.chapterHref),
            mediaType: .ebook,
            remoteID: 4
        )

        let merged = merge(
            annotations: [annotationRecord(id: 7, cfi: Self.canonicalCFI, text: "Pulled before anything was anchored")],
            snapshot: snapshot(bookmarks: [anchoredBookmark], annotations: [stored])
        )

        let updated = try #require(merged.annotations.first(where: { $0.remoteID == 7 }))
        #expect(EpubLocationBridge.href(from: updated.locator) == Self.chapterHref)
        #expect(EpubLocationBridge.totalProgression(from: updated.locator) == 0.4)
    }

    @Test func movingToAnotherSpineDocumentDropsTheOldDocumentsAnchor() throws {
        let local = ReaderAnnotation(
            id: "annotation-1",
            bookId: "bookorbit:1",
            locator: """
                {"href":"\(Self.chapterHref)","type":"application/xhtml+xml","locations":\
                {"cfi":"\(Self.canonicalCFI)","cssSelector":"#p12","progression":0.2,"enveSourceEngine":"foliate"},\
                "text":{"highlight":"a sentence from chapter five"}}
                """,
            text: "Moved on the server",
            remoteID: 7
        )

        let merged = merge(
            annotations: [annotationRecord(id: 7, cfi: Self.otherCanonicalCFI, text: "Moved on the server")],
            snapshot: snapshot(annotations: [local])
        )

        let moved = try #require(merged.annotations.first)
        let movedLocator = try #require(moved.locator)
        #expect(BookOrbitArtifactMerge.canonicalCFI(in: movedLocator) == Self.otherCanonicalCFI)
        #expect(EpubLocationBridge.href(from: movedLocator) == nil)
        #expect(!movedLocator.contains("cssSelector"))
        #expect(!movedLocator.contains("highlight"))
        #expect(EpubLocationBridge.canRestoreDirectly(movedLocator) == false)
    }

    @Test func audiobookBookmarksStillMatchByPosition() {
        let local = Bookmark(
            id: "bookmark-1",
            bookId: "bookorbit:1",
            position: 125,
            title: "Local title",
            mediaType: .audiobook
        )

        let merged = merge(
            bookmarks: [
                BookOrbitProvider.ReaderBookmarkRecord(
                    id: 3,
                    cfi: nil,
                    title: "Server title",
                    positionSeconds: 125.2,
                    createdAt: Date(timeIntervalSince1970: 1_000)
                )
            ],
            snapshot: snapshot(bookmarks: [local])
        )

        #expect(merged.bookmarks.count == 1)
        #expect(merged.bookmarks[0].id == "bookmark-1")
        #expect(merged.bookmarks[0].remoteID == 3)
    }

    private func merge(
        bookmarks: [BookOrbitProvider.ReaderBookmarkRecord] = [],
        annotations: [BookOrbitProvider.ReaderAnnotationRecord] = [],
        snapshot: BookOrbitArtifactMerge.Snapshot,
        pendingWork: BookOrbitArtifactQueue.PendingWork = BookOrbitArtifactQueue.PendingWork(),
        spineHrefs: [String: String] = [:]
    ) -> BookOrbitArtifactMerge.Snapshot {
        BookOrbitArtifactMerge.applying(
            bookmarks: bookmarks,
            annotations: annotations,
            to: snapshot,
            bookStableId: "bookorbit:1",
            pendingWork: pendingWork,
            spineHrefs: spineHrefs
        )
    }

    private func snapshot(
        bookmarks: [Bookmark] = [],
        annotations: [ReaderAnnotation] = []
    ) -> BookOrbitArtifactMerge.Snapshot {
        BookOrbitArtifactMerge.Snapshot(bookmarks: bookmarks, annotations: annotations)
    }

    private func annotationRecord(id: Int, cfi: String?, text: String) -> BookOrbitProvider.ReaderAnnotationRecord {
        BookOrbitProvider.ReaderAnnotationRecord(
            id: id,
            cfi: cfi,
            text: text,
            color: "#FFF59D",
            style: "highlight",
            note: nil,
            chapterTitle: nil,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func locator(cfi: String, href: String? = nil) -> String? {
        EpubLocationBridge.readiumLocator(href: href, epubCFI: cfi, fraction: 0.4, sourceEngine: .foliate)
    }
}

@MainActor
struct BookOrbitArtifactQueueTests {
    private let connectionId = UUID()

    @Test func enqueueKeepsOneEntryPerOperationAndRestartsItsBudget() {
        var queue = BookOrbitArtifactQueue()
        let operation = BookOrbitArtifactQueue.Operation.upsertAnnotation(
            connectionId: connectionId,
            bookId: "bookorbit:1",
            localId: "annotation-1"
        )
        let now = Date(timeIntervalSince1970: 10_000)

        queue.enqueue(operation)
        queue.recordFailure(operation, now: now)
        queue.enqueue(operation)

        #expect(queue.entries.count == 1)
        #expect(queue.entries[0].attempts == 0)
        #expect(queue.dueOperations(connectionId: connectionId, bookId: "bookorbit:1", now: now) == [operation])
    }

    @Test func aFailedOperationBacksOffInsteadOfRetryingImmediately() {
        var queue = BookOrbitArtifactQueue()
        let operation = BookOrbitArtifactQueue.Operation.upsertAnnotation(
            connectionId: connectionId,
            bookId: "bookorbit:1",
            localId: "annotation-1"
        )
        let now = Date(timeIntervalSince1970: 10_000)
        queue.enqueue(operation)

        let retained = queue.recordFailure(operation, now: now)

        #expect(retained)
        #expect(queue.dueOperations(connectionId: connectionId, bookId: "bookorbit:1", now: now).isEmpty)
        #expect(
            queue.dueOperations(
                connectionId: connectionId,
                bookId: "bookorbit:1",
                now: now.addingTimeInterval(BookOrbitArtifactQueue.backoff(attempts: 1))
            ) == [operation]
        )
        #expect(BookOrbitArtifactQueue.backoff(attempts: 4) > BookOrbitArtifactQueue.backoff(attempts: 1))
        #expect(BookOrbitArtifactQueue.backoff(attempts: 99) == BookOrbitArtifactQueue.backoff(attempts: 20))
    }

    @Test func aPermanentlyFailingOperationIsAbandonedAfterItsBudget() {
        var queue = BookOrbitArtifactQueue()
        let failing = BookOrbitArtifactQueue.Operation.upsertAnnotation(
            connectionId: connectionId,
            bookId: "bookorbit:1",
            localId: "annotation-1"
        )
        let healthy = BookOrbitArtifactQueue.Operation.upsertBookmark(
            connectionId: connectionId,
            bookId: "bookorbit:2",
            localId: "bookmark-1"
        )
        queue.enqueue(failing)
        queue.enqueue(healthy)

        var now = Date(timeIntervalSince1970: 10_000)
        for _ in 1..<BookOrbitArtifactQueue.maxAttempts {
            let retained = queue.recordFailure(failing, now: now)
            #expect(retained)
            now = now.addingTimeInterval(BookOrbitArtifactQueue.backoff(attempts: BookOrbitArtifactQueue.maxAttempts))
        }
        let retainedAfterBudget = queue.recordFailure(failing, now: now)

        #expect(retainedAfterBudget == false)
        #expect(queue.bookIds(connectionId: connectionId) == ["bookorbit:2"])
        #expect(queue.dueOperations(connectionId: connectionId, bookId: "bookorbit:2", now: now) == [healthy])
    }

    @Test func pendingWorkNamesOnlyTheArtifactsItShields() {
        var queue = BookOrbitArtifactQueue()
        queue.enqueue(.upsertAnnotation(connectionId: connectionId, bookId: "bookorbit:1", localId: "annotation-1"))
        queue.enqueue(.deleteAnnotation(connectionId: connectionId, bookId: "bookorbit:1", remoteId: 7))
        queue.enqueue(.upsertBookmark(connectionId: connectionId, bookId: "bookorbit:1", localId: "bookmark-1"))
        queue.enqueue(.deleteBookmark(connectionId: connectionId, bookId: "bookorbit:1", remoteId: 4))
        queue.enqueue(.upsertAnnotation(connectionId: UUID(), bookId: "bookorbit:1", localId: "other-connection"))

        let work = queue.pendingWork(connectionId: connectionId, bookId: "bookorbit:1")

        #expect(work.annotationIds == ["annotation-1"])
        #expect(work.deletedAnnotationRemoteIds == [7])
        #expect(work.bookmarkIds == ["bookmark-1"])
        #expect(work.deletedBookmarkRemoteIds == [4])
        #expect(
            queue.pendingWork(connectionId: connectionId, bookId: "bookorbit:2")
                == BookOrbitArtifactQueue.PendingWork()
        )
    }

    @Test func persistedQueueSurvivesAReload() throws {
        let defaults = try scratchDefaults(#function)
        var queue = BookOrbitArtifactQueue()
        let operation = BookOrbitArtifactQueue.Operation.deleteBookmark(
            connectionId: connectionId,
            bookId: "bookorbit:1",
            remoteId: 4
        )
        queue.enqueue(operation)
        queue.recordFailure(operation, now: Date(timeIntervalSince1970: 10_000))
        queue.persist(to: defaults)

        let reloaded = BookOrbitArtifactQueue.loaded(from: defaults)

        #expect(reloaded == queue)
        #expect(reloaded.entries[0].attempts == 1)
    }

    @Test func legacyPendingWorkMigratesWithAFreshBudget() throws {
        let defaults = try scratchDefaults(#function)
        let legacy = [
            BookOrbitArtifactQueue.Operation.upsertAnnotation(
                connectionId: connectionId,
                bookId: "bookorbit:1",
                localId: "annotation-1"
            )
        ]
        let encoded = try JSONEncoder().encode(legacy)
        defaults.set(encoded, forKey: BookOrbitArtifactQueue.legacyStorageKey)

        let queue = BookOrbitArtifactQueue.loaded(from: defaults)

        #expect(queue.entries.map(\.operation) == legacy)
        #expect(queue.entries[0].attempts == 0)

        queue.persist(to: defaults)
        #expect(defaults.data(forKey: BookOrbitArtifactQueue.legacyStorageKey) == nil)
        #expect(BookOrbitArtifactQueue.loaded(from: defaults) == queue)
    }

    private func scratchDefaults(_ name: String) throws -> UserDefaults {
        let suite = "BookOrbitArtifactQueueTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
