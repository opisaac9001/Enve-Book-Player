import Combine
import Foundation
import Testing

@testable import enve

@MainActor
struct PlaybackQueuePolicyTests {
    @Test func playAllUsesUnfinishedAudioWhenAnyRemain() {
        let providerID = UUID()
        let books = [
            book("finished", providerID: providerID, isFinished: true),
            book("next", providerID: providerID),
            book("ebook", providerID: providerID, mediaType: .ebook),
            book("later", providerID: providerID, currentTime: 40, duration: 100),
        ]

        #expect(PlaybackQueuePolicy.playAllCandidates(books).map(\.id) == ["next", "later"])
    }

    @Test func playAllIncludesCompletedAudioWhenEverythingIsFinished() {
        let providerID = UUID()
        let books = [
            book("one", providerID: providerID, isFinished: true),
            book("two", providerID: providerID, currentTime: 100, duration: 100),
        ]

        #expect(PlaybackQueuePolicy.playAllCandidates(books).map(\.id) == ["one", "two"])
    }

    @Test func playAllKeepsTheFirstCopyOfEachBook() {
        let providerID = UUID()
        let books = [
            book("one", providerID: providerID),
            book("two", providerID: providerID),
            book("one", providerID: providerID),
        ]

        #expect(PlaybackQueuePolicy.playAllCandidates(books).map(\.id) == ["one", "two"])
    }

    private func book(
        _ id: String,
        providerID: UUID,
        mediaType: AppMediaType = .audiobook,
        currentTime: TimeInterval = 0,
        duration: TimeInterval = 600,
        isFinished: Bool = false
    ) -> Book {
        Book(
            id: id,
            title: id,
            duration: duration,
            mediaType: mediaType,
            currentTime: currentTime,
            isFinished: isFinished,
            providerId: providerID,
            libraryId: "library"
        )
    }
}

@MainActor
private final class BookPlaybackStarterSpy: BookPlaybackStarting {
    private(set) var started: [(book: Book, presentPlayer: Bool)] = []

    func play(_ book: Book, presentPlayer: Bool) {
        started.append((book, presentPlayer))
    }
}

@MainActor
private final class FakePlaybackController: PlaybackControlling, PlaybackEventPublishing {
    private let snapshotSubject = CurrentValueSubject<PlaybackSnapshot, Never>(.idle)
    private let eventSubject = PassthroughSubject<PlaybackEvent, Never>()

    let ownsProgressPersistence = false

    var snapshot: PlaybackSnapshot { snapshotSubject.value }
    var snapshots: AnyPublisher<PlaybackSnapshot, Never> { snapshotSubject.eraseToAnyPublisher() }
    var playbackEvents: AnyPublisher<PlaybackEvent, Never> { eventSubject.eraseToAnyPublisher() }

    func becomeActive(with book: Book, isLoading: Bool = false) {
        snapshotSubject.send(
            PlaybackSnapshot(
                currentBook: book,
                isPlaying: !isLoading,
                position: 0,
                duration: book.duration ?? 0,
                playbackSpeed: 1,
                volume: 1,
                isLoaded: !isLoading,
                isLoading: isLoading,
                isOverlayPlaybackActive: false,
                errorDescription: nil
            )
        )
    }

    func send(_ event: PlaybackEvent) {
        eventSubject.send(event)
    }

    func play() {}
    func pause() {}
    func stop() {}
    func togglePlay() {}
    func seek(to time: TimeInterval) {}
    func skipForward(seconds: TimeInterval) {}
    func skipBackward(seconds: TimeInterval) {}
    func setPlaybackRate(_ rate: Double) {}
    func setVolume(_ volume: Double) {}
    func fadeOutAndPause(duration: TimeInterval, steps: Int) async {}
}

@MainActor
@Suite(.serialized)
struct PlaybackQueueRoutingTests {
    @Test func manualStartRoutesThroughInjectedBookStarter() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let book = makeBook("manual-start")

        fixture.queue.playManually(book, presentPlayer: false)
        await waitUntil { !fixture.starter.started.isEmpty }

