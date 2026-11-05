import Foundation
import Testing
@testable import enve

/// Two profiles holding the same books under identical stable IDs, one of them with the owner's profile ID.
/// Quick Sync must never let the other profile read the owner's prepared passages or change its calibration.
@MainActor
@Suite(.serialized)
struct LinkedBookQuickSyncIsolationTests {
    @Test func anotherProfileCannotStartQuickSyncOrTouchOwnerCalibration() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let quickSync = LinkedBookQuickSyncService.shared
        #expect(LinkedBookQuickSyncService.isAvailable(for: fixture.owner))
        #expect(!LinkedBookQuickSyncService.isAvailable(for: fixture.member))

        quickSync.start(ebook: fixture.ebook, audiobook: fixture.audiobook, profile: fixture.member)
        #expect(quickSync.state == nil)
        #expect(!quickSync.isRunning(ebook: fixture.ebook, audiobook: fixture.audiobook))
        #expect(LinkedBookProgressCoordinator.shared.calibrationSummary(ebookStableId: fixture.ebook.stableId, audiobookStableId: fixture.audiobook.stableId) == nil)
        #expect(fixture.member.linkedProgress.calibrationSummary(ebookStableId: fixture.ebook.stableId, audiobookStableId: fixture.audiobook.stableId) == nil)
        #expect(!UnifiedDownloadService.shared.tasks.contains { $0.bookId == fixture.audiobook.downloadKey })
        #expect(try await quickSync.preparedAnchors(ebook: fixture.ebook, audiobook: fixture.audiobook, profile: fixture.owner, at: Fixture.sampleFractions).count >= 4)
        await fixture.retire()
    }

    @Test func aRetiredOwnerCannotStartQuickSyncOrQueueADownload() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await fixture.owner.retire()
        let quickSync = LinkedBookQuickSyncService.shared
        #expect(!LinkedBookQuickSyncService.isAvailable(for: fixture.owner))
        quickSync.start(ebook: fixture.ebook, audiobook: fixture.audiobook, profile: fixture.owner)
        #expect(quickSync.state == nil)
        #expect(!quickSync.isRunning(ebook: fixture.ebook, audiobook: fixture.audiobook))
        #expect(!UnifiedDownloadService.shared.tasks.contains { $0.bookId == fixture.audiobook.downloadKey })
        await fixture.member.retire()
    }

    @Test func theMatchScreenPairsBooksFromThePresentingProfilesOwnLibrary() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        // Identical ebook IDs; the owner pairs it with the fixture audiobook, the other profile with its own.
        var memberAudiobook = Book(id: "member-audio-\(UUID().uuidString)", title: "Harbor, read by another narrator", source: .local, mediaType: .audiobook)
        memberAudiobook.duration = 500
        var memberEbook = fixture.ebook!
        memberEbook.linkedAudiobookStableId = memberAudiobook.stableId
        fixture.owner.appState.libraryCache.hot.insert(fixture.ebook)
        fixture.owner.appState.libraryCache.hot.insert(fixture.audiobook)
        fixture.member.appState.libraryCache.hot.insert(memberEbook)
        fixture.member.appState.libraryCache.hot.insert(memberAudiobook)

        let owned = EbookAudiobookMatchScreen.pair(of: fixture.ebook, resolvedEbook: nil, linker: fixture.owner.ebookLinker)
        let members = EbookAudiobookMatchScreen.pair(of: memberEbook, resolvedEbook: nil, linker: fixture.member.ebookLinker)
        #expect(owned.audiobook?.stableId == fixture.audiobook.stableId)
        #expect(members.audiobook?.stableId == memberAudiobook.stableId)
        #expect(members.audiobook?.title == "Harbor, read by another narrator")
        #expect(EbookAudiobookMatchScreen.pair(of: memberAudiobook, resolvedEbook: nil, linker: fixture.member.ebookLinker).ebook?.stableId == memberEbook.stableId)
        #expect(EbookAudiobookMatchScreen.pair(of: memberAudiobook, resolvedEbook: nil, linker: fixture.owner.ebookLinker).ebook == nil)

        // The same ebook unlinked in the other profile never falls back to the owner's pairing.
        var unlinked = memberEbook
        unlinked.linkedAudiobookStableId = nil
        fixture.member.ebookLinker.invalidateCache()
        #expect(EbookAudiobookMatchScreen.pair(of: unlinked, resolvedEbook: nil, linker: fixture.member.ebookLinker).audiobook == nil)
        await fixture.retire()
    }

    @Test func preparedAnchorsComeOnlyFromTheProfileThatAsked() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let quickSync = LinkedBookQuickSyncService.shared

        let owned = try await quickSync.preparedAnchors(ebook: fixture.ebook, audiobook: fixture.audiobook, profile: fixture.owner, at: Fixture.sampleFractions)
        #expect(LinkedBookAlignmentEvaluator.assess(owned).quality.unitCount >= 4)
        // Same stable IDs, same media and an established identity, but none of the owner's passages.
        #expect(await fixture.member.passageAlignment.store.mappingSet(for: fixture.memberIdentity) == nil)
        #expect(try await quickSync.preparedAnchors(ebook: fixture.ebook, audiobook: fixture.audiobook, profile: fixture.member, at: Fixture.sampleFractions).isEmpty)
        await fixture.retire()
    }

    @Test func aRetiredProfilesPreparedAnchorsAreRejected() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await fixture.owner.retire()
        await #expect(throws: CancellationError.self) {
            try await LinkedBookQuickSyncService.shared.preparedAnchors(ebook: fixture.ebook, audiobook: fixture.audiobook, profile: fixture.owner, at: Fixture.sampleFractions)
        }
        await fixture.member.retire()
    }

    @MainActor
    final class Fixture {
        static let sampleTimes: [TimeInterval] = [114, 168, 228, 294, 360]
        static let sampleFractions = sampleTimes.map { $0 / 600 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        private var domains: [String] = []
        private(set) var owner: ProfileSession!
        private(set) var member: ProfileSession!
        private(set) var ebook: Book!
        private(set) var audiobook: Book!
        private(set) var memberIdentity: PassageMediaIdentity!

        init() async throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            owner = try makeSession(FamilyProfile(id: FamilyProfile.ownerID, name: "Owner", role: .adult))
            member = try makeSession(FamilyProfile(id: UUID().uuidString, name: "Member", role: .adult))

            let suffix = UUID().uuidString
            var audiobook = Book(id: "quicksync-audio-\(suffix)", title: "Harbor", source: .local, mediaType: .audiobook)
            audiobook.duration = 600
            var ebook = Book(id: "quicksync-ebook-\(suffix)", title: "Harbor", source: .local, mediaType: .ebook)
            ebook.linkedAudiobookStableId = audiobook.stableId
            let epub = root.appendingPathComponent("harbor.epub")
            try Data("fixture epub".utf8).write(to: epub)
            ebook.ebookFileURL = epub
            self.ebook = ebook
            self.audiobook = audiobook

            let ownerIdentity = try await install(epub: epub, in: owner)
            memberIdentity = try await install(epub: epub, in: member)
            for (window, time) in Self.sampleTimes.enumerated() {
                let mappings = (0..<3).map { offset -> PassageMapping in
                    let sentence = window * 3 + offset
                    let start = time - 6 + Double(offset) * 4.5
                    return PassageMapping(
                        key: PassageSentenceKey(chapter: 1, sentence: sentence), href: "OEBPS/chapter1.xhtml",
                        text: "Harbor sentence \(sentence) was spoken aloud.", before: "", after: "",
                        chapterProgression: Double(sentence) / 20, totalProgression: (start + 2) / 600,
                        trackIndex: 0, start: start, end: start + 4, granularity: .sentence, engine: "test-engine", score: -0.3
                    )
                }
                _ = try await owner.passageAlignment.store.commit(
                    PassageWindowUpdate(trackIndex: 0, windowIndex: window, ownedEnds: (time - 10)..<(time + 10), engine: "test-engine", mappings: mappings),
                    identity: ownerIdentity
                )
            }
        }

        /// The same EPUB and identical audio in each profile, so only profile ownership separates their passages.
        private func install(epub: URL, in session: ProfileSession) async throws -> PassageMediaIdentity {
            let audioDirectory = session.localStorage.bookAudioDirectory(for: audiobook.downloadKey)
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            let audio = audioDirectory.appendingPathComponent("track.mp3")
            try Data(repeating: 7, count: 120_000).write(to: audio)
            return try await session.passageAlignment.identities.identity(
                ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId, epubURL: epub, audioURLs: [audio]
            )
        }

        private func makeSession(_ profile: FamilyProfile) throws -> ProfileSession {
            let domain = "LinkedBookQuickSyncIsolationTests.\(UUID().uuidString)"
            domains.append(domain)
            let directory = root.appendingPathComponent(UUID().uuidString)
            let storage = ProfileStorageLocations(profileID: profile.id,
                documentsDirectory: directory.appendingPathComponent("Documents"),
                applicationSupportDirectory: directory.appendingPathComponent("ApplicationSupport"),
                cachesDirectory: directory.appendingPathComponent("Caches"))
            guard let defaults = UserDefaults(suiteName: domain) else { throw CocoaError(.featureUnsupported) }
            return try ProfileSession(profile: profile, storage: storage, defaults: defaults, libraryDatabase: Self.sharedDatabase())
        }

        func retire() async {
            await owner.retire()
            await member.retire()
        }

        func remove() {
            for domain in domains { UserDefaults.standard.removePersistentDomain(forName: domain) }
            try? FileManager.default.removeItem(at: root)
        }

        // One long-lived library database for the suite, as in the other passage suites.
        private static var database: BookStoreManager?

        private static func sharedDatabase() throws -> BookStoreManager {
            if let database { return database }
            let id = UUID().uuidString
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LinkedBookQuickSyncIsolationTests-\(id)")
            let storage = ProfileStorageLocations(profileID: id,
                documentsDirectory: directory.appendingPathComponent("Documents"),
                applicationSupportDirectory: directory.appendingPathComponent("ApplicationSupport"),
                cachesDirectory: directory.appendingPathComponent("Caches"))
            guard let defaults = UserDefaults(suiteName: "LinkedBookQuickSyncIsolationTests.database.\(id)") else { throw CocoaError(.featureUnsupported) }
            let created = try BookStoreManager(storage: storage, defaults: defaults)
            database = created
            return created
        }
    }
}
