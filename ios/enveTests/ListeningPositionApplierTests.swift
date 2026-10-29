import Foundation
import Testing

@testable import enve

@MainActor
private final class ProgressTargetStub: ListeningPositionProgressTarget {
    enum Call: Equatable {
        case seek(TimeInterval)
        case applyLocally(String, TimeInterval, Date)
        case pending(String, TimeInterval)
        case push(String, TimeInterval)
    }

    var reloadedBook: Book?
    var loadedUniqueId: String?
    var route = ListeningPositionServerRoute.server
    var pushStatus = ListeningPositionServerStatus.saved
    var holdsFirstPush = false
    private(set) var calls: [Call] = []
    private var heldPush: CheckedContinuation<Void, Never>?

    func reload(_ book: Book) async -> Book { reloadedBook ?? book }

    func loadedBookUniqueId() -> String? { loadedUniqueId }

    func seekLoadedBook(to position: TimeInterval) {
        calls.append(.seek(position))
    }

    func applyLocally(_ book: Book, payload: ListeningPositionPayload, isFinished: Bool, at date: Date) async -> Book {
        let position = payload.readingLocation?.progression(for: book) ?? payload.position
        calls.append(.applyLocally(book.uniqueId, position, date))
        var updated = book
        if let reading = payload.readingLocation {
            updated.ebookProgress = reading.progression(for: book)
            updated.epubLocator = reading.locatorJSON(for: book)
        } else { updated.currentTime = position }
        updated.isFinished = isFinished
        updated.lastUpdate = date
        return updated
    }

    func serverRoute(for book: Book) -> ListeningPositionServerRoute { route }

    func recordPendingServerWrite(_ book: Book, payload: ListeningPositionPayload, isFinished: Bool) {
        calls.append(.pending(book.uniqueId, payload.readingLocation?.progression(for: book) ?? payload.position))
    }

    func pushToServer(_ book: Book, payload: ListeningPositionPayload, isFinished: Bool) async -> ListeningPositionServerStatus {
        calls.append(.push(book.uniqueId, payload.readingLocation?.progression(for: book) ?? payload.position))
        if holdsFirstPush {
            holdsFirstPush = false
            await withCheckedContinuation { heldPush = $0 }
        }
        return pushStatus
    }

    var isHoldingPush: Bool { heldPush != nil }

    func releasePush() {
        heldPush?.resume()
        heldPush = nil
    }
}