        #expect(fixture.starter.started.count == 1)
        #expect(fixture.starter.started.first?.book.uniqueId == book.uniqueId)
        #expect(fixture.starter.started.first?.presentPlayer == false)
    }

    @Test func playAllStartsFirstQueuedBookThroughInjectedBookStarter() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let first = makeBook("queued-first")
        let second = makeBook("queued-second")

        #expect(fixture.queue.playAll([first, second]))
        await waitUntil { !fixture.starter.started.isEmpty }

        #expect(fixture.starter.started.count == 1)
        #expect(fixture.starter.started.first?.book.uniqueId == first.uniqueId)
        #expect(fixture.starter.started.first?.presentPlayer == true)
        #expect(fixture.queue.entries.map(\.book.id) == [second.id])
    }

    @Test func manualPlayOfADifferentBookClearsTheQueue() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let playing = makeBook("playing")
        let queued = makeBook("queued")
        fixture.controller.becomeActive(with: playing)
        fixture.store.addLast(queued)

        fixture.queue.playManually(makeBook("other"), presentPlayer: false)

        #expect(fixture.queue.entries.isEmpty)
    }

    @Test func manualPlayOfTheActiveBookKeepsTheQueue() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let playing = makeBook("playing")
        let queued = makeBook("queued")
        fixture.controller.becomeActive(with: playing)
        fixture.store.addLast(queued)

        fixture.queue.playManually(playing, presentPlayer: false)

        #expect(fixture.queue.entries.map(\.book.id) == [queued.id])
    }

    @Test func addNextQueuesBehindActivePlaybackReportedByTheController() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.controller.becomeActive(with: makeBook("playing"))
        fixture.store.addLast(makeBook("tail"))

        fixture.queue.addNext(makeBook("jumped"))

        #expect(fixture.queue.entries.map(\.book.id) == ["jumped", "tail"])
        #expect(fixture.starter.started.isEmpty)
    }

    @Test func addLastAppendsBehindActivePlaybackReportedByTheController() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.controller.becomeActive(with: makeBook("playing"))
        fixture.store.addLast(makeBook("tail"))

        fixture.queue.addLast(makeBook("appended"))

        #expect(fixture.queue.entries.map(\.book.id) == ["tail", "appended"])
        #expect(fixture.starter.started.isEmpty)
    }

    @Test func loadingControllerStateStillCountsAsActivePlayback() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.controller.becomeActive(with: makeBook("loading"), isLoading: true)

        fixture.queue.addNext(makeBook("queued"))

        #expect(fixture.queue.entries.map(\.book.id) == ["queued"])
        #expect(fixture.starter.started.isEmpty)
    }

    @Test func addNextStartsPlaybackWhenTheControllerReportsNothingActive() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let book = makeBook("idle-start")

        fixture.queue.addNext(book)
        await waitUntil { !fixture.starter.started.isEmpty }

        #expect(fixture.starter.started.map(\.book.uniqueId) == [book.uniqueId])
        #expect(fixture.queue.entries.isEmpty)
    }

    @Test func completionEventStartsTheNextQueuedBookAndPreservesPresentation() async throws {
        let fixture = try makeFixture(continuousPlayback: true)
        defer { fixture.tearDown() }
        let playing = makeBook("finishing")
        let next = makeBook("up-next")
        fixture.controller.becomeActive(with: playing)
        fixture.store.addLast(next)

        let presentation = AppState.shared.presentation
        let originalPresented = presentation.isPlayerPresented
        presentation.isPlayerPresented = true
        defer { presentation.isPlayerPresented = originalPresented }

        fixture.controller.send(.completed(playing))
        await waitUntil { !fixture.starter.started.isEmpty }

        #expect(fixture.starter.started.map(\.book.uniqueId) == [next.uniqueId])
        #expect(fixture.starter.started.first?.presentPlayer == true)
        #expect(fixture.queue.entries.isEmpty)
    }

    @Test func completionEventDoesNotAdvanceWhenContinuousPlaybackIsOff() async throws {
        let fixture = try makeFixture(continuousPlayback: false)
        defer { fixture.tearDown() }
        let playing = makeBook("finishing")
        let next = makeBook("up-next")
        fixture.controller.becomeActive(with: playing)
        fixture.store.addLast(next)

        fixture.controller.send(.completed(playing))
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(fixture.starter.started.isEmpty)
        #expect(fixture.queue.entries.map(\.book.id) == [next.id])
    }

    @Test func completionEventForABookTheControllerIsNoLongerPlayingIsIgnored() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let stale = makeBook("stale-completion")
        let next = makeBook("still-queued")
        fixture.controller.becomeActive(with: makeBook("current"))
        fixture.store.addLast(next)

        fixture.controller.send(.completed(stale))
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(fixture.starter.started.isEmpty)
        #expect(fixture.queue.entries.map(\.book.id) == [next.id])
    }

    @Test func completedBookNoLongerCountsAsActivePlayback() async throws {
        let fixture = try makeFixture(continuousPlayback: true)
        defer { fixture.tearDown() }
        let playing = makeBook("finished")
        fixture.controller.becomeActive(with: playing)

        fixture.controller.send(.completed(playing))
        fixture.queue.addNext(makeBook("after-completion"))
        await waitUntil { !fixture.starter.started.isEmpty }

        #expect(fixture.starter.started.map(\.book.id) == ["after-completion"])
        #expect(fixture.queue.entries.isEmpty)
    }

    @Test func failureEventStartsTheNextQueuedBook() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let playing = makeBook("failing")
        let next = makeBook("recovery")
        fixture.controller.becomeActive(with: playing)
        fixture.store.addLast(next)

        fixture.controller.send(.failed(playing))
        await waitUntil { !fixture.starter.started.isEmpty }

        #expect(fixture.starter.started.map(\.book.uniqueId) == [next.uniqueId])
        #expect(fixture.queue.entries.isEmpty)
    }

    @Test func duplicateFailureEventsAdvanceOnlyOnce() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let playing = makeBook("failing-once")
        let first = makeBook("first-recovery")
        let second = makeBook("second-recovery")
        fixture.controller.becomeActive(with: playing)
        fixture.store.addLast(first)
        fixture.store.addLast(second)

        fixture.controller.send(.failed(playing))
        fixture.controller.send(.failed(playing))
        await waitUntil { !fixture.starter.started.isEmpty }

        #expect(fixture.starter.started.map(\.book.id) == [first.id])
        #expect(fixture.queue.entries.map(\.book.id) == [second.id])
    }

    @Test func failureEventForABookTheControllerIsNoLongerPlayingIsIgnored() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let stale = makeBook("stale")
        let next = makeBook("still-queued")
        fixture.controller.becomeActive(with: makeBook("current"))
        fixture.store.addLast(next)

        fixture.controller.send(.failed(stale))
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(fixture.starter.started.isEmpty)
        #expect(fixture.queue.entries.map(\.book.id) == [next.id])
    }

    @Test func failureEventSupersededByANewBookDoesNotAdvance() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let failing = makeBook("superseded")
        let next = makeBook("untouched")
        fixture.controller.becomeActive(with: failing)
        fixture.store.addLast(next)

        fixture.controller.send(.failed(failing))
        fixture.controller.becomeActive(with: makeBook("replacement"))
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(fixture.starter.started.isEmpty)
        #expect(fixture.queue.entries.map(\.book.id) == [next.id])
    }

    @Test func playQueuedReQueuesTheUnfinishedBookTheControllerWasPlaying() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let playing = makeBook("interrupted")
        let selected = makeBook("selected")
        fixture.controller.becomeActive(with: playing)
        fixture.store.addLast(selected)

        fixture.queue.playQueued(bookID: selected.uniqueId)
        await waitUntil { !fixture.starter.started.isEmpty }

        #expect(fixture.starter.started.map(\.book.uniqueId) == [selected.uniqueId])
        #expect(fixture.queue.entries.map(\.book.id) == [playing.id])
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private struct Fixture {
        let directory: URL
        let store: PlaybackQueueStore
        let controller: FakePlaybackController
        let starter: BookPlaybackStarterSpy
        let queue: PlaybackQueueCoordinator
        let originalPreferences: UserPreferences

        func tearDown() {
            LibraryDisplayPreferencesStore.shared.savePreferences(originalPreferences)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture(continuousPlayback: Bool = true) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-queue-routing-tests-\(UUID().uuidString)", isDirectory: true)
        let store = PlaybackQueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        let controller = FakePlaybackController()
        let starter = BookPlaybackStarterSpy()
        let queue = PlaybackQueueCoordinator(
            playback: controller,
            playbackEvents: controller,
            playbackStarter: starter,
            store: store
        )

        let preferencesStore = LibraryDisplayPreferencesStore.shared
        let original = preferencesStore.loadPreferences()
        var updated = original
        updated.continuousPlaybackEnabled = continuousPlayback
        updated.autoPlayNextInSeries = false
        preferencesStore.savePreferences(updated)

        return Fixture(
            directory: directory,
            store: store,
            controller: controller,
            starter: starter,
            queue: queue,
            originalPreferences: original
        )
    }

    private func makeBook(_ id: String) -> Book {
        Book(
            id: id,
            title: id,
            duration: 600,
            providerId: UUID(),
            libraryId: "library"
        )
    }
}

