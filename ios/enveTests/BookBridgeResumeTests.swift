import Foundation
import ReadiumZIPFoundation
import Testing

@testable import enve

@MainActor
struct BookBridgeResumeTests {
    @Test(arguments: ["epubcfi(/6/4!/4/2[target]/1:4)", "/body/DocFragment[2]/body/p[1]/text().4"])
    func bridgeLocationsRestoreTheRemoteChapter(location: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let contents = fixture.root.appendingPathComponent("epub")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": #"<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#,
            "package.opf": #"<package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata/><manifest><item id="one" href="chapter-1.xhtml" media-type="application/xhtml+xml"/><item id="two" href="chapter-2.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>"#,
            "chapter-1.xhtml": #"<html xmlns="http://www.w3.org/1999/xhtml"><head/><body><p>First chapter.</p></body></html>"#,
            "chapter-2.xhtml": #"<html xmlns="http://www.w3.org/1999/xhtml"><head/><body><p id="target">The exact sentence to restore.</p></body></html>"#,
        ]
        for (path, text) in files { try Data(text.utf8).write(to: contents.appendingPathComponent(path)) }
        let epub = fixture.root.appendingPathComponent("fixture.epub")
        try await FileManager.default.zipItem(at: contents, to: epub, shouldKeepParent: false)
        var book = fixture.book()
        book.ebookFileURL = epub
        await fixture.session.bookStore.upsertBooks([book])
        let remote = try progress(0.65, location: location, timestamp: 2_000)
        #expect(await KOReaderSyncService.shared.mergeRemoteProgress(into: book, remote: remote, profileSession: fixture.session))
        let saved = try #require(await fixture.session.bookStore.book(uniqueId: book.uniqueId))
        let locator = try #require(saved.epubLocator.flatMap(EpubCFI.jsonObject))
        #expect(locator["href"] as? String == "chapter-2.xhtml")
        #expect(Book.progressFromEbookLocator(saved.epubLocator) == 0.65)
        await fixture.session.retire()
    }

    @Test func aColdBookKeepsTheRemoteTimestampAcrossReload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session
        let book = fixture.book()
        await session.bookStore.upsertBooks([book])
        #expect(session.appState.bookInMemory(uniqueId: book.uniqueId) == nil)

        let remote = try progress(0.65, location: "unsupported", timestamp: 500)
        #expect(await KOReaderSyncService.shared.mergeRemoteProgress(into: book, remote: remote, profileSession: session))
        session.appState.hotCache.remove(uniqueId: book.uniqueId)
        let saved = try #require(await session.bookStore.book(uniqueId: book.uniqueId))
        #expect(saved.ebookProgress == 0.65)
        #expect(saved.epubLocator == nil)
        #expect(saved.lastUpdate == Date(timeIntervalSince1970: 500))
        #expect(saved.currentTime == book.currentTime)
        await session.retire()
    }

    @Test func unknownRemoteTimeDoesNotBecomeANewListeningObservation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let book = fixture.book()
        await fixture.session.bookStore.upsertBooks([book])
        let remote = try progress(0.65, location: "0.65", timestamp: nil)
        #expect(await KOReaderSyncService.shared.mergeRemoteProgress(into: book, remote: remote, profileSession: fixture.session))
        let saved = try #require(await fixture.session.bookStore.book(uniqueId: book.uniqueId))
        #expect(saved.lastUpdate == book.lastUpdate)
        #expect(saved.epubLocator == nil)
        await fixture.session.retire()
    }

    @Test func remoteProgressCannotOverwritePendingOfflineReading() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let book = fixture.book()
        await fixture.session.bookStore.upsertBooks([book])
        let pending = PendingServerSync(stableId: book.stableId, sourceRaw: book.source.rawValue,
            backendId: nil, serverItemId: book.id, position: 0, duration: 0,
            updatedAt: 1_000, domainRaw: "ebook", progress: 0.1, locator: book.epubLocator)
        fixture.session.pendingSync.enqueue(pending)
        let remote = try progress(0.8, location: "0.8", timestamp: 2_000)
        #expect(!(await KOReaderSyncService.shared.mergeRemoteProgress(into: book, remote: remote, profileSession: fixture.session)))
        #expect(fixture.session.pendingSync.entries[book.stableId] == pending)
        #expect(await fixture.session.bookStore.book(uniqueId: book.uniqueId)?.ebookProgress == 0.1)
        await fixture.session.retire()
    }

    @Test func staleCapturedBookDoesNotRewindANewerLocalPosition() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let captured = fixture.book()
        var current = captured
        current.ebookProgress = 0.9
        current.epubLocator = nil
        await fixture.session.bookStore.upsertBooks([current])
        fixture.session.appState.hotCache.insert(current)
        let remote = try progress(0.6, location: "0.6", timestamp: 2_000)
        #expect(!(await KOReaderSyncService.shared.mergeRemoteProgress(into: captured, remote: remote, profileSession: fixture.session)))
        #expect(fixture.session.appState.bookInMemory(uniqueId: captured.uniqueId)?.ebookProgress == 0.9)
        await fixture.session.retire()
    }

    @Test func openingWaitsForRemoteProgressBeforePresentingTheBook() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session
        let book = fixture.book()
        await session.bookStore.upsertBooks([book])
        let remote = try progress(0.6, location: "0.6", timestamp: 2_000)
        var pulled = false
        var presented: Book?
        let coordinator = ReaderOpenCoordinator(appState: session.appState, downloads: session.downloads,
            linkedProgress: session.linkedProgress, present: { presented = $0 }, profileSession: session,
            pullRemoteProgress: { candidate in
                try? await Task.sleep(for: .milliseconds(30))
                await KOReaderSyncService.shared.mergeRemoteProgress(into: candidate, remote: remote, profileSession: session)
                pulled = true
            })
        coordinator.open(book)
        #expect(presented == nil)
        for _ in 0..<300 where presented == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pulled)
        #expect(presented?.canonicalEbookProgress == 0.6)
        #expect(presented?.lastUpdate == Date(timeIntervalSince1970: 2_000))
        await session.retire()
    }

    @Test func anExplicitReaderJumpDoesNotPullAnotherPosition() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session
        let book = fixture.book()
        await session.bookStore.upsertBooks([book])
        session.appState.hotCache.insert(book)
        var pulled = false
        var presented: Book?
        let coordinator = ReaderOpenCoordinator(appState: session.appState, downloads: session.downloads,
            linkedProgress: session.linkedProgress, present: { presented = $0 }, profileSession: session,
            pullRemoteProgress: { _ in pulled = true })
        let target = #"{"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.3}}"#
        coordinator.open(book, at: target)
        for _ in 0..<300 where presented == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!pulled)
        #expect(presented?.epubLocator == target)
        await session.retire()
    }

    @Test func olderReadingProgressDoesNotResetNewerAudiobookResume() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session
        let audio = Book(id: "audio", title: "Audio", duration: 1_000, source: .local,
            currentTime: 800, lastUpdate: Date(timeIntervalSince1970: 3_000))
        var ebook = fixture.book()
        ebook.linkedAudiobookStableId = audio.stableId
        await session.bookStore.upsertBooks([ebook, audio])
        session.appState.hotCache.insert(audio)
        let remote = try progress(0.4, location: "0.4", timestamp: 2_000)
        #expect(await KOReaderSyncService.shared.mergeRemoteProgress(into: ebook, remote: remote, profileSession: session))
        await session.linkedProgress.reconcilePair(for: ebook)
        let saved = try #require(await session.bookStore.book(uniqueId: audio.uniqueId))
        #expect(saved.currentTime == 800)
        #expect(saved.lastUpdate == audio.lastUpdate)
        #expect(session.appState.bookInMemory(uniqueId: audio.uniqueId)?.currentTime == 800)
        await session.retire()
    }

    private func progress(_ percentage: Double, location: String, timestamp: Double?) throws -> KOReaderProgress {
        var object: [String: Any] = ["document": String(repeating: "a", count: 32),
            "progress": location, "percentage": percentage, "device": "abs-kosync-bridge", "device_id": "bridge"]
        if let timestamp { object["timestamp"] = timestamp }
        return try JSONDecoder().decode(KOReaderProgress.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "BookBridgeResumeTests.\(UUID().uuidString)"
        let session: ProfileSession

        init() throws {
            let profile = FamilyProfile(id: UUID().uuidString, name: "Resume fixture", role: .adult)
            let defaults = try #require(UserDefaults(suiteName: domain))
            ProfileServerSyncPreferences(defaults: defaults, isOwner: false).isEnabled = true
            let storage = ProfileStorageLocations(profileID: profile.id,
                documentsDirectory: root.appendingPathComponent("Documents"),
                applicationSupportDirectory: root.appendingPathComponent("Support"),
                cachesDirectory: root.appendingPathComponent("Caches"))
            session = try ProfileSession(profile: profile, storage: storage, defaults: defaults)
        }

        func book() -> Book {
            Book(id: "ebook", title: "BookBridge fixture", source: .local, mediaType: .ebook,
                epubLocator: #"{"href":"old.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.1}}"#,
                ebookProgress: 0.1, lastUpdate: Date(timeIntervalSince1970: 1_000))
        }

        func remove() {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