@MainActor
struct ListeningPositionApplierTests {
    private let acceptedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func loadedBookIsSeekedBeforeLocalAndServerWrites() async throws {
        let book = makeBook(duration: 7200)
        let target = ProgressTargetStub()
        target.loadedUniqueId = book.uniqueId
        let applier = ListeningPositionApplier(target: target, now: { acceptedAt })

        let result = try await applier.apply(try payload(positionMs: 1_234_000), to: book)

        #expect(target.calls == [
            .seek(1234),
            .applyLocally(book.uniqueId, 1234, acceptedAt),
            .pending(book.uniqueId, 1234),
            .push(book.uniqueId, 1234),
        ])
        #expect(result.server == .saved)
        #expect(result.book.currentTime == 1234)
        #expect(result.book.lastUpdate == acceptedAt)
    }

    @Test func idleBookIsUpdatedWithoutTouchingThePlayer() async throws {
        let book = makeBook(duration: 7200)
        let target = ProgressTargetStub()
        target.loadedUniqueId = makeBook(duration: 100).uniqueId
        target.pushStatus = .queued

        let result = try await ListeningPositionApplier(target: target, now: { acceptedAt })
            .apply(try payload(positionMs: 60_000), to: book)

        #expect(!target.calls.contains { if case .seek = $0 { true } else { false } })
        #expect(result.server == .queued)
    }

    @Test(arguments: [
        (ListeningPositionServerRoute.noServer, ListeningPositionServerStatus.noServer),
        (.syncDisabled, .syncDisabled),
    ])
    func localOnlyRoutesNeverQueueOrClaimServerSuccess(route: ListeningPositionServerRoute, expected: ListeningPositionServerStatus) async throws {
        let book = makeBook(duration: 7200)
        let target = ProgressTargetStub()
        target.route = route

        let result = try await ListeningPositionApplier(target: target, now: { acceptedAt })
            .apply(try payload(positionMs: 60_000), to: book)

        #expect(target.calls == [.applyLocally(book.uniqueId, 60, acceptedAt)])
        #expect(result.server == expected)
    }

    @Test func rejectedServerUpdateIsReportedHonestly() async throws {
        let target = ProgressTargetStub()
        target.pushStatus = .rejected("Position exceeds duration")

        let result = try await ListeningPositionApplier(target: target, now: { acceptedAt })
            .apply(try payload(positionMs: 60_000), to: makeBook(duration: 7200))

        #expect(result.server == .rejected("Position exceeds duration"))
    }

    @Test func positionsPastTheEndAndNonAudiobooksAreRefusedBeforeAnyWrite() async throws {
        let target = ProgressTargetStub()
        let applier = ListeningPositionApplier(target: target, now: { acceptedAt })
        let shared = try payload(positionMs: 7_300_000)

        await #expect(throws: ListeningPositionApplyError.positionBeyondEnd) {
            try await applier.apply(shared, to: makeBook(duration: 7200))
        }
        await #expect(throws: ListeningPositionApplyError.incompatibleMedia) {
            try await applier.apply(shared, to: makeBook(duration: 9000, mediaType: .ebook))
        }
        #expect(target.calls.isEmpty)
    }

    @Test func unknownLengthCopyStillAcceptsTheConfirmedPosition() async throws {
        let target = ProgressTargetStub()
        let result = try await ListeningPositionApplier(target: target, now: { acceptedAt })
            .apply(try payload(positionMs: 7_300_000), to: makeBook(duration: nil))
        #expect(result.position == 7300)
        #expect(result.book.isFinished == false)
    }

    @Test func positionAtTheEndMarksTheCopyFinished() async throws {
        let target = ProgressTargetStub()
        let result = try await ListeningPositionApplier(target: target, now: { acceptedAt })
            .apply(try payload(positionMs: 7_200_000), to: makeBook(duration: 7200))
        #expect(result.book.isFinished)
    }

    @Test func secondAcceptanceForTheSameBookWaitsForTheFirst() async throws {
        let book = makeBook(duration: 7200)
        let target = ProgressTargetStub()
        target.holdsFirstPush = true
        let applier = ListeningPositionApplier(target: target, now: { acceptedAt })
        let first = try payload(positionMs: 100_000)
        let second = try payload(positionMs: 200_000)

        let firstTask = Task { try await applier.apply(first, to: book) }
        while !target.isHoldingPush { await Task.yield() }
        let secondTask = Task { try await applier.apply(second, to: book) }
        for _ in 0..<20 { await Task.yield() }

        #expect(!target.calls.contains(.applyLocally(book.uniqueId, 200, acceptedAt)))

        target.releasePush()
        _ = try await firstTask.value
        _ = try await secondTask.value

        #expect(target.calls == [
            .applyLocally(book.uniqueId, 100, acceptedAt),
            .pending(book.uniqueId, 100),
            .push(book.uniqueId, 100),
            .applyLocally(book.uniqueId, 200, acceptedAt),
            .pending(book.uniqueId, 200),
            .push(book.uniqueId, 200),
        ])
    }

    @Test func readingRewindClearsTheOldLocatorAndFinishedStateWithoutSeekingAudio() async throws {
        var book = makeBook(duration: nil, mediaType: .ebook)
        book.ebookFormat = "epub"
        book.ebookProgress = 1
        book.epubLocator = #"{"href":"old.xhtml","locations":{"totalProgression":1}}"#
        book.isFinished = true
        let target = ProgressTargetStub()
        target.loadedUniqueId = book.uniqueId
        target.pushStatus = .queued
        let payload = try ListeningPositionPayload(
            positionMilliseconds: 0, durationMilliseconds: 0, title: "A Book",
            readingLocation: ListeningPositionReadingLocation(format: "epub", progressionUnits: 0)
        )
        let result = try await ListeningPositionApplier(target: target).apply(payload, to: book)
        #expect(result.book.ebookProgress == 0)
        #expect(result.book.epubLocator?.contains("old.xhtml") == false)
        #expect(result.book.epubLocator?.contains("enveSharedPosition") == true)
        #expect(!result.book.isFinished)
        #expect(result.server == .queued)
        #expect(!target.calls.contains { if case .seek = $0 { true } else { false } })
    }

    @Test func acceptedPageOverridesTheOtherEditionsPercentageOnRestore() throws {
        var book = makeBook(duration: nil, mediaType: .ebook)
        book.ebookFormat = "pdf"
        let reading = try ListeningPositionReadingLocation(format: "pdf", progressionUnits: 800_000, page: 8)
        book.epubLocator = reading.locatorJSON(for: book)
        book.ebookProgress = reading.progression
        #expect(ReaderLocatorProgress.restorePDFPageIndex(book: book, totalPages: 200) == 7)
    }

    @Test func pageBoundsUseTheFreshCopyInsideTheSerializedAcceptance() async throws {
        var selected = makeBook(duration: nil, mediaType: .ebook)
        selected.ebookFormat = "cbz"
        var fresh = selected
        fresh.comicMetadata = ComicMetadata(seriesID: "series", pageCount: 8)
        let target = ProgressTargetStub()
        target.reloadedBook = fresh
        let payload = try ListeningPositionPayload(
            positionMilliseconds: 0, durationMilliseconds: 0, title: "A Book",
            readingLocation: ListeningPositionReadingLocation(format: "comic", progressionUnits: 500_000, page: 10)
        )
        await #expect(throws: ListeningPositionApplyError.positionBeyondEnd) {
            try await ListeningPositionApplier(target: target).apply(payload, to: selected)
        }
        #expect(target.calls.isEmpty)
    }

    @Test func readingAcceptancePersistsOnlyTheSelectedCopyInTheActiveProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "shared-reading-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let profile = FamilyProfile(id: UUID().uuidString, name: "Reader", role: .adult)
        let storage = ProfileStorageLocations(
            profileID: profile.id, documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("Support"),
            cachesDirectory: root.appendingPathComponent("Caches")
        )
        let session = try ProfileSession(profile: profile, storage: storage, defaults: defaults)
        var book = Book(id: "reading-copy", title: "A Book", source: .local, mediaType: .ebook)
        book.ebookFormat = "epub"
        book.ebookProgress = 1
        book.isFinished = true
        book.serverReadStatus = "READ"
        book.epubLocator = #"{"href":"old.xhtml","locations":{"totalProgression":1}}"#
        let other = Book(id: "other-copy", title: "A Book", source: .local, mediaType: .ebook)
        await session.bookStore.upsertBooks([book, other])
        let payload = try ListeningPositionPayload(
            positionMilliseconds: 0, durationMilliseconds: 0, title: "A Book",
            readingLocation: ListeningPositionReadingLocation(
                format: "epub", progressionUnits: 250_000, href: "chapter2.xhtml", resourceProgressionUnits: 500_000
            )
        )
        _ = try await ListeningPositionApplier(target: LiveListeningPositionProgressTarget(session: session)).apply(payload, to: book)
        let saved = try #require(await session.bookStore.book(uniqueId: book.uniqueId))
        #expect(saved.ebookProgress == 0.25)
        #expect(saved.epubLocator?.contains("chapter2.xhtml") == true)
        #expect(!saved.isFinished)
        #expect(saved.serverReadStatus == "RE_READING")
        #expect(await session.bookStore.book(uniqueId: other.uniqueId)?.ebookProgress == nil)
        #expect(session.pendingSync.entries.isEmpty)
        await session.retire()
    }

    private func payload(positionMs: Int64) throws -> ListeningPositionPayload {
        try ListeningPositionPayload(positionMilliseconds: positionMs, durationMilliseconds: 7_300_000, title: "Shared Book")
    }

    private func makeBook(duration: TimeInterval?, mediaType: AppMediaType = .audiobook) -> Book {
        Book(
            id: UUID().uuidString,
            ratingKey: "",
            title: "Local Copy",
            duration: duration,
            source: .audiobookshelf,
            backendId: "server",
            mediaType: mediaType,
            providerId: UUID(),
            libraryId: "library"
        )
    }
}
