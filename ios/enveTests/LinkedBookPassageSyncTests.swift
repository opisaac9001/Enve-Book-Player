import Foundation
import Testing
@testable import enve

@MainActor
@Suite(.serialized)
struct LinkedBookPassageSyncTests {
    @Test func listeningInsideCoverageSavesThePreciseOriginalLocator() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let observedAt = Date().addingTimeInterval(60)
        await fixture.session.linkedProgress.recordAudiobookProgress(
            book: fixture.audiobook, currentTime: 112, isFinished: false, observedAt: observedAt, authoritative: true
        )
        let ebook = try #require(fixture.session.appState.libraryCache.bookInMemory(stableId: fixture.ebook.stableId))
        #expect(ebook.epubLocator == fixture.mappings[1].locatorJSON)
        #expect(ebook.ebookProgress == fixture.mappings[1].totalProgression)
        #expect(ebook.lastUpdate == observedAt)
        await fixture.session.retire()
    }

    @Test func newerListeningOutsideCoverageReplacesThePreciseLocatorWithAnEstimate() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let first = Date().addingTimeInterval(60)
        await fixture.session.linkedProgress.recordAudiobookProgress(
            book: fixture.audiobook, currentTime: 112, isFinished: false, observedAt: first, authoritative: true
        )
        let later = first.addingTimeInterval(30)
        await fixture.session.linkedProgress.recordAudiobookProgress(
            book: fixture.audiobook, currentTime: 400, isFinished: false, observedAt: later, authoritative: true
        )
        let ebook = try #require(fixture.session.appState.libraryCache.bookInMemory(stableId: fixture.ebook.stableId))
        #expect(ebook.epubLocator == nil)
        #expect(abs((ebook.ebookProgress ?? 0) - 400.0 / 600.0) < 0.001)
        #expect(ebook.lastUpdate == later)
        await fixture.session.retire()
    }

    @Test func failedExplicitHandoffChangesNeitherPosition() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let first = Date().addingTimeInterval(60)
        await fixture.session.linkedProgress.recordAudiobookProgress(
            book: fixture.audiobook, currentTime: 112, isFinished: false, observedAt: first, authoritative: true
        )
        let ebookBefore = fixture.session.appState.libraryCache.bookInMemory(stableId: fixture.ebook.stableId)
        let audioBefore = fixture.session.bookProgress.loadProgress(for: fixture.audiobook)
        fixture.session.passageAlignment.modelDirectoryProvider = { nil }
        await #expect(throws: LinkedBookPassageError.unavailable(.modelDownloadRequired)) {
            try await LinkedBookPassageService.find(
                ebook: fixture.ebook, audiobook: fixture.audiobook, profileSession: fixture.session, playhead: { 400 }
            )
        }
        #expect(fixture.session.appState.libraryCache.bookInMemory(stableId: fixture.ebook.stableId) == ebookBefore)
        #expect(fixture.session.bookProgress.loadProgress(for: fixture.audiobook)?.progress == audioBefore?.progress)
        await fixture.session.retire()
    }

    @Test func cachedHandoffResolvesWithoutAnyGeneratingEngine() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.session.passageAlignment.modelDirectoryProvider = { nil }
        let mapping = try await LinkedBookPassageService.find(
            ebook: fixture.ebook, audiobook: fixture.audiobook, profileSession: fixture.session, playhead: { 118.5 }
        )
        #expect(mapping == fixture.mappings[2])
        // Between two sentences the handoff opens the upcoming one.
        let pause = try await LinkedBookPassageService.find(
            ebook: fixture.ebook, audiobook: fixture.audiobook, profileSession: fixture.session, playhead: { 115.2 }
        )
        #expect(pause == fixture.mappings[2])
        await fixture.session.retire()
    }

    @Test func readingAPreparedSentenceSavesItsExactNarrationTime() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.mappings[2]
        let observedAt = Date().addingTimeInterval(60)
        await fixture.session.linkedProgress.recordEbookProgress(
            book: fixture.ebook, progression: target.totalProgression, locatorJSON: target.locatorJSON,
            observedAt: observedAt, authoritative: true
        )
        let audiobook = try #require(fixture.session.appState.libraryCache.bookInMemory(stableId: fixture.audiobook.stableId))
        #expect(abs(audiobook.currentTime - target.start) < 0.001)
        #expect(audiobook.lastUpdate == observedAt)

        // A locator that disagrees with the recorded progression is not trusted as exact.
        let later = observedAt.addingTimeInterval(10)
        await fixture.session.linkedProgress.recordEbookProgress(
            book: fixture.ebook, progression: 0.5, locatorJSON: target.locatorJSON, observedAt: later, authoritative: true
        )
        let estimated = try #require(fixture.session.appState.libraryCache.bookInMemory(stableId: fixture.audiobook.stableId))
        #expect(abs(estimated.currentTime - 300) < 0.5)
        await fixture.session.retire()
    }

    @Test func mappingImprovementsAreNotActivityAndOlderListeningCannotOverwriteNewerReading() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let reading = Date().addingTimeInterval(120)
        _ = fixture.session.appState.libraryCache.mutateBook(stableId: fixture.ebook.stableId) {
            $0.ebookProgress = 0.9
            $0.lastUpdate = reading
        }
        await fixture.session.linkedProgress.recordEbookProgress(
            book: fixture.ebook, progression: 0.9, observedAt: reading, authoritative: true
        )
        let ebookAfterReading = fixture.session.appState.libraryCache.bookInMemory(stableId: fixture.ebook.stableId)
        let audioAfterReading = fixture.session.appState.libraryCache.bookInMemory(stableId: fixture.audiobook.stableId)

        _ = try await fixture.session.passageAlignment.store.commit(
            PassageWindowUpdate(trackIndex: 0, windowIndex: 9, ownedEnds: 277.75..<307.75, engine: "test-engine", mappings: [
                fixture.mapping(10, start: 280, end: 284), fixture.mapping(11, start: 285, end: 290), fixture.mapping(12, start: 291, end: 300),
            ]),
            identity: fixture.identity
        )
        #expect(fixture.session.appState.libraryCache.bookInMemory(stableId: fixture.ebook.stableId) == ebookAfterReading)
        #expect(fixture.session.appState.libraryCache.bookInMemory(stableId: fixture.audiobook.stableId) == audioAfterReading)

        await fixture.session.linkedProgress.recordAudiobookProgress(
            book: fixture.audiobook, currentTime: 112, isFinished: false, observedAt: reading.addingTimeInterval(-60), authoritative: true
        )
        let ebook = try #require(fixture.session.appState.libraryCache.bookInMemory(stableId: fixture.ebook.stableId))
        #expect(ebook.ebookProgress == 0.9)
        #expect(ebook.lastUpdate == reading)
        await fixture.session.retire()
    }

    @Test func retiredProfileRejectsLatePassageResultsAndKeepsProfilesPrivate() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let other = try fixture.makeSession(name: "Second")
        #expect(await other.passageAlignment.store.mappingSet(for: fixture.identity) == nil)
        let passages = fixture.session.passageAlignment
        await fixture.session.retire()
        let late = try await passages.store.commit(
            PassageWindowUpdate(trackIndex: 0, windowIndex: 20, ownedEnds: 577.75..<600, engine: "test-engine", mappings: [
                fixture.mapping(20, start: 580, end: 584), fixture.mapping(21, start: 585, end: 590), fixture.mapping(22, start: 591, end: 599),
            ]),
            identity: fixture.identity
        )
        #expect(late == nil)
        #expect(await passages.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 112) == .unprepared)
        await other.retire()
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        private var domains: [String] = []
        private(set) var session: ProfileSession!
        private(set) var ebook: Book!
        private(set) var audiobook: Book!
        private(set) var identity: PassageMediaIdentity!
        private(set) var mappings: [PassageMapping] = []

        init() async throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            session = try makeSession(name: "Passage")

            let suffix = UUID().uuidString
            var audiobook = Book(id: "passage-audio-\(suffix)", title: "Harbor", source: .local, mediaType: .audiobook)
            audiobook.duration = 600
            var ebook = Book(id: "passage-ebook-\(suffix)", title: "Harbor", source: .local, mediaType: .ebook)
            let epub = session.storage.documentsDirectory.appendingPathComponent("Ebooks/local/harbor.epub")
            try FileManager.default.createDirectory(at: epub.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture epub".utf8).write(to: epub)
            ebook.ebookFileURL = epub
            ebook.linkedAudiobookStableId = audiobook.stableId
            let audioDirectory = session.localStorage.bookAudioDirectory(for: audiobook.downloadKey)
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            let audio = audioDirectory.appendingPathComponent("track.mp3")
            try Data(repeating: 7, count: 120_000).write(to: audio)
            session.appState.libraryCache.hot.insert(audiobook)
            session.appState.libraryCache.hot.insert(ebook)
            await session.bookStore.upsertLink(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId, chapterOffset: 0)
            self.ebook = ebook
            self.audiobook = audiobook

            identity = try await session.passageAlignment.identities.identity(
                ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId, epubURL: epub, audioURLs: [audio]
            )
            mappings = [mapping(0, start: 100, end: 106), mapping(1, start: 106.5, end: 114.8), mapping(2, start: 116, end: 121), mapping(3, start: 121.4, end: 128)]
            _ = try await session.passageAlignment.store.commit(
                PassageWindowUpdate(trackIndex: 0, windowIndex: 3, ownedEnds: 97.75..<127.75, engine: "test-engine", mappings: mappings),
                identity: identity
            )
            mappings = Array(mappings.prefix(3))
        }

        func mapping(_ sentence: Int, start: Double, end: Double) -> PassageMapping {
            PassageMapping(
                key: PassageSentenceKey(chapter: 1, sentence: sentence), href: "OEBPS/chapter1.xhtml",
                text: "The harbor sentence number \(sentence) was spoken aloud.", before: "", after: "",
                chapterProgression: Double(sentence) / 50, totalProgression: 0.2 + Double(sentence) / 1000,
                trackIndex: 0, start: start, end: end, granularity: .sentence, engine: "test-engine", score: -0.3
            )
        }

        func makeSession(name: String) throws -> ProfileSession {
            let profile = FamilyProfile(id: UUID().uuidString, name: name, role: .adult)
            let domain = "LinkedBookPassageSyncTests.\(profile.id)"
            domains.append(domain)
            let directory = root.appendingPathComponent(profile.id)
            let storage = ProfileStorageLocations(profileID: profile.id,
                documentsDirectory: directory.appendingPathComponent("Documents"),
                applicationSupportDirectory: directory.appendingPathComponent("ApplicationSupport"),
                cachesDirectory: directory.appendingPathComponent("Caches"))
            guard let defaults = UserDefaults(suiteName: domain) else { throw CocoaError(.featureUnsupported) }
            return try ProfileSession(profile: profile, storage: storage, defaults: defaults, libraryDatabase: Self.sharedDatabase())
        }

        // One long-lived library database for the suite: on iOS 17.0 the runtime still begins CloudKit mirroring
        // setup for each new store, and tearing stores down during that setup crashes the test host.
        private static var database: BookStoreManager?

        private static func sharedDatabase() throws -> BookStoreManager {
            if let database { return database }
            let id = UUID().uuidString
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LinkedBookPassageSyncTests-\(id)")
            let storage = ProfileStorageLocations(profileID: id,
                documentsDirectory: directory.appendingPathComponent("Documents"),
                applicationSupportDirectory: directory.appendingPathComponent("ApplicationSupport"),
                cachesDirectory: directory.appendingPathComponent("Caches"))
            guard let defaults = UserDefaults(suiteName: "LinkedBookPassageSyncTests.database.\(id)") else { throw CocoaError(.featureUnsupported) }
            let created = try BookStoreManager(storage: storage, defaults: defaults)
            database = created
            return created
        }

        func remove() {
            for domain in domains { UserDefaults.standard.removePersistentDomain(forName: domain) }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