@MainActor
struct PlaybackQueueStoreTests {
    @Test func queueMutationsPreserveOrderAndUniqueness() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let books = makeBooks()
        fixture.store.replace(with: books, origin: .playAll, groupKey: "series:test")
        fixture.store.addNext(books[2])
        fixture.store.addLast(books[0])
        fixture.store.move(bookID: books[0].uniqueId, by: -1)

        #expect(fixture.store.entries.map(\.book.id) == ["three", "one", "two"])
        #expect(fixture.store.takeNext()?.book.id == "three")
        #expect(fixture.store.entries.map(\.book.id) == ["one", "two"])

        fixture.store.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(fixture.store.entries.map(\.book.id) == ["two", "one"])
    }

    @Test func queueSurvivesStoreRecreation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.store.replace(with: makeBooks(), origin: .playAll, groupKey: "author:test")
        let restored = PlaybackQueueStore(fileURL: fixture.file)

        #expect(restored.entries.map(\.book.id) == ["one", "two", "three"])
        #expect(restored.entries.allSatisfy { $0.origin == .playAll })
        #expect(restored.entries.allSatisfy { $0.groupKey == "author:test" })
    }

    private func makeFixture() throws -> (directory: URL, file: URL, store: PlaybackQueueStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-queue-tests-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("queue.json")
        return (directory, file, PlaybackQueueStore(fileURL: file))
    }

    private func makeBooks() -> [Book] {
        let providerID = UUID()
        return ["one", "two", "three"].map {
            Book(
                id: $0,
                title: $0,
                duration: 600,
                providerId: providerID,
                libraryId: "library"
            )
        }
    }
}
