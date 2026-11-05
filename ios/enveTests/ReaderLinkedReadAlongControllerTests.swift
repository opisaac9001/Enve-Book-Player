import Combine
import Foundation
@preconcurrency import ReadiumShared
import StoryAlignCore
import Testing
import UIKit
@testable import enve
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ReaderLinkedReadAlongControllerTests {
    typealias Fixture = PassageAlignmentServiceTests.Fixture

    @Test func listenFromHereSeeksTheLoadedAudiobookToTheVisibleSentence() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        reader.transport.load(fixture.audiobook, position: 40, isPlaying: false)

        #expect(await reader.controller.listenFromHere() == .started)
        #expect(reader.transport.seeks == [10])
        #expect(reader.transport.plays == 1)
        #expect(reader.engine.locatorRequests == 1)
        #expect(reader.controller.isFollowRequested)
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test(arguments: [(false, false), (false, true), (true, true)])
    func listenFromHereStartsAtTheExactSentenceWhenTheNamedAudiobookIsNotReady(isLoaded: Bool, isLoading: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        final class Starts { var books: [String] = []; var times: [TimeInterval] = [] }
        let starts = Starts()
        let reader = try await Reader(fixture: fixture, startAudiobookAtPosition: {
            starts.books.append($0.stableId)
            starts.times.append($1)
        })
        reader.transport.load(fixture.audiobook, position: 40, isPlaying: false, isLoaded: isLoaded, isLoading: isLoading)

        #expect(await reader.controller.listenFromHere() == .started)
        #expect(starts.books == [fixture.audiobook.stableId])
        #expect(starts.times == [10])
        #expect(reader.transport.commands == 0)
        #expect(reader.controller.isFollowRequested)
        reader.controller.retire()
        await fixture.session.retire()
    }

    @Test func anOlderTapResumingAfterItsVisibleTextLookupNeverActs() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        reader.transport.load(fixture.audiobook, position: 40, isPlaying: true)
        let lookup = PassageAlignmentServiceTests.Gate()
        reader.engine.nextLocatorGate = lookup

        let older = Task { await reader.controller.listenFromHere() }
        try await fixture.until { reader.engine.locatorRequests == 1 }
        #expect(await reader.controller.listenFromHere() == .started)
        lookup.open()
        #expect(await older.value == .cancelled)
        #expect(reader.transport.seeks == [10])
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test func dismissalOrCancellationMakesAPendingListenSilentAndInert() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()

        let dismissedReader = try await Reader(fixture: fixture)
        dismissedReader.transport.load(fixture.audiobook, position: 40, isPlaying: false)
        let dismissedLookup = PassageAlignmentServiceTests.Gate()
        dismissedReader.engine.nextLocatorGate = dismissedLookup
        let dismissed = Task { await dismissedReader.controller.listenFromHere() }
        try await fixture.until { dismissedReader.engine.locatorRequests == 1 }
        dismissedReader.controller.retire()
        dismissedLookup.open()
        #expect(await dismissed.value == .cancelled)

        let cancelledReader = try await Reader(fixture: fixture)
        cancelledReader.transport.load(fixture.audiobook, position: 40, isPlaying: false)
        let cancelledLookup = PassageAlignmentServiceTests.Gate()
        cancelledReader.engine.nextLocatorGate = cancelledLookup
        let cancelled = Task { await cancelledReader.controller.listenFromHere() }
        try await fixture.until { cancelledReader.engine.locatorRequests == 1 }
        cancelled.cancel()
        cancelledLookup.open()
        #expect(await cancelled.value == .cancelled)

        for reader in [dismissedReader, cancelledReader] {
            #expect(reader.transport.seeks.isEmpty)
            #expect(reader.transport.plays == 0)
            #expect(!reader.controller.isFollowRequested)
        }
        await fixture.session.retire()
    }

    @Test func dismissalWhileTheSessionStartsNeverActsOnTheLateExactMatch() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.narrateSentence()
        let reader = try await Reader(fixture: fixture)
        reader.transport.load(fixture.audiobook, position: 40, isPlaying: false)

        let listen = Task { await reader.controller.listenFromHere() }
        try await fixture.until { fixture.builds == 1 }
        reader.controller.retire()
        fixture.startup.open()
        #expect(await listen.value == .cancelled)
        // The service still found the sentence; only the dismissed reader ignored it.
        #expect(await fixture.findNarratedSentence(with: fixture.service).isMatched)
        #expect(reader.transport.seeks.isEmpty)
        #expect(reader.transport.plays == 0)
        await fixture.session.retire()
    }

    @Test func unlinkingWhileTheReaderIsOpenStopsListenBeforeTransport() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        reader.transport.load(fixture.audiobook, position: 40, isPlaying: false)

        // The effects of LibraryEngine.unlinkAudiobook: the in-memory link clears, then the stored one.
        _ = fixture.session.appState.libraryCache.mutateBook(uniqueId: fixture.ebook.uniqueId) { $0.linkedAudiobookStableId = nil }
        fixture.session.playback.linker.invalidateCache()
        await fixture.session.bookStore.removeLink(ebookStableId: fixture.ebook.stableId)
        #expect(await reader.controller.listenFromHere() == .cancelled)
        #expect(reader.transport.seeks.isEmpty)
        #expect(reader.transport.plays == 0)
        #expect(!reader.controller.isAvailable)
        await fixture.session.retire()
    }

    @Test func followingUsesTheEngineAdapterAndUserNavigationStopsPageTurnsUntilResumed() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture, color: .purple)
        let narrated = try #require(await fixture.service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 12).handoffMapping)
        let following = try #require(await fixture.service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 16).handoffMapping)
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)

        reader.controller.startFollowing()
        try await fixture.until { reader.engine.follows == [narrated.locatorJSON] }
        #expect(reader.engine.decorations.last?.locatorJSON == narrated.locatorJSON)
        #expect(reader.engine.decorations.allSatisfy { $0.color == .purple })
        #expect(reader.engine.ttsDecorations == 0)
        #expect(!reader.controller.isMovingPage)

        reader.engine.visibleLocatorJSON = try Self.lineLocatorJSON("The tide had turned before dawn.", progression: 0.05)
        reader.controller.userDidNavigate()
        #expect(reader.controller.status == .browsing)
        reader.transport.load(fixture.audiobook, position: 16, isPlaying: true)
        try await fixture.until { reader.engine.decorations.last?.locatorJSON == following.locatorJSON }
        try await Task.sleep(for: .milliseconds(300))
        #expect(reader.engine.follows == [narrated.locatorJSON])

        reader.controller.resumeFollowing()
        try await fixture.until { reader.engine.follows == [narrated.locatorJSON, following.locatorJSON] }

        // A gap is shown as a gap, never as the neighboring sentence.
        reader.transport.load(fixture.audiobook, position: 200, isPlaying: false)
        try await fixture.until { reader.engine.decorations.last.map { $0.locatorJSON == nil } == true }
        #expect(reader.controller.highlighted == nil)
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test(arguments: [false, true])
    func stoppingOrRetiringDuringAPageTurnLeavesNoLaterHighlightOrPageTurn(retire: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        let narrated = try #require(await fixture.service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 12).handoffMapping)
        let pageTurn = PassageAlignmentServiceTests.Gate()
        reader.engine.nextFollowGate = pageTurn
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)

        reader.controller.startFollowing()
        try await fixture.until { reader.engine.follows == [narrated.locatorJSON] }
        #expect(reader.controller.isMovingPage)
        if retire { reader.controller.retire() } else { reader.controller.stopFollowing() }
        reader.transport.load(fixture.audiobook, position: 16, isPlaying: true)
        pageTurn.open()
        try await Task.sleep(for: .milliseconds(700))

        // The page turn already issued completes; nothing new is highlighted or turned afterwards.
        #expect(reader.engine.follows == [narrated.locatorJSON])
        #expect(reader.engine.decorations.map(\.locatorJSON) == [narrated.locatorJSON, nil])
        #expect(!reader.controller.isFollowRequested)
        #expect(!reader.controller.isMovingPage)
        #expect(reader.engine.ttsDecorations == 0)
        await fixture.session.retire()
    }

    @Test func aHighlightQueuedBehindASlowDecorationIsDroppedWhenFollowingStops() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        let narrated = try #require(await fixture.service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 12).handoffMapping)
        let following = try #require(await fixture.service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 16).handoffMapping)
        let slowDecoration = PassageAlignmentServiceTests.Gate()
        reader.engine.nextDecorationGate = slowDecoration
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)

        reader.controller.startFollowing()
        try await fixture.until { reader.engine.decorations.count == 1 }
        reader.transport.load(fixture.audiobook, position: 16, isPlaying: true)
        try await fixture.until { reader.controller.highlighted?.key == following.key }
        reader.controller.stopFollowing()
        slowDecoration.open()
        try await fixture.until { reader.engine.decorations.count == 2 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(reader.engine.decorations.map(\.locatorJSON) == [narrated.locatorJSON, nil])
        await fixture.session.retire()
    }

    @Test(arguments: [false, true])
    func aQueuedHighlightIsDroppedWhenPassagesAreSwitchedOffOrRemoved(remove: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        let narrated = try #require(await fixture.service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 12).handoffMapping)
        let following = try #require(await fixture.service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 16).handoffMapping)
        let slowDecoration = PassageAlignmentServiceTests.Gate()
        reader.engine.nextDecorationGate = slowDecoration
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)

        reader.controller.startFollowing()
        try await fixture.until { reader.engine.decorations.count == 1 }
        reader.transport.load(fixture.audiobook, position: 16, isPlaying: true)
        try await fixture.until { reader.controller.highlighted?.key == following.key }
        if remove { await fixture.service.removePreparedPassages() } else { fixture.service.cachedMappingsEnabled = false }
        try await fixture.until { reader.controller.highlighted == nil }
        slowDecoration.open()
        try await fixture.until { reader.engine.decorations.count == 2 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(reader.engine.decorations.map(\.locatorJSON) == [narrated.locatorJSON, nil])

        if remove {
            fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .playback)
        } else {
            fixture.service.cachedMappingsEnabled = true
        }
        try await fixture.until { reader.engine.decorations.last?.locatorJSON == following.locatorJSON }
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test func switchingPreparedPassagesOffClearsTheHighlightAndPageTurnsUntilSwitchedOn() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        let narrated = try #require(await fixture.service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 12).handoffMapping)
        let following = try #require(await fixture.service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 16).handoffMapping)
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)
        reader.controller.startFollowing()
        try await fixture.until { reader.engine.follows == [narrated.locatorJSON] }

        fixture.service.cachedMappingsEnabled = false
        try await fixture.until { reader.engine.decorations.last.map { $0.locatorJSON == nil } == true }
        #expect(reader.controller.status == .passagesOff)
        #expect(reader.controller.remedy == .storyAlignSettings)
        reader.transport.load(fixture.audiobook, position: 16, isPlaying: true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(reader.engine.follows == [narrated.locatorJSON])
        #expect(reader.controller.highlighted == nil)

        fixture.service.cachedMappingsEnabled = true
        try await fixture.until { reader.engine.follows == [narrated.locatorJSON, following.locatorJSON] }
        #expect(reader.controller.status == .following)
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test func readAlongIsOfferedBeforeTheAudiobookIsDownloadedAndSaysWhatIsMissing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        var audiobook = Book(id: "remote-audio-\(UUID().uuidString)", title: "Remote", source: .local, mediaType: .audiobook)
        audiobook.duration = 600
        var ebook = Book(id: "remote-ebook-\(UUID().uuidString)", title: "Remote", source: .local, mediaType: .ebook)
        ebook.ebookFileURL = fixture.ebook.ebookFileURL
        ebook.linkedAudiobookStableId = audiobook.stableId
        fixture.session.appState.libraryCache.ensureBookInMemory(audiobook)
        let transport = RecordingTransport()
        let engine = ScriptedReaderEngine(visibleLocatorJSON: try Reader.visibleSentenceJSON())
        let controller = ReaderLinkedReadAlongController(
            book: ebook, profileSession: fixture.session, playback: transport,
            adapter: { engine }, openedFileURL: { ebook.ebookFileURL }, highlightColor: { .gold }
        )

        await controller.prepare()
        #expect(controller.isAvailable)
        #expect(controller.needsAudiobookDownload)
        transport.load(audiobook, position: 30, isPlaying: true)
        controller.startFollowing()
        try await fixture.until { controller.status == .blocked(.missingMedia) }
        #expect(controller.remedy == .download)
        controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test func aFailedStartupShowsItsReasonAndTryAgainPreparesTheNarratedPassage() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let reader = try await Reader(fixture: fixture)
        fixture.startup.open()
        fixture.startupFailure = CocoaError(.fileReadCorruptFile)
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)

        reader.controller.startFollowing()
        try await fixture.until { reader.controller.status == .blocked(.preparationFailed) }
        #expect(fixture.builds == 1)
        #expect(reader.controller.remedy == .retry)

        fixture.startupFailure = nil
        fixture.narrateSentence()
        reader.controller.retryPreparation()
        try await fixture.until { reader.controller.status == .following && reader.controller.highlighted != nil }
        #expect(fixture.builds == 2)
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test func theAudioButtonPausesOrResumesInPlaceAndFollowingNeverStartsOrMovesPlayback() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let reader = try await Reader(fixture: fixture)

        // An idle player is reported with a Play action, never started on its own.
        reader.controller.startFollowing()
        try await fixture.until { reader.controller.status == .narrationElsewhere }
        #expect(reader.controller.remedy == .play)
        reader.controller.stopFollowing()
        reader.controller.startFollowing()
        #expect(reader.transport.plays == 0 && reader.transport.toggles == 0 && reader.transport.seeks.isEmpty)

        reader.transport.load(fixture.audiobook, position: 40, isPlaying: false)
        await reader.controller.toggleListening(audiobook: fixture.audiobook, readingLocatorJSON: nil, chapterIndex: 3)
        #expect(reader.transport.toggles == 1)
        #expect(reader.transport.seeks.isEmpty)

        reader.controller.retire()
        await reader.controller.toggleListening(audiobook: fixture.audiobook, readingLocatorJSON: nil, chapterIndex: 3)
        reader.controller.retryPreparation()
        #expect(reader.transport.toggles == 1 && reader.transport.plays == 0 && reader.transport.seeks.isEmpty)
        #expect(!reader.controller.isFollowRequested)
        await fixture.session.retire()
    }

    @Test func aWindowWhoseAnalysisFailedIsReportedAndTryAgainAnalyzesItAgain() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let reader = try await Reader(fixture: fixture)
        fixture.narrateSentence()
        fixture.startup.open()
        fixture.engine.failure = CocoaError(.fileReadCorruptFile)
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)

        reader.controller.startFollowing()
        try await fixture.until { reader.controller.status == .unmatched(.analysisFailed) }
        #expect(reader.controller.remedy == .retry)
        #expect(reader.controller.highlighted == nil)

        fixture.engine.failure = nil
        reader.controller.retryPreparation()
        try await fixture.until { reader.controller.status == .following && reader.controller.highlighted != nil }
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test func aWindowWithoutAConfidentMatchSaysSoInsteadOfPreparing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let reader = try await Reader(fixture: fixture)
        fixture.narrateSentence()
        let recognized = fixture.engine.matches
        fixture.engine.matches = []
        fixture.startup.open()
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)

        reader.controller.startFollowing()
        try await fixture.until { reader.controller.status == .unmatched(.noConfidentMatch) }
        #expect(reader.controller.remedy == .retry)
        let calls = fixture.engine.analyzedWindows.filter { $0 == 0 }.count

        fixture.engine.matches = recognized
        reader.controller.retryPreparation()
        try await fixture.until { reader.controller.status == .following && reader.controller.highlighted != nil }
        #expect(fixture.engine.analyzedWindows.filter { $0 == 0 }.count == calls + 1)
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test func aMissingModelOffersStoryAlignSettingsAndPreparesOnceItIsInstalled() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let reader = try await Reader(fixture: fixture)
        let installed = fixture.service.modelDirectoryProvider
        fixture.service.modelDirectoryProvider = { nil }
        fixture.startup.open()
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)

        reader.controller.startFollowing()
        try await fixture.until { reader.controller.status == .blocked(.modelDownloadRequired) }
        #expect(reader.controller.remedy == .storyAlignSettings)
        #expect(fixture.builds == 0)

        fixture.narrateSentence()
        fixture.service.modelDirectoryProvider = installed
        try await fixture.until { reader.controller.status == .following && reader.controller.highlighted != nil }
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test func onlyReasonsWithACorrectiveRouteOfferAnAction() {
        typealias Controller = ReaderLinkedReadAlongController
        for reason in [PassageUnavailableReason.unsupportedSystem, .unsupportedHardware, .unsupportedLanguage, .unsupportedFormat,
            .busy, .pausedForPower, .pausedForTemperature, .backgroundUnavailable] {
            #expect(Controller.remedy(for: .blocked(reason), needsAudiobookDownload: true) == nil)
        }
        for reason in [PassageUnavailableReason.generationDisabled, .modelDownloadRequired, .lowStorage] {
            #expect(Controller.remedy(for: .blocked(reason), needsAudiobookDownload: false) == .storyAlignSettings)
        }
        // StoryAlign settings cannot re-allow Speech Recognition; only the system Settings app can.
        #expect(Controller.remedy(for: .blocked(.permissionDenied), needsAudiobookDownload: false) == .appSettings)
        #expect(Controller.remedy(for: .blocked(.preparationFailed), needsAudiobookDownload: false) == .retry)
        #expect(Controller.remedy(for: .blocked(.missingMedia), needsAudiobookDownload: true) == .download)
        #expect(Controller.remedy(for: .blocked(.missingMedia), needsAudiobookDownload: false) == nil)
        #expect(Controller.remedy(for: .unmatched(.noConfidentMatch), needsAudiobookDownload: false) == .retry)
        #expect(Controller.remedy(for: .unavailable("Different copy"), needsAudiobookDownload: false) == nil)
        #expect(Controller.remedy(for: .preparing(.matchingPassage), needsAudiobookDownload: false) == nil)
    }
    private static func narratedWords() -> [PassageWordTiming] {
        PassageWordMatcher.printedWords(Fixture.narrated).enumerated().map { index, chunk in
            PassageWordTiming(location: chunk.location, length: chunk.length, start: 10 + Double(index) * 0.4, end: 10.35 + Double(index) * 0.4)
        }
    }

    @Test func wordsFollowTheLiveClockWithoutTurningPagesAndClearBetweenWords() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let words = Self.narratedWords()
        fixture.engine.words[1] = words
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        reader.transport.load(fixture.audiobook, position: 10.5, isPlaying: true)
        reader.transport.live = 10.1

        reader.controller.startFollowing()
        try await fixture.until { reader.controller.activeWord == words[0] }
        let mapping = try #require(reader.controller.highlighted)
        #expect(mapping.granularity == .word)
        try await fixture.until { reader.engine.wordDecorations.last == mapping.locatorJSON(for: words[0]) }

        reader.transport.live = 11.3
        try await fixture.until { reader.controller.activeWord == words[3] }
        reader.transport.live = 11.57
        try await fixture.until { reader.controller.activeWord == nil && reader.engine.wordDecorations.last == .some(nil) }
        // A seek inside the sentence moves the word; the page was turned once, for the sentence.
        reader.transport.live = 13.3
        try await fixture.until { reader.controller.activeWord == words[8] }
        #expect(reader.engine.follows.count == 1)

        // Without a trustworthy live clock only the sentence stays highlighted.
        reader.transport.live = 45
        try await fixture.until { reader.controller.activeWord == nil }
        reader.transport.live = nil
        try await Task.sleep(for: .milliseconds(300))
        #expect(reader.controller.activeWord == nil && reader.controller.highlighted?.key == mapping.key)

        reader.transport.live = 11.3
        try await fixture.until { reader.controller.activeWord == words[3] }
        reader.controller.stopFollowing()
        try await fixture.until { reader.engine.wordDecorations.last == .some(nil) }
        #expect(reader.controller.activeWord == nil)
        await fixture.session.retire()
    }

    @Test func theLiveClockToleranceScalesWithPlaybackRate() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let words = Self.narratedWords()
        fixture.engine.words[1] = words
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        // Published once a second, the position can trail the live clock by more at double speed.
        reader.transport.load(fixture.audiobook, position: 6.7, isPlaying: true, speed: 2)
        reader.transport.live = 11.3
        reader.controller.startFollowing()
        try await fixture.until { reader.controller.activeWord == words[3] }

        reader.transport.load(fixture.audiobook, position: 6.7, isPlaying: true, speed: 1)
        try await fixture.until { reader.controller.activeWord == nil }
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test func aBusyRendererReceivesOnlyTheNewestWord() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let words = Self.narratedWords()
        fixture.engine.words[1] = words
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        let gate = PassageAlignmentServiceTests.Gate()
        reader.engine.nextWordGate = gate
        reader.transport.load(fixture.audiobook, position: 10.5, isPlaying: true)
        reader.transport.live = 10.1
        reader.controller.startFollowing()
        try await fixture.until { reader.engine.wordDecorations.count == 1 }
        for (time, index) in [(10.5, 1), (10.9, 2), (11.3, 3)] {
            reader.transport.live = time
            try await fixture.until { reader.controller.activeWord == words[index] }
        }
        gate.open()
        let mapping = try #require(reader.controller.highlighted)
        try await fixture.until { reader.engine.wordDecorations.count == 2 }
        #expect(reader.engine.wordDecorations == [mapping.locatorJSON(for: words[0]), mapping.locatorJSON(for: words[3])])
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test func replacingTheOpenedFileStopsHighlightsFromTheOldRevision() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.engine.words[1] = Self.narratedWords()
        try await fixture.prepareNarratedSentence()
        let original = try #require(fixture.ebook.ebookFileURL)
        let copy = fixture.root.appendingPathComponent("opened-copy.epub")
        try FileManager.default.copyItem(at: original, to: copy)
        let reader = try await Reader(fixture: fixture, openedFileURL: copy)
        reader.transport.load(fixture.audiobook, position: 11.3, isPlaying: true)
        reader.transport.live = 11.3
        reader.controller.startFollowing()
        try await fixture.until { reader.controller.activeWord != nil }

        try Data("a different revision of the book".utf8).write(to: copy)
        try await fixture.until {
            reader.controller.highlighted == nil && reader.controller.activeWord == nil
                && reader.engine.decorations.last.map { $0.locatorJSON == nil } == true && reader.engine.wordDecorations.last == .some(nil)
        }
        guard case .unavailable = reader.controller.status else {
            Issue.record("Expected the replaced revision to be reported, got \(reader.controller.status)")
            return
        }
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test func unlinkingDuringFollowingStopsAndNeverPreparesTheOldPair() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.engine.words[1] = Self.narratedWords()
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        reader.transport.load(fixture.audiobook, position: 11.3, isPlaying: true)
        reader.transport.live = 11.3
        reader.controller.startFollowing()
        try await fixture.until { reader.controller.activeWord != nil }
        // A slow renderer still holds the next word write when the link goes away.
        let gate = PassageAlignmentServiceTests.Gate()
        reader.engine.nextWordGate = gate
        reader.transport.live = 10.1
        try await fixture.until { reader.controller.activeWord == Self.narratedWords()[0] }

        _ = fixture.session.appState.mutateBook(uniqueId: fixture.ebook.uniqueId) { $0.linkedAudiobookStableId = nil }
        fixture.session.playback.linker.invalidateCache()
        await fixture.service.removePair(ebookStableId: fixture.ebook.stableId, audiobookStableId: fixture.audiobook.stableId)
        try await fixture.until { !reader.controller.isFollowRequested && reader.controller.highlighted == nil }
        let written = reader.engine.wordDecorations.count
        gate.open()
        let builds = fixture.builds
        try await Task.sleep(for: .milliseconds(800))
        #expect(!reader.controller.isAvailable)
        #expect(reader.controller.status == .idle)
        #expect(reader.engine.wordDecorations.dropFirst(written).allSatisfy { $0 == nil })
        #expect(reader.engine.decorations.last.map { $0.locatorJSON == nil } == true)
        #expect(fixture.builds == builds && fixture.service.queuedWindows.isEmpty)
        await fixture.session.retire()
    }

    @Test func relinkingToAnotherAudiobookStopsFollowingTheOldOne() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)
        reader.controller.startFollowing()
        try await fixture.until { reader.controller.highlighted != nil }

        var other = Book(id: "relinked-\(UUID().uuidString)", title: "Other narration", source: .local, mediaType: .audiobook)
        other.duration = 600
        fixture.session.appState.libraryCache.ensureBookInMemory(other)
        _ = fixture.session.appState.mutateBook(uniqueId: fixture.ebook.uniqueId) { $0.linkedAudiobookStableId = other.stableId }
        fixture.session.playback.linker.invalidateCache()
        try await fixture.until { !reader.controller.isFollowRequested && reader.controller.highlighted == nil }
        #expect(reader.controller.linkedAudiobook?.stableId == other.stableId)
        #expect(reader.controller.status == .idle)
        await fixture.session.retire()
    }

    @Test func deletedOrReplacedAudioDropsWordsUntilANewIdentityIsPrepared() async throws {
        for replace in [false, true] {
            let fixture = try await Fixture()
            defer { fixture.remove() }
            fixture.engine.words[1] = Self.narratedWords()
            try await fixture.prepareNarratedSentence()
            let reader = try await Reader(fixture: fixture)
            reader.transport.load(fixture.audiobook, position: 11.3, isPlaying: true)
            reader.transport.live = 11.3
            reader.controller.startFollowing()
            try await fixture.until { reader.controller.activeWord != nil }

            // Re-preparing the replaced recording fails here, so nothing from the old recording may come back.
            fixture.engine.failure = CocoaError(.fileReadCorruptFile)
            if replace {
                try Data(repeating: 9, count: 90_000).write(to: fixture.audio)
            } else {
                try FileManager.default.removeItem(at: fixture.audio)
            }
            try await fixture.until {
                reader.controller.highlighted == nil && reader.controller.activeWord == nil && reader.engine.wordDecorations.last == .some(nil)
            }
            try await Task.sleep(for: .milliseconds(600))
            #expect(reader.controller.highlighted == nil)
            reader.controller.stopFollowing()
            await fixture.session.retire()
        }
    }

    @Test func theResumeStartSkipsTheLinkedReadingHandoff() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await Reader(fixture: fixture)
        let appState = fixture.session.appState
        // The ebook was read after the audiobook was last heard, which a normal start would reconcile toward.
        _ = appState.mutateBook(uniqueId: fixture.audiobook.uniqueId) {
            $0.currentTime = 132.8
            $0.lastUpdate = Date(timeIntervalSinceNow: -3600)
        }
        _ = appState.mutateBook(uniqueId: fixture.ebook.uniqueId) {
            $0.ebookProgress = 0.5
            $0.lastUpdate = Date()
        }
        final class Starter: BookPlaybackStarting {
            var started: [Book] = []
            func play(_ book: Book, from startPosition: TimeInterval?, presentPlayer: Bool) { started.append(book) }
        }
        final class Events: PlaybackEventPublishing {
            var playbackEvents: AnyPublisher<PlaybackEvent, Never> { Empty().eraseToAnyPublisher() }
        }
        let starter = Starter()
        let queue = PlaybackQueueCoordinator(
            appState: appState, playback: RecordingTransport(), playbackEvents: Events(), playbackStarter: starter,
            linkedProgress: fixture.session.linkedProgress,
            store: PlaybackQueueStore(fileURL: fixture.root.appendingPathComponent("queue.json"))
        )
        let audiobook = try #require(appState.libraryCache.bookInMemory(uniqueId: fixture.audiobook.uniqueId))
        queue.playManually(audiobook, presentPlayer: false, reconcilingLinkedPosition: false)
        try await fixture.until { !starter.started.isEmpty }
        #expect(starter.started.first?.currentTime == 132.8)
        #expect(appState.libraryCache.bookInMemory(uniqueId: fixture.audiobook.uniqueId)?.currentTime == 132.8)
        await fixture.session.retire()
    }

    @Test func unlinkingWhileAnotherBookPlaysDropsThePlayRemedyAndStartsNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        final class Starts { var books: [String] = [] }
        let starts = Starts()
        let reader = try await Reader(fixture: fixture, startAudiobook: { starts.books.append($0.stableId) })
        let other = Book(id: "elsewhere-\(UUID().uuidString)", title: "Elsewhere", source: .local, mediaType: .audiobook)
        reader.transport.load(other, position: 99, isPlaying: true)
        reader.controller.startFollowing()
        try await fixture.until { reader.controller.status == .narrationElsewhere }
        #expect(reader.controller.remedy == .play)

        _ = fixture.session.appState.mutateBook(uniqueId: fixture.ebook.uniqueId) { $0.linkedAudiobookStableId = nil }
        fixture.session.playback.linker.invalidateCache()
        try await fixture.until { !reader.controller.isFollowRequested && reader.controller.linkedAudiobook == nil }
        #expect(reader.controller.remedy == nil)
        await reader.controller.resumeLinkedAudiobook()
        // The old audiobook, loaded and paused, is not toggled by the reader's audio button either.
        reader.transport.load(fixture.audiobook, position: 40, isPlaying: false)
        await reader.controller.toggleListening(audiobook: fixture.audiobook, readingLocatorJSON: nil, chapterIndex: nil)
        #expect(starts.books.isEmpty && reader.transport.plays == 0 && reader.transport.toggles == 0)
        await fixture.session.retire()
    }

    @Test func relinkingWhileNothingIsLoadedResumesOnlyTheNewAudiobook() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        final class Starts { var books: [String] = [] }
        let starts = Starts()
        let reader = try await Reader(fixture: fixture, startAudiobook: { starts.books.append($0.stableId) })
        reader.controller.startFollowing()
        try await fixture.until { reader.controller.status == .narrationElsewhere }

        var replacement = Book(id: "relinked-idle-\(UUID().uuidString)", title: "Replacement", source: .local, mediaType: .audiobook)
        replacement.duration = 600
        fixture.session.appState.libraryCache.ensureBookInMemory(replacement)
        _ = fixture.session.appState.mutateBook(uniqueId: fixture.ebook.uniqueId) { $0.linkedAudiobookStableId = replacement.stableId }
        fixture.session.playback.linker.invalidateCache()
        await reader.controller.resumeLinkedAudiobook()
        #expect(!starts.books.contains(fixture.audiobook.stableId))
        #expect(reader.controller.linkedAudiobook?.stableId == replacement.stableId)
        await reader.controller.resumeLinkedAudiobook()
        #expect(starts.books == [replacement.stableId])
        await fixture.session.retire()
    }
    private static func lineLocatorJSON(_ text: String, progression: Double) throws -> String {
        let object: [String: Any] = [
            "href": Fixture.narratedHref, "type": "application/xhtml+xml",
            "locations": ["progression": progression, "totalProgression": progression], "text": ["highlight": text],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test func listenAlongKeepsTheListeningPositionWhileReadingOnOrAhead() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        #expect(!reader.controller.ownsListeningPosition)
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)
        reader.controller.startFollowing()
        try await fixture.until { reader.controller.status == .following }
        #expect(reader.controller.ownsListeningPosition)
        reader.engine.visibleLocatorJSON = try Self.lineLocatorJSON("Nobody on the pier said a word.", progression: 0.9)
        reader.controller.userDidNavigate()
        #expect(reader.controller.status == .browsing && reader.controller.ownsListeningPosition)
        // Another book in the player: reading saves are ordinary reading again.
        let other = Book(id: "elsewhere-\(UUID().uuidString)", title: "Other", source: .local, mediaType: .audiobook)
        reader.transport.load(other, position: 3, isPlaying: true)
        #expect(!reader.controller.ownsListeningPosition)
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: false)
        reader.controller.stopFollowing()
        #expect(!reader.controller.ownsListeningPosition)
        await fixture.session.retire()
    }

    @Test func aDoubleTappedLineStartsNarrationThereAndTheNewestTapWins() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        let first = try Self.lineLocatorJSON(Fixture.narrated, progression: 0.10)
        let second = try Self.lineLocatorJSON("Nobody on the pier said a word.", progression: 0.15)
        reader.engine.locatorAtPoint = { $0.x < 50 ? first : second }
        reader.transport.load(fixture.audiobook, position: 7, isPlaying: true)
        reader.controller.startFollowing()
        try await fixture.until { reader.engine.follows.count == 1 && reader.engine.locatorRequests == 1 }

        // The first tap is still reading its line when the second arrives; narration keeps playing meanwhile.
        let gate = PassageAlignmentServiceTests.Gate()
        reader.engine.nextLocatorGate = gate
        let older = Task { await reader.controller.listenFromHere(at: CGPoint(x: 10, y: 200)) }
        try await fixture.until { reader.engine.locatorRequests == 2 }
        #expect(await reader.controller.listenFromHere(at: CGPoint(x: 300, y: 400)) == .started)
        gate.open()
        #expect(await older.value == .cancelled)
        #expect(reader.transport.seeks == [14.5])
        #expect(reader.transport.pauses == 0 && reader.transport.plays == 0)
        await fixture.session.retire()
    }

    @Test func aCancelledOrRetiredLineTapMovesNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        reader.engine.locatorAtPoint = { _ in try? Self.lineLocatorJSON("Nobody on the pier said a word.", progression: 0.15) }
        reader.transport.load(fixture.audiobook, position: 7, isPlaying: true)
        let gate = PassageAlignmentServiceTests.Gate()
        reader.engine.nextLocatorGate = gate
        let tap = Task { await reader.controller.listenFromHere(at: CGPoint(x: 300, y: 400)) }
        try await fixture.until { reader.engine.locatorRequests == 1 }
        tap.cancel()
        gate.open()
        #expect(await tap.value == .cancelled)

        reader.controller.retire()
        #expect(await reader.controller.listenFromHere(at: CGPoint(x: 300, y: 400)) == .cancelled)
        #expect(reader.transport.seeks.isEmpty && reader.transport.plays == 0)
        await fixture.session.retire()
    }
    @Test(arguments: [0, 0.349986, 0.658115])
    func narrationReachingAPageReadAheadResumesFollowingWithoutSeeking(rendererProgression: Double) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        reader.transport.load(fixture.audiobook, position: 7, isPlaying: true)
        reader.controller.startFollowing()
        try await fixture.until { reader.engine.follows.count == 1 && reader.engine.locatorRequests == 1 }

        // The reader turns ahead to the page that starts with the third sentence; narration plays on.
        reader.engine.visibleLocatorJSON = try Self.lineLocatorJSON("Nobody on the pier said a word.", progression: rendererProgression)
        reader.controller.userDidNavigate()
        try await fixture.until { reader.engine.locatorRequests == 2 }
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)
        try await fixture.until { reader.controller.highlighted?.key.sentence == 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(reader.controller.status == .browsing && reader.engine.follows.count == 1)

        reader.transport.load(fixture.audiobook, position: 16, isPlaying: true)
        try await fixture.until { reader.controller.status == .following && reader.engine.follows.count == 2 }
        #expect(reader.transport.commands == 0)
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test(arguments: [0, 0.658115])
    func aPageReadBehindNarrationWaitsForBackToNarration(rendererProgression: Double) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)
        reader.controller.startFollowing()
        try await fixture.until { reader.engine.follows.count == 1 && reader.engine.locatorRequests == 1 }
        reader.engine.visibleLocatorJSON = try Self.lineLocatorJSON("The tide had turned before dawn.", progression: rendererProgression)
        reader.controller.userDidNavigate()
        try await fixture.until { reader.engine.locatorRequests == 2 }
        reader.transport.load(fixture.audiobook, position: 16, isPlaying: true)
        try await fixture.until { reader.controller.highlighted?.key.sentence == 2 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(reader.controller.status == .browsing && reader.engine.follows.count == 1)
        #expect(reader.controller.remedy == .resumeFollowing)
        reader.controller.resumeFollowing()
        try await fixture.until { reader.engine.follows.count == 2 }
        #expect(reader.transport.commands == 0)
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }
    @Test func aSentenceCarriedOverFromThePreviousPageIsNotThePageReached() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        reader.transport.load(fixture.audiobook, position: 7, isPlaying: true)
        reader.controller.startFollowing()
        try await fixture.until { reader.engine.follows.count == 1 && reader.engine.locatorRequests == 1 }
        reader.engine.visibleLocatorJSON = try Self.lineLocatorJSON("once and the harbor went quiet.", progression: 0)
        reader.controller.userDidNavigate()
        try await fixture.until { reader.engine.locatorRequests == 2 }
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)
        try await fixture.until { reader.controller.highlighted?.key.sentence == 1 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(reader.controller.status == .browsing && reader.engine.follows.count == 1)
        reader.transport.load(fixture.audiobook, position: 16, isPlaying: true)
        try await fixture.until { reader.controller.status == .following && reader.engine.follows.count == 2 }
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test func turningBackToTheNarratedPageResumesFollowingAtOnce() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)
        reader.controller.startFollowing()
        try await fixture.until { reader.engine.follows.count == 1 && reader.engine.locatorRequests == 1 }
        let narratedPage = reader.engine.visibleLocatorJSON
        reader.engine.visibleLocatorJSON = try Self.lineLocatorJSON("Nobody on the pier said a word.", progression: 0.9)
        reader.controller.userDidNavigate()
        try await fixture.until { reader.engine.locatorRequests == 2 }
        #expect(reader.controller.status == .browsing)

        reader.engine.visibleLocatorJSON = narratedPage
        reader.controller.userDidNavigate()
        try await fixture.until { reader.controller.status == .following }
        #expect(reader.transport.commands == 0)
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }
    @Test func aPageInTheNextChapterHeadedByAnUnspokenTitleIsReachedWithoutAnEarlierMapping() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let next = "OEBPS/c2.xhtml"
        let lines: [(href: String, key: PassageSentenceKey, text: String)] = [
            (Fixture.narratedHref, .init(chapter: 0, sentence: 0), "The tide had turned before dawn."),
            (Fixture.narratedHref, .init(chapter: 0, sentence: 1), Fixture.narrated),
            (Fixture.narratedHref, .init(chapter: 0, sentence: 2), "Nobody on the pier said a word."),
            (next, .init(chapter: 1, sentence: 0), "Chapter Two"),
            (next, .init(chapter: 1, sentence: 1), "Morning found the boats already gone."),
            (next, .init(chapter: 1, sentence: 2), "Gulls argued over the empty nets."),
        ]
        fixture.sentences = lines.enumerated().map {
            PassageSentence(key: $0.element.key, href: $0.element.href, text: $0.element.text,
                chapterProgression: 0.2 * Double($0.element.key.sentence + 1), totalProgression: Double($0.offset + 1) / 7)
        }
        fixture.engine.matches = [(0, 6.0, 9.5), (1, 10.0, 14.0), (2, 14.5, 18.0), (4, 18.5, 22.0), (5, 22.5, 26.0)].map {
            CTCPassageMatch(sentenceIndex: $0.0, start: $0.1, end: $0.2, score: -0.1)
        }
        fixture.engine.finishWork()
        fixture.startup.open()
        let reader = try await Reader(fixture: fixture)
        reader.transport.load(fixture.audiobook, position: 2, isPlaying: true)
        reader.controller.startFollowing()
        let heading: [String: Any] = [
            "href": next, "type": "application/xhtml+xml",
            "locations": ["progression": 0, "totalProgression": 0], "text": ["highlight": "Chapter Two"],
        ]
        reader.engine.visibleLocatorJSON = String(decoding: try JSONSerialization.data(withJSONObject: heading), as: UTF8.self)
        reader.controller.userDidNavigate()
        try await fixture.until { reader.engine.locatorRequests == 1 }
        #expect(reader.controller.highlighted == nil)

        for (time, sentence) in [(7.0, 0), (12.0, 1), (16.0, 2)] {
            reader.transport.load(fixture.audiobook, position: time, isPlaying: true)
            try await fixture.until { reader.controller.highlighted?.key == .init(chapter: 0, sentence: sentence) }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(reader.controller.status == .browsing && reader.engine.follows.isEmpty)
        reader.transport.load(fixture.audiobook, position: 20, isPlaying: true)
        try await fixture.until { reader.controller.status == .following && reader.engine.follows.count == 1 }
        #expect(reader.controller.highlighted?.key == .init(chapter: 1, sentence: 1))
        #expect(reader.transport.commands == 0)
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test func followingContinuesAcrossManyPreparedWindowsAndAManualPageTurn() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        // Sentences end 9 s apart, so each window, owning about 30 s of endings, has the three an accepted window needs.
        let count = 17
        fixture.sentences = (0..<count).map {
            PassageSentence(key: .init(chapter: 0, sentence: $0), href: Fixture.narratedHref, text: "Harbor line \($0) was spoken while the tide turned.",
                chapterProgression: Double($0 + 1) / Double(count + 1), totalProgression: Double($0 + 1) / Double(count + 1))
        }
        fixture.engine.matches = (0..<count).map { CTCPassageMatch(sentenceIndex: $0, start: 6 + 9 * Double($0), end: 10 + 9 * Double($0), score: -0.1) }
        fixture.engine.finishWork()
        fixture.startup.open()
        let reader = try await Reader(fixture: fixture)
        reader.transport.load(fixture.audiobook, position: 7, isPlaying: true)
        reader.controller.startFollowing()
        for index in 0..<count {
            if index == 5 {
                reader.engine.visibleLocatorJSON = try Self.lineLocatorJSON("Harbor line 9 was spoken while the tide turned.", progression: Double(10) / Double(count + 1))
                let requests = reader.engine.locatorRequests
                reader.controller.userDidNavigate()
                try await fixture.until { reader.controller.status == .browsing && reader.engine.locatorRequests > requests }
            }
            reader.transport.load(fixture.audiobook, position: 8 + 9 * Double(index), isPlaying: true)
            try await fixture.until { reader.controller.highlighted?.key.sentence == index }
            if (5..<9).contains(index) { #expect(reader.controller.status == .browsing) }
        }
        #expect(reader.controller.status == .following)
        #expect(Set(fixture.engine.analyzedWindows).count >= 4)
        #expect(reader.transport.seeks.isEmpty && reader.transport.pauses == 0 && reader.transport.plays == 0)
        reader.controller.stopFollowing()
        await fixture.session.retire()
    }

    @Test func thePlayRemedyResumesTheAudiobookWithoutTouchingEitherPosition() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        final class Starts { var books: [String] = [] }
        let starts = Starts()
        let reader = try await Reader(fixture: fixture, startAudiobook: { starts.books.append($0.stableId) })
        let cache = fixture.session.appState.libraryCache
        let ebookBefore = cache.bookInMemory(uniqueId: fixture.ebook.uniqueId)?.canonicalEbookProgress
        let locatorBefore = cache.bookInMemory(uniqueId: fixture.ebook.uniqueId)?.epubLocator

        let other = Book(id: "other-\(UUID().uuidString)", title: "Other", source: .local, mediaType: .audiobook)
        reader.transport.load(other, position: 99, isPlaying: true)
        reader.controller.startFollowing()
        try await fixture.until { reader.controller.status == .narrationElsewhere }
        #expect(reader.controller.remedy == .play)
        await reader.controller.resumeLinkedAudiobook()
        #expect(starts.books == [fixture.audiobook.stableId])

        // A restored mini player names the audiobook without loading it; it starts from its own position.
        reader.transport.load(fixture.audiobook, position: 40, isPlaying: false, isLoaded: false)
        await reader.controller.resumeLinkedAudiobook()
        #expect(starts.books.count == 2)

        reader.transport.load(fixture.audiobook, position: 40, isPlaying: false)
        await reader.controller.resumeLinkedAudiobook()
        #expect(reader.transport.plays == 1)

        reader.controller.retire()
        await reader.controller.resumeLinkedAudiobook()
        #expect(starts.books.count == 2 && reader.transport.plays == 1)
        #expect(reader.transport.seeks.isEmpty && reader.transport.toggles == 0)
        #expect(cache.bookInMemory(uniqueId: fixture.ebook.uniqueId)?.canonicalEbookProgress == ebookBefore)
        #expect(cache.bookInMemory(uniqueId: fixture.ebook.uniqueId)?.epubLocator == locatorBefore)
        await fixture.session.retire()
    }

    @Test func listenAlongStoppingReadToMeOnlyOnceTheLinkedAudiobookStarts() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        final class Starts { var books: [String] = [] }
        let starts = Starts()
        let reader = try await Reader(fixture: fixture, startAudiobook: { starts.books.append($0.stableId) })
        let tts = EbookTTSService()
        reader.controller.coordinate(with: tts)
        var readAloudStops = 0
        reader.controller.onNarrationWillStart = { readAloudStops += 1 }

        // Paused TTS; a line that is never narrated starts nothing, so Read to me keeps its place.
        tts.isPaused = true
        reader.engine.locatorAtPoint = { _ in try? Self.lineLocatorJSON("A line the narrator never reads aloud.", progression: 0.5) }
        #expect(await reader.controller.listenFromHere(at: CGPoint(x: 1, y: 1)) != .started)
        #expect(tts.isPaused && readAloudStops == 0 && starts.books.isEmpty)

        // Play in the Listen Along controls starts the linked audiobook, and only then stops Read to me.
        await reader.controller.toggleNarrationPlayback()
        #expect(starts.books == [fixture.audiobook.stableId])
        #expect(!tts.isPaused && !tts.isPlaying && readAloudStops == 1)

        // Speaking TTS, linked audiobook loaded and paused: Play resumes it in place and stops TTS.
        reader.transport.load(fixture.audiobook, position: 40, isPlaying: false)
        tts.isPlaying = true
        await reader.controller.toggleNarrationPlayback()
        #expect(reader.transport.plays == 1 && !tts.isPlaying && readAloudStops == 2)

        // A double-tapped narrated line takes over from speaking TTS the same way.
        tts.isPlaying = true
        reader.engine.locatorAtPoint = { _ in try? Self.lineLocatorJSON("Nobody on the pier said a word.", progression: 0.15) }
        #expect(await reader.controller.listenFromHere(at: CGPoint(x: 1, y: 1)) == .started)
        #expect(!tts.isPlaying && readAloudStops == 3 && reader.transport.seeks == [14.5])

        // Unlinked, or the reader closed: Play starts nothing and TTS keeps speaking.
        tts.isPlaying = true
        _ = fixture.session.appState.mutateBook(uniqueId: fixture.ebook.uniqueId) { $0.linkedAudiobookStableId = nil }
        fixture.session.playback.linker.invalidateCache()
        await reader.controller.toggleNarrationPlayback()
        reader.controller.retire()
        await reader.controller.toggleNarrationPlayback()
        #expect(tts.isPlaying && readAloudStops == 3 && starts.books.count == 1 && reader.transport.plays == 2)
        tts.isPlaying = false
        await fixture.session.retire()
    }
    @Test func unlinkingWhileALineRecordsItsPositionStartsNothingAndKeepsTheCurrentNarration() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let recording = PassageAlignmentServiceTests.Gate()
        final class Records { var count = 0 }
        let records = Records()
        let reader = try await Reader(fixture: fixture, recordReadingPosition: { _ in
            records.count += 1
            await recording.waitIgnoringCancellation()
        })
        let tts = EbookTTSService()
        reader.controller.coordinate(with: tts)
        var readAloudStops = 0
        reader.controller.onNarrationWillStart = { readAloudStops += 1 }
        let other = Book(id: "elsewhere-\(UUID().uuidString)", title: "Other", source: .local, mediaType: .audiobook)
        reader.transport.load(other, position: 3, isPlaying: true)
        tts.isPaused = true
        reader.engine.locatorAtPoint = { _ in try? Self.lineLocatorJSON("Nobody on the pier said a word.", progression: 0.15) }

        let tap = Task { await reader.controller.listenFromHere(at: CGPoint(x: 1, y: 1)) }
        try await fixture.until { records.count == 1 }
        _ = fixture.session.appState.mutateBook(uniqueId: fixture.ebook.uniqueId) { $0.linkedAudiobookStableId = nil }
        fixture.session.playback.linker.invalidateCache()
        recording.open()
        #expect(await tap.value == .cancelled)
        #expect(tts.isPaused && readAloudStops == 0 && reader.transport.commands == 0)
        #expect(fixture.session.playback.composition.controller.snapshot.currentBook?.stableId != fixture.audiobook.stableId)
        #expect(!reader.controller.isAvailable && !reader.controller.isFollowRequested)
        tts.isPaused = false
        await fixture.session.retire()
    }

    @Test func readToMeStartingPausesOnlyTheLinkedAudiobookAndEndsListenAlong() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        let tts = EbookTTSService()
        reader.controller.coordinate(with: tts)
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)
        reader.controller.startFollowing()
        try await fixture.until { reader.controller.highlighted != nil }

        tts.isPlaying = true
        #expect(reader.transport.pauses == 1)
        #expect(!reader.controller.isFollowRequested && reader.controller.highlighted == nil)

        // Resuming TTS while another book plays leaves that book alone.
        tts.isPlaying = false
        tts.isPaused = true
        reader.transport.load(Book(id: "elsewhere-\(UUID().uuidString)", title: "Other", source: .local, mediaType: .audiobook), position: 3, isPlaying: true)
        tts.isPlaying = true
        #expect(reader.transport.pauses == 1)
        tts.isPlaying = false
        await fixture.session.retire()
    }

    @Test func everyTransportCommandRechecksTheLinkFirst() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        final class Starts { var books: [String] = [] }
        let starts = Starts()
        let reader = try await Reader(fixture: fixture, startAudiobook: { starts.books.append($0.stableId) })
        let controller = reader.controller
        func issueAll() async {
            await controller.skipNarration(by: -15)
            await controller.skipNarration(by: 30)
            await controller.seekNarration(to: 90)
            await controller.setNarrationRate(1.5)
            await controller.toggleNarrationPlayback()
        }

        reader.transport.load(fixture.audiobook, position: 40, isPlaying: true)
        await issueAll()
        #expect(reader.transport.skips == [-15, 30] && reader.transport.seeks == [90] && reader.transport.rates == [1.5])
        #expect(reader.transport.pauses == 1 && reader.transport.commands == 5)

        // Another book in the player: no scrub, rate or skip reaches it.
        reader.transport.load(Book(id: "elsewhere-\(UUID().uuidString)", title: "Other", source: .local, mediaType: .audiobook), position: 3, isPlaying: true)
        await controller.skipNarration(by: 30)
        await controller.seekNarration(to: 5)
        await controller.setNarrationRate(2)
        #expect(reader.transport.commands == 5)

        // A cancelled command never acts.
        reader.transport.load(fixture.audiobook, position: 40, isPlaying: true)
        let cancelled = Task { await controller.seekNarration(to: 7) }
        cancelled.cancel()
        await cancelled.value
        #expect(reader.transport.commands == 5)

        // Relinked to another audiobook before the next tick: the loaded old one is left alone.
        var replacement = Book(id: "relinked-\(UUID().uuidString)", title: "Replacement", source: .local, mediaType: .audiobook)
        replacement.duration = 600
        fixture.session.appState.libraryCache.ensureBookInMemory(replacement)
        _ = fixture.session.appState.mutateBook(uniqueId: fixture.ebook.uniqueId) { $0.linkedAudiobookStableId = replacement.stableId }
        fixture.session.playback.linker.invalidateCache()
        await issueAll()
        #expect(reader.transport.commands == 5 && controller.linkedAudiobook?.stableId == replacement.stableId)
        // Play is the one command for the new link: it starts the replacement, which is not loaded yet.
        #expect(starts.books == [replacement.stableId])

        // Unlinked before the next tick, then retired: nothing at all.
        _ = fixture.session.appState.mutateBook(uniqueId: fixture.ebook.uniqueId) { $0.linkedAudiobookStableId = nil }
        fixture.session.playback.linker.invalidateCache()
        reader.transport.load(replacement, position: 40, isPlaying: true)
        await issueAll()
        controller.retire()
        await issueAll()
        await controller.stopListenAlong()
        #expect(reader.transport.commands == 5 && starts.books == [replacement.stableId])
        await fixture.session.retire()
    }

    @Test func stopPausesTheLinkedAudiobookThenStopsFollowingButNeverAnotherBook() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let reader = try await Reader(fixture: fixture)
        reader.transport.load(fixture.audiobook, position: 12, isPlaying: true)
        reader.controller.startFollowing()
        try await fixture.until { reader.controller.highlighted != nil }
        await reader.controller.stopListenAlong()
        #expect(reader.transport.pauses == 1)
        #expect(!reader.controller.isFollowRequested && reader.controller.status == .idle && reader.controller.highlighted == nil)

        reader.transport.load(Book(id: "elsewhere-\(UUID().uuidString)", title: "Other", source: .local, mediaType: .audiobook), position: 3, isPlaying: true)
        reader.controller.startFollowing()
        try await fixture.until { reader.controller.status == .narrationElsewhere }
        await reader.controller.stopListenAlong()
        #expect(reader.transport.pauses == 1 && !reader.controller.isFollowRequested)
        #expect(reader.transport.seeks.isEmpty && reader.transport.plays == 0)
        await fixture.session.retire()
    }
    @MainActor
    final class Reader {
        let transport: RecordingTransport
        let engine: ScriptedReaderEngine
        let controller: ReaderLinkedReadAlongController

        init(
            fixture: Fixture, color: ReadAloudHighlightColor = .gold, openedFileURL: URL? = nil,
            startAudiobook: ((Book) -> Void)? = nil, startAudiobookAtPosition: ((Book, TimeInterval) -> Void)? = nil,
            recordReadingPosition: ((PassageMapping) async -> Void)? = nil
        ) async throws {
            let session = fixture.session!
            session.appState.libraryCache.ensureBookInMemory(fixture.ebook)
            session.appState.libraryCache.ensureBookInMemory(fixture.audiobook)
            await session.bookStore.upsertBooks([fixture.ebook, fixture.audiobook])
            await session.bookStore.upsertLink(ebookStableId: fixture.ebook.stableId, audiobookStableId: fixture.audiobook.stableId, chapterOffset: 0)
            let transport = RecordingTransport()
            let engine = ScriptedReaderEngine(visibleLocatorJSON: try Self.visibleSentenceJSON())
            let epub = try #require(openedFileURL ?? fixture.ebook.ebookFileURL)
            self.transport = transport
            self.engine = engine
            controller = ReaderLinkedReadAlongController(
                book: fixture.ebook, profileSession: session, playback: transport,
                adapter: { engine }, openedFileURL: { epub }, highlightColor: { color }, startAudiobook: startAudiobook,
                startAudiobookAtPosition: startAudiobookAtPosition,
                recordReadingPosition: recordReadingPosition
            )
            await controller.prepare()
            #expect(controller.isAvailable)
        }
        static func visibleSentenceJSON() throws -> String {
            let object: [String: Any] = [
                "href": Fixture.narratedHref,
                "type": "application/xhtml+xml",
                "locations": ["progression": 0.1, "totalProgression": 0.05],
                "text": ["highlight": "swung once and the harbor went quiet."],
            ]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
    }

    @MainActor
    final class RecordingTransport: PlaybackControlling {
        private let subject = CurrentValueSubject<PlaybackSnapshot, Never>(.idle)
        private(set) var seeks: [TimeInterval] = []
        private(set) var plays = 0
        private(set) var toggles = 0
        private(set) var pauses = 0
        private(set) var skips: [TimeInterval] = []
        private(set) var rates: [Double] = []
        var commands: Int { seeks.count + plays + toggles + pauses + skips.count + rates.count }
        var live: TimeInterval?
        var livePosition: TimeInterval? { live }

        let ownsProgressPersistence = false
        var snapshot: PlaybackSnapshot { subject.value }
        var snapshots: AnyPublisher<PlaybackSnapshot, Never> { subject.eraseToAnyPublisher() }

        func load(_ book: Book, position: TimeInterval, isPlaying: Bool, speed: Double = 1, isLoaded: Bool = true, isLoading: Bool = false) {
            subject.send(PlaybackSnapshot(
                currentBook: book, isPlaying: isPlaying, position: position, duration: 600, playbackSpeed: speed, volume: 1,
                isLoaded: isLoaded, isLoading: isLoading, isOverlayPlaybackActive: false, errorDescription: nil
            ))
        }

        func play() { plays += 1 }
        func pause() { pauses += 1 }
        func stop() {}
        func togglePlay() { toggles += 1 }
        func seek(to time: TimeInterval) { seeks.append(time) }
        func skipForward(seconds: TimeInterval) { skips.append(seconds) }
        func skipBackward(seconds: TimeInterval) { skips.append(-seconds) }
        func setPlaybackRate(_ rate: Double) { rates.append(rate) }
        func setVolume(_ volume: Double) {}
        func fadeOutAndPause(duration: TimeInterval, steps: Int) async {}
    }

    @MainActor
    final class ScriptedReaderEngine: ReaderEngineAdapter {
        var visibleLocatorJSON: String
        var locatorAtPoint: ((CGPoint) -> String?)?
        var nextLocatorGate: PassageAlignmentServiceTests.Gate?
        var nextFollowGate: PassageAlignmentServiceTests.Gate?
        var nextDecorationGate: PassageAlignmentServiceTests.Gate?
        var nextWordGate: PassageAlignmentServiceTests.Gate?
        private(set) var wordDecorations: [String?] = []
        private(set) var locatorRequests = 0
        private(set) var decorations: [(locatorJSON: String?, color: ReadAloudHighlightColor)] = []
        private(set) var follows: [String] = []
        private(set) var ttsDecorations = 0

        init(visibleLocatorJSON: String) {
            self.visibleLocatorJSON = visibleLocatorJSON
        }

        func ttsLocator(at point: CGPoint?) async -> Locator? {
            locatorRequests += 1
            if let gate = nextLocatorGate {
                nextLocatorGate = nil
                await gate.waitIgnoringCancellation()
            }
            return try? Locator(jsonString: point.flatMap { locatorAtPoint?($0) } ?? visibleLocatorJSON)
        }

        func applyReadAlongDecoration(locatorJSON: String?, color: ReadAloudHighlightColor) async {
            decorations.append((locatorJSON, color))
            if let gate = nextDecorationGate {
                nextDecorationGate = nil
                await gate.waitIgnoringCancellation()
            }
        }

        func applyReadAlongWordDecoration(locatorJSON: String?, color: ReadAloudHighlightColor) async {
            wordDecorations.append(locatorJSON)
            if let gate = nextWordGate {
                nextWordGate = nil
                await gate.waitIgnoringCancellation()
            }
        }

        func followReadAlong(locatorJSON: String) async {
            follows.append(locatorJSON)
            if let gate = nextFollowGate {
                nextFollowGate = nil
                await gate.waitIgnoringCancellation()
            }
        }

        func applyTTSDecoration(locatorJSON: String?) async { ttsDecorations += 1 }

        let kind = ReaderEngineKind.foliate
        let viewController = UIViewController()
        let capabilities = Set(ReaderEngineCapability.allCases)
        let currentLocatorJSON: String? = nil
        let currentSelection: ReaderSelectionSnapshot? = nil
        var onRelocation: ((ReaderEngineRelocation) -> Void)?
        var onSelectionChange: ((ReaderSelectionSnapshot?) -> Void)?
        var onAnnotationActivated: ((String) -> Void)?
        var onTap: ((CGPoint, CGSize) -> Void)?
        var onExternalLink: ((URL) -> Void)?
        func restore(locatorJSON: String, animated: Bool) async -> Bool { false }
        func navigate(to locator: Locator, animated: Bool) async -> Bool { false }
        func navigate(toHref href: String, animated: Bool) async -> Bool { false }
        func navigate(toFraction fraction: Double, animated: Bool) async -> Bool { false }
        func pageForward(animated: Bool) async -> Bool { false }
        func pageBackward(animated: Bool) async -> Bool { false }
        func clearSelection() {}
        func applyAppearance(_ appearance: ClassicReaderAppearance) async {}
        func updateAnnotations(_ annotations: [ReaderAnnotation]) async {}
        func search(query: String) async -> [EbookSearchResult] { [] }
        func clearSearch() async {}
        func setAutoScroll(pointsPerSecond: Double) async {}
        func currentPageText() async -> String? { nil }
        func flushPosition() async -> String? { nil }
        func followTTS(locatorJSON: String) async {}
        func tearDown() {}
    }
}
