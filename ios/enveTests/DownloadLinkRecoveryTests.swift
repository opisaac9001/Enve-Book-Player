import Foundation
import Network
import ReadiumZIPFoundation
import Testing

@testable import enve
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct DownloadLinkRecoveryTests {
    private static let rescueProvider = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    @Test func coldStartRecoveryKeepsEveryOwnedDownloadAndListsOnlyTrueOrphans() async throws {
        let lab = try Lab()
        do {
            let first = UUID(), second = UUID(), stranger = UUID()
            let audio = Lab.audiobook("li_seamage", provider: first, currentTime: 77)
            let sameItemOnSecond = Lab.audiobook("li_seamage", provider: second)
            let legacy = Lab.audiobook("li_legacy", provider: first, backendId: "server-one")
            let sharedOnFirst = Lab.audiobook("li_shared", provider: first)
            let sharedOnSecond = Lab.audiobook("li_shared", provider: second)
            let other = Lab.audiobook("li_other", provider: first)
            let ebook = Lab.ebook("li_reading", provider: first, linkedTo: audio)
            await lab.store.upsertBooks([audio, sameItemOnSecond, legacy, sharedOnFirst, sharedOnSecond, other, ebook])
            await lab.store.upsertLink(ebookStableId: ebook.stableId, audiobookStableId: audio.stableId, chapterOffset: 2)

            // Owned: the canonical copy, a raw-id tree whose metadata names this connection's book, and a tree under
            // the legacy provider-scoped key of a book that now has a server id.
            try lab.writeTree(audio.downloadKey, metadata: Lab.metadata(for: audio))
            try lab.writeTree("li_seamage", metadata: Lab.metadata(for: audio))
            try lab.writeTree("audiobookshelf:\(first.uuidString):li_legacy", metadata: nil)
            // Not owned: a raw id both connections serve, metadata naming a connection this profile does not have,
            // and a book that is no longer stored.
            try lab.writeTree("li_shared", metadata: nil)
            try lab.writeTree("stray-li_other", metadata: OfflineBookMetadata(
                id: "li_other", stableId: "audiobookshelf:\(stranger.uuidString):li_other", title: "Other", author: nil,
                narrator: nil, duration: nil, chapters: nil, audioTracks: nil, coverURLString: nil, source: .audiobookshelf
            ))
            try lab.writeTree("gone-tree", metadata: OfflineBookMetadata(
                id: "li_gone", stableId: "audiobookshelf:\(first.uuidString):li_gone", title: "Gone", author: nil,
                narrator: nil, duration: nil, chapters: nil, audioTracks: nil, coverURLString: nil, source: .audiobookshelf
            ))
            let trees = lab.storage.downloadedAudiobookIds()

            for _ in 0..<2 {
                try await lab.coldRestart()
                #expect(lab.session.appState.libraryCache.books.isEmpty)
                await lab.session.recovery.rescueOrphanedDownloads()
                #expect(await lab.rescuedDiskIds() == ["li_shared", "stray-li_other", "gone-tree"])
            }

            let storedEbook = try #require(await lab.store.book(uniqueId: ebook.uniqueId))
            #expect(storedEbook.linkedAudiobookStableId == audio.stableId && storedEbook.linkedAudiobookChapterOffset == 2)
            #expect(storedEbook.epubLocator == ebook.epubLocator)
            #expect(await lab.store.linkedAudiobookStableId(forEbookStableId: ebook.stableId) == audio.stableId)
            let storedAudio = try #require(await lab.store.book(uniqueId: audio.uniqueId))
            #expect(storedAudio.stableId == audio.stableId && storedAudio.providerId == first && storedAudio.currentTime == 77)
            #expect(lab.storage.isAudiobookDownloaded(storedAudio))
            #expect(!lab.storage.isAudiobookDownloaded(sameItemOnSecond) && !lab.storage.isAudiobookDownloaded(sharedOnFirst))
            #expect(lab.storage.isAudiobookDownloaded(try #require(await lab.store.book(uniqueId: legacy.uniqueId))))
            lab.storage.invalidateDownloadedIdsCache()
            #expect(lab.storage.downloadedAudiobookIds() == trees)
        } catch {
            await lab.close()
            throw error
        }
        await lab.close()
    }

    @Test func rescuedRowsOfAnOwnedBookAreReconciledKeepingTheNewerListeningAndEveryCopy() async throws {
        let lab = try Lab()
        do {
            let provider = UUID()
            let now = Date()
            // Already downloaded and listened to since the copy was rescued.
            let downloaded = Lab.audiobook("li_kept", provider: provider, currentTime: 300, lastUpdate: now)
            // Not downloaded; the rescued copy was listened to more recently than the original.
            let missing = Lab.audiobook("li_moved", provider: provider, currentTime: 10, lastUpdate: now.addingTimeInterval(-3 * 86_400))
            await lab.store.upsertBooks([downloaded, missing])
            try lab.writeTree(downloaded.downloadKey, metadata: Lab.metadata(for: downloaded))
            try lab.writeTree("li_kept", metadata: Lab.metadata(for: downloaded))
            // A folder name no book claims, so its exact metadata owner takes it under the canonical key.
            try lab.writeTree("old-folder", metadata: Lab.metadata(for: missing))
            let olderListening = now.addingTimeInterval(-2 * 86_400)
            let newerListening = now.addingTimeInterval(-86_400)
            await lab.store.upsertBooks([
                Lab.rescued("li_kept", currentTime: 50, lastUpdate: olderListening),
                Lab.rescued("old-folder", currentTime: 120, lastUpdate: newerListening),
            ])

            try await lab.coldRestart()
            await lab.session.recovery.rescueOrphanedDownloads()
            try await lab.until { await lab.rescuedDiskIds().isEmpty }
            try await lab.until { await lab.store.book(uniqueId: missing.uniqueId)?.currentTime == 120 }

            let kept = try #require(await lab.store.book(uniqueId: downloaded.uniqueId))
            #expect(kept.currentTime == 300 && abs(kept.lastUpdate.timeIntervalSince(now)) < 1)
            #expect(lab.storage.isAudiobookDownloaded(downloaded.downloadKey) && lab.storage.isAudiobookDownloaded("li_kept"))
            let moved = try #require(await lab.store.book(uniqueId: missing.uniqueId))
            #expect(abs(moved.lastUpdate.timeIntervalSince(newerListening)) < 1)
            #expect(lab.storage.isAudiobookDownloaded(missing.downloadKey) && !lab.storage.isAudiobookDownloaded("old-folder"))

            // The kept second copy is recognized on the next launch, not rescued again.
            try await lab.coldRestart()
            await lab.session.recovery.rescueOrphanedDownloads()
            #expect(await lab.rescuedDiskIds().isEmpty)
            #expect(lab.storage.isAudiobookDownloaded("li_kept"))
        } catch {
            await lab.close()
            throw error
        }
        await lab.close()
    }
    @Test func reconciliationCarriesTheLatestRescuedObservationIncludingAnExplicitRestart() async throws {
        let lab = try Lab()
        do {
            let provider = UUID()
            let now = Date()
            let entryNewer = Lab.audiobook("li_entry", provider: provider, currentTime: 10, lastUpdate: now.addingTimeInterval(-5 * 86_400))
            let restarted = Lab.audiobook("li_zero", provider: provider, currentTime: 90, lastUpdate: now.addingTimeInterval(-2 * 86_400))
            let originalNewer = Lab.audiobook("li_newer", provider: provider, currentTime: 300, lastUpdate: now.addingTimeInterval(-3600))
            await lab.store.upsertBooks([entryNewer, restarted, originalNewer])
            let rows = [
                (entryNewer, "old-entry", Lab.rescued("old-entry", currentTime: 50, lastUpdate: now.addingTimeInterval(-4 * 86_400))),
                (restarted, "old-zero", Lab.rescued("old-zero", currentTime: 0, lastUpdate: now.addingTimeInterval(-3 * 86_400))),
                (originalNewer, "old-newer", Lab.rescued("old-newer", currentTime: 40, lastUpdate: now.addingTimeInterval(-2 * 86_400))),
            ]
            for (original, tree, _) in rows { try lab.writeTree(tree, metadata: Lab.metadata(for: original)) }
            await lab.store.upsertBooks(rows.map(\.2))

            try await lab.coldRestart()
            let progress = lab.session.progress
            for (rescued, time, at) in [
                (rows[0].2, 200.0, now.addingTimeInterval(-86_400)),
                (rows[1].2, 0.0, now.addingTimeInterval(-3600 * 2)),
                (rows[2].2, 45.0, now.addingTimeInterval(-2 * 86_400)),
            ] {
                progress.update(UserMediaProgress(
                    id: rescued.id, libraryItemId: rescued.id, providerId: rescued.providerId, episodeId: nil, currentTime: time,
                    progress: time / 600, isFinished: false, duration: 600, lastUpdate: at, ebookProgress: nil
                ))
            }
            await lab.session.recovery.rescueOrphanedDownloads()
            try await lab.until { await lab.rescuedDiskIds().isEmpty }
            try await lab.until { await lab.store.book(uniqueId: entryNewer.uniqueId)?.currentTime == 200 }
            try await lab.until { await lab.store.book(uniqueId: restarted.uniqueId)?.currentTime == 0 }

            let carried = try #require(await lab.store.book(uniqueId: entryNewer.uniqueId))
            #expect(abs(carried.lastUpdate.timeIntervalSince(now.addingTimeInterval(-86_400))) < 1)
            let saved = try #require(lab.session.bookProgress.loadProgress(for: entryNewer))
            #expect(saved.progress == 200 && abs(saved.lastUpdated - now.addingTimeInterval(-86_400).timeIntervalSince1970) < 1)
            let rewound = try #require(await lab.store.book(uniqueId: restarted.uniqueId))
            #expect(abs(rewound.lastUpdate.timeIntervalSince(now.addingTimeInterval(-7200))) < 1)
            let kept = try #require(await lab.store.book(uniqueId: originalNewer.uniqueId))
            #expect(kept.currentTime == 300 && abs(kept.lastUpdate.timeIntervalSince(now.addingTimeInterval(-3600))) < 1)
            #expect(lab.session.bookProgress.loadProgress(for: originalNewer) == nil)
            #expect(progress.progress(forUniqueId: originalNewer.uniqueId) == nil)
            for (original, _, _) in rows { #expect(lab.storage.isAudiobookDownloaded(original)) }
        } catch {
            await lab.close()
            throw error
        }
        await lab.close()
    }
    @Test func rescuedRowsAnEbookLinksToAreKeptWithTheirLinksAndPositions() async throws {
        let lab = try Lab()
        do {
            let provider = UUID()
            let fieldOriginal = Lab.audiobook("li_field", provider: provider, currentTime: 12)
            let tableOriginal = Lab.audiobook("li_table", provider: provider, currentTime: 34)
            let fieldRescued = Lab.rescued("field-tree", currentTime: 400, lastUpdate: Date())
            let tableRescued = Lab.rescued("table-tree", currentTime: 500, lastUpdate: Date())
            let sourceOriginal = Lab.audiobook("li_source", provider: provider, currentTime: 56)
            let sourceRescued = Lab.rescued("source-tree", currentTime: 600, lastUpdate: Date())
            var readAloud = Lab.ebook("li_source_text", provider: provider, linkedTo: sourceRescued)
            readAloud.linkedAudiobookStableId = nil
            readAloud.readAloudSourceStableId = sourceRescued.stableId
            let fieldEbook = Lab.ebook("li_field_text", provider: provider, linkedTo: fieldRescued)
            var tableEbook = Lab.ebook("li_table_text", provider: provider, linkedTo: tableRescued)
            tableEbook.linkedAudiobookStableId = nil
            tableEbook.linkedAudiobookChapterOffset = 0
            await lab.store.upsertBooks([fieldOriginal, tableOriginal, sourceOriginal, fieldRescued, tableRescued, sourceRescued,
                fieldEbook, tableEbook, readAloud])
            await lab.store.upsertLink(ebookStableId: tableEbook.stableId, audiobookStableId: tableRescued.stableId, chapterOffset: 3)
            try lab.writeTree("field-tree", metadata: Lab.metadata(for: fieldOriginal))
            try lab.writeTree("table-tree", metadata: Lab.metadata(for: tableOriginal))
            try lab.writeTree("source-tree", metadata: Lab.metadata(for: sourceOriginal))

            for _ in 0..<2 {
                try await lab.coldRestart()
                #expect(lab.session.appState.libraryCache.books.isEmpty)
                await lab.session.recovery.rescueOrphanedDownloads()
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(await lab.rescuedDiskIds() == ["field-tree", "table-tree", "source-tree"])
            #expect(await lab.store.book(uniqueId: readAloud.uniqueId)?.readAloudSourceStableId == sourceRescued.stableId)
            #expect(await lab.store.book(uniqueId: sourceOriginal.uniqueId)?.currentTime == 56)
            let fieldStored = try #require(await lab.store.book(uniqueId: fieldEbook.uniqueId))
            #expect(fieldStored.linkedAudiobookStableId == fieldRescued.stableId && fieldStored.linkedAudiobookChapterOffset == 2)
            #expect(fieldStored.epubLocator == fieldEbook.epubLocator && fieldStored.ebookProgress == fieldEbook.ebookProgress)
            let links = await lab.store.allLinks()
            #expect(links.contains { $0.ebookStableId == tableEbook.stableId && $0.audiobookStableId == tableRescued.stableId && $0.chapterOffset == 3 })
            #expect(await lab.store.book(uniqueId: tableEbook.uniqueId)?.epubLocator == tableEbook.epubLocator)
            #expect(await lab.store.book(uniqueId: fieldRescued.uniqueId)?.currentTime == 400)
            #expect(await lab.store.book(uniqueId: fieldOriginal.uniqueId)?.currentTime == 12)
            #expect(await lab.store.book(uniqueId: tableOriginal.uniqueId)?.currentTime == 34)
            for tree in ["field-tree", "table-tree", "source-tree"] { #expect(lab.storage.isAudiobookDownloaded(tree)) }
        } catch {
            await lab.close()
            throw error
        }
        await lab.close()
    }
    @Test(arguments: [false, true])
    func everyRescuedFolderKeepsItsOwnRowAcrossColdStarts(reversed: Bool) async throws {
        let lab = try Lab()
        do {
            let first = reversed ? "z-copy" : "a-copy"
            let second = reversed ? "a-li_same" : "z-li_same"
            let shared = OfflineBookMetadata(id: second, stableId: "audiobookshelf:\(UUID().uuidString):\(second)", title: "Same",
                author: nil, narrator: nil, duration: nil, chapters: nil, audioTracks: nil, coverURLString: nil, source: .audiobookshelf)
            try lab.writeTree(first, metadata: shared)
            try lab.writeTree(second, metadata: shared)
            try lab.writeTree("fresh-folder", metadata: nil)
            try lab.writeTree("older-tree", metadata: nil)
            await lab.store.upsertBooks([Lab.rescued("older-tree", id: "fresh-folder", currentTime: 0, lastUpdate: Date())])

            var rows: [String: String] = [:]
            for pass in 0..<2 {
                try await lab.coldRestart()
                lab.session.appState.libraryCache.load([])
                #expect(lab.session.appState.libraryCache.books.isEmpty)
                await lab.session.recovery.rescueOrphanedDownloads()
                let rescued = await lab.store.books(source: Book.BookSource.local.rawValue, providerId: DownloadLinkRecoveryTests.rescueProvider)
                    .filter { $0.libraryId == "rescued-downloads" }
                #expect(rescued.count == 4)
                #expect(Set(rescued.compactMap(\.partKey)).count == rescued.count)
                #expect(Set(rescued.map(\.uniqueId)).count == rescued.count)
                let byFolder = Dictionary(rescued.compactMap { book in book.partKey.map { ($0, book.uniqueId) } }, uniquingKeysWith: { a, _ in a })
                #expect(Set(byFolder.keys) == [first, second, "fresh-folder", "older-tree"])
                if pass == 1 { #expect(byFolder == rows) }
                rows = byFolder
            }
            #expect(await lab.store.book(uniqueId: rows["older-tree"] ?? "")?.id == "fresh-folder")
            for tree in [first, second, "fresh-folder", "older-tree"] { #expect(lab.storage.isAudiobookDownloaded(tree)) }
            #expect((try? lab.storage.loadMetadataOverride(OfflineBookMetadata.self, for: first))?.stableId == shared.stableId)
        } catch {
            await lab.close()
            throw error
        }
        await lab.close()
    }
    @Test func aMirroredRawIdIsNotOwnershipOfAFolder() async throws {
        let lab = try Lab()
        do {
            let first = UUID(), second = UUID(), stranger = UUID()
            let onFirst = Lab.audiobook("li_twice", provider: first)
            let onSecond = Lab.audiobook("li_twice", provider: second)
            let single = Lab.audiobook("li_once", provider: first)
            await lab.store.upsertBooks([onFirst, onSecond, single])
            try lab.writeTree(onFirst.downloadKey, metadata: Lab.metadata(for: onFirst))
            try lab.writeTree("li_twice", metadata: nil)
            try lab.writeTree("old-twice", metadata: OfflineBookMetadata(
                id: "li_twice", stableId: "audiobookshelf:\(stranger.uuidString):li_twice", title: "Elsewhere", author: nil,
                narrator: nil, duration: nil, chapters: nil, audioTracks: nil, coverURLString: nil, source: .audiobookshelf
            ))
            try lab.writeTree("li_once", metadata: Lab.metadata(for: single))

            try await lab.coldRestart()
            lab.session.appState.libraryCache.load([onFirst, onSecond, single])
            await lab.session.recovery.rescueOrphanedDownloads()
            let rescued = await lab.rescuedDiskIds()
            #expect(rescued == ["li_twice", "old-twice"], "rescued \(rescued.sorted())")
            #expect(lab.storage.isAudiobookDownloaded(onFirst) && !lab.storage.isAudiobookDownloaded(onSecond))
            #expect(lab.storage.isAudiobookDownloaded(single))
        } catch {
            await lab.close()
            throw error
        }
        await lab.close()
    }

    @Test func theNewestObservationReachesEveryProgressStoreWhicheverSourceHoldsIt() async throws {
        let lab = try Lab()
        do {
            let provider = UUID()
            let now = Date(timeIntervalSinceReferenceDate: (815_000_000.0).nextUp.nextUp.nextUp + 3600)
            let latest = now.addingTimeInterval(-3600)
            #expect(Date(timeIntervalSince1970: latest.timeIntervalSince1970) > latest)
            let savedNewest = Lab.audiobook("li_saved", provider: provider, currentTime: 5, lastUpdate: now.addingTimeInterval(-5 * 86_400))
            let tied = Lab.audiobook("li_tied", provider: provider, currentTime: 5, lastUpdate: now.addingTimeInterval(-5 * 86_400))
            let originalTied = Lab.audiobook("li_original_tied", provider: provider, currentTime: 430, lastUpdate: latest)
            await lab.store.upsertBooks([savedNewest, tied, originalTied])
            let savedRow = Lab.rescued("saved-tree", currentTime: 0, lastUpdate: now.addingTimeInterval(-4 * 86_400))
            let tiedRow = Lab.rescued("tied-tree", currentTime: 0, lastUpdate: now.addingTimeInterval(-4 * 86_400))
            let originalTiedRow = Lab.rescued("original-tied-tree", currentTime: 0, lastUpdate: now.addingTimeInterval(-4 * 86_400))
            try lab.writeTree("saved-tree", metadata: Lab.metadata(for: savedNewest))
            try lab.writeTree("tied-tree", metadata: Lab.metadata(for: tied))
            try lab.writeTree("original-tied-tree", metadata: Lab.metadata(for: originalTied))
            await lab.store.upsertBooks([savedRow, tiedRow, originalTiedRow])

            try await lab.coldRestart()
            let progress = lab.session.progress
            let saved = lab.session.bookProgress
            func entry(_ book: Book, _ time: TimeInterval, _ at: Date) -> UserMediaProgress {
                UserMediaProgress(id: book.id, libraryItemId: book.id, providerId: book.providerId, episodeId: nil,
                    currentTime: time, progress: time / 600, isFinished: false, duration: 600, lastUpdate: at, ebookProgress: nil)
            }
            // Saved progress alone is newest; the original keeps an older progress entry of its own.
            progress.update(entry(savedNewest, 7, now.addingTimeInterval(-4.5 * 86_400)))
            progress.update(entry(savedRow, 20, now.addingTimeInterval(-2 * 86_400)))
            saved.saveProgress(for: savedRow, progress: 333, duration: 600, at: latest)
            // Two sources at the same time disagree; the progress entry is the one carried, everywhere.
            progress.update(entry(tiedRow, 200, latest))
            saved.saveProgress(for: tiedRow, progress: 150, duration: 600, at: latest)
            saved.saveProgress(for: originalTiedRow, progress: 111, duration: 600, at: latest)

            await lab.session.recovery.rescueOrphanedDownloads()
            try await lab.until { await lab.rescuedDiskIds().isEmpty }
            for (book, time) in [(savedNewest, 333.0), (tied, 200.0)] {
                try await lab.until { await lab.store.book(uniqueId: book.uniqueId)?.currentTime == time }
                let stored = try #require(await lab.store.book(uniqueId: book.uniqueId))
                #expect(abs(stored.lastUpdate.timeIntervalSince(latest)) < 1)
                let entryNow = try #require(progress.progress(forUniqueId: book.uniqueId))
                #expect(entryNow.currentTime == time && abs(entryNow.lastUpdate.timeIntervalSince(latest)) < 1)
                let savedNow = try #require(saved.loadProgress(for: book))
                #expect(savedNow.progress == time && abs(savedNow.lastUpdated - latest.timeIntervalSince1970) < 1)
                let pending = try #require(lab.session.pendingSync.entries[book.stableId])
                #expect(pending.position == time && abs(pending.updatedAt - latest.timeIntervalSince1970) < 1)
            }
            let kept = try #require(await lab.store.book(uniqueId: originalTied.uniqueId))
            #expect(kept.currentTime == 430 && kept.lastUpdate.timeIntervalSince1970 == latest.timeIntervalSince1970)
            #expect(progress.progress(forUniqueId: originalTied.uniqueId) == nil)
            #expect(saved.loadProgress(for: originalTied) == nil)
            #expect(lab.session.pendingSync.entries[originalTied.stableId] == nil)
        } catch {
            await lab.close()
            throw error
        }
        await lab.close()
    }
    @Test func aProviderEbookDownloadKeepsLinksAndPositionsChangedWhileItWasHeld() async throws {
        let lab = try Lab()
        do {
            let provider = GatedEbookProvider()
            let audio = Lab.audiobook("li_heard", provider: UUID())
            let replacement = Lab.audiobook("li_heard_again", provider: audio.providerId)
            let relinked = Lab.kavitaEbook("relinked", provider: provider, linkedTo: audio)
            let unlinked = Lab.kavitaEbook("unlinked", provider: provider, linkedTo: audio)
            let removed = Lab.kavitaEbook("removed", provider: provider, linkedTo: audio)
            let unsaved = Lab.kavitaEbook("unsaved", provider: provider, linkedTo: audio)
            let refused = Lab.kavitaEbook("refused", provider: provider, linkedTo: audio)
            await lab.store.upsertBooks([audio, replacement, relinked, unlinked, removed, refused])
            for ebook in [relinked, unlinked, removed, refused] {
                await lab.store.upsertLink(ebookStableId: ebook.stableId, audiobookStableId: audio.stableId, chapterOffset: 2)
            }
            let readLocator = #"{"href":"c2.xhtml","type":"application/xhtml+xml","locations":{"progression":0.5,"totalProgression":0.6}}"#

            // A stale mirror: the store relinks and moves the reading position while the mirror keeps the old row.
            try await lab.coldRestart()
            lab.session.appState.libraryCache.load([relinked])
            var outcome = try await lab.download(relinked, from: provider) {
                var fresh = try #require(await lab.store.book(uniqueId: relinked.uniqueId))
                fresh.linkedAudiobookStableId = replacement.stableId
                fresh.linkedAudiobookChapterOffset = 0
                fresh.epubLocator = readLocator
                fresh.ebookProgress = 0.6
                await lab.store.upsertBooks([fresh])
                await lab.store.upsertLink(ebookStableId: relinked.stableId, audiobookStableId: replacement.stableId, chapterOffset: 0)
            }
            #expect(outcome == .completed)
            #expect(lab.session.appState.libraryCache.bookInMemory(uniqueId: relinked.uniqueId)?.ebookFileURL != nil)
            try await lab.coldRestart()
            let stored = try #require(await lab.store.book(uniqueId: relinked.uniqueId))
            #expect(stored.linkedAudiobookStableId == replacement.stableId && stored.epubLocator == readLocator && stored.ebookProgress == 0.6)
            #expect(stored.ebookFileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
            #expect(await lab.store.linkedAudiobookStableId(forEbookStableId: relinked.stableId) == replacement.stableId)

            // The reader unlinks through the mirror while the transfer is held.
            lab.session.appState.libraryCache.load([unlinked])
            outcome = try await lab.download(unlinked, from: provider) {
                lab.session.appState.mutateBook(uniqueId: unlinked.uniqueId) {
                    $0.linkedAudiobookStableId = nil
                    $0.linkedAudiobookChapterOffset = 0
                }
                await lab.store.removeLink(ebookStableId: unlinked.stableId)
            }
            #expect(outcome == .completed)
            try await lab.coldRestart()
            let cleared = try #require(await lab.store.book(uniqueId: unlinked.uniqueId))
            #expect(cleared.linkedAudiobookStableId == nil && cleared.ebookFileURL != nil)
            #expect(await lab.store.linkedAudiobookStableId(forEbookStableId: unlinked.stableId) == nil)

            // Removed while held: the finished transfer reports the removal, keeps its file and re-adds nothing.
            let filesBefore = lab.downloadedEbookCount()
            outcome = try await lab.download(removed, from: provider) {
                await lab.store.deleteBooks(uniqueIds: [removed.uniqueId])
            }
            #expect(outcome == .failed)
            #expect(lab.downloadedEbookCount() == filesBefore + 1)
            try await lab.coldRestart()
            #expect(await lab.store.book(uniqueId: removed.uniqueId) == nil)

            // A book first seen by the download is registered before the transfer and keeps its link.
            outcome = try await lab.download(unsaved, from: provider) {}
            #expect(outcome == .completed)
            try await lab.coldRestart()
            let registered = try #require(await lab.store.book(uniqueId: unsaved.uniqueId))
            #expect(registered.ebookFileURL != nil && registered.linkedAudiobookStableId == audio.stableId)

            // A failed store write fails the download; the row and the downloaded file are both kept.
            outcome = try await lab.download(refused, from: provider, failingWrites: true) {}
            #expect(outcome == .failed)
            try await lab.coldRestart()
            let untouched = try #require(await lab.store.book(uniqueId: refused.uniqueId))
            #expect(untouched.ebookFileURL == nil && untouched.linkedAudiobookStableId == audio.stableId)
            #expect(lab.downloadedEbookCount() == filesBefore + 3)
        } catch {
            await lab.close()
            throw error
        }
        await lab.close()
    }
    @Test(arguments: [false, true])
    func aCompletionInterruptedDuringItsStoreWriteIsNeverReportedComplete(retire: Bool) async throws {
        let lab = try Lab()
        do {
            let provider = GatedEbookProvider()
            let audio = Lab.audiobook("li_heard", provider: UUID())
            let ebook = Lab.kavitaEbook(retire ? "retired" : "cancelled", provider: provider, linkedTo: audio)
            await lab.store.upsertBooks([audio, ebook])
            let writer = GatedDownloadWriter(base: lab.store)
            let held = PassageAlignmentServiceTests.Gate()
            writer.gate = held
            let service = try await lab.makeService(provider: provider, writer: writer)
            @MainActor final class Completions { var count = 0 }
            let completions = Completions()
            let observer = NotificationCenter.default.addObserver(
                forName: UnifiedDownloadService.downloadCompletedNotification, object: nil, queue: nil
            ) { _ in MainActor.assumeIsolated { completions.count += 1 } }
            defer { NotificationCenter.default.removeObserver(observer) }
            let running = Task { await service.download(book: ebook) }
            try await lab.until { writer.heldWrites == 1 }
            var retiring: Task<Void, Never>?
            if retire {
                retiring = Task { await service.retire() }
                try await lab.until { service.isRetired }
            } else {
                let taskId = try #require(service.tasks.last { $0.bookId == ebook.downloadKey }?.id)
                service.cancel(taskId: taskId)
            }
            held.open()
            await running.value
            await retiring?.value
            #expect(service.tasks.last { $0.bookId == ebook.downloadKey }?.status != .completed)
            #expect(completions.count == 0)
            if !retire { await service.retire() }

            try await lab.coldRestart()
            let stored = try #require(await lab.store.book(uniqueId: ebook.uniqueId))
            #expect(stored.ebookFileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
            #expect(stored.linkedAudiobookStableId == audio.stableId)
        } catch {
            await lab.close()
            throw error
        }
        await lab.close()
    }

    @Test func registeringADownloadNeverRewritesOrRevivesAStoredRow() async throws {
        let lab = try Lab()
        do {
            let provider = GatedEbookProvider()
            let audio = Lab.audiobook("li_heard", provider: UUID())
            let replacement = Lab.audiobook("li_heard_again", provider: audio.providerId)
            let captured = Lab.kavitaEbook("captured", provider: provider, linkedTo: audio)
            var current = captured
            current.linkedAudiobookStableId = replacement.stableId
            current.epubLocator = #"{"href":"c2.xhtml","type":"application/xhtml+xml","locations":{"progression":0.5,"totalProgression":0.6}}"#
            await lab.store.upsertBooks([audio, replacement, current])
            try await lab.store.registerDownloadIfMissing(captured)
            let kept = try #require(await lab.store.book(uniqueId: captured.uniqueId))
            #expect(kept.linkedAudiobookStableId == replacement.stableId && kept.epubLocator == current.epubLocator)

            let deleted = Lab.kavitaEbook("deleted", provider: provider, linkedTo: audio)
            await lab.store.upsertBooks([deleted])
            await lab.store.setDeleted(true, stableId: deleted.stableId)
            let outcome = try await lab.download(deleted, from: provider) {}
            #expect(outcome == .failed)
            try await lab.coldRestart()
            #expect(await lab.store.books(withIds: [deleted.id]).isEmpty)
        } catch {
            await lab.close()
            throw error
        }
        await lab.close()
    }

    @MainActor
    final class Lab {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        private let profile = FamilyProfile(id: UUID().uuidString, name: "Download links", role: .adult)
        private var serviceRoots = 0
        private let domain = "DownloadLinkRecoveryTests.\(UUID().uuidString)"
        private let locations: ProfileStorageLocations
        private let defaults: UserDefaults
        private(set) var session: ProfileSession

        var store: BookStoreRepository { session.bookStore }
        var storage: LocalStorageManager { session.localStorage }

        init() throws {
            locations = ProfileStorageLocations(profileID: profile.id,
                documentsDirectory: root.appendingPathComponent("Documents"),
                applicationSupportDirectory: root.appendingPathComponent("Support"),
                cachesDirectory: root.appendingPathComponent("Caches"))
            defaults = try #require(UserDefaults(suiteName: domain))
            ProfileServerSyncPreferences(defaults: defaults, isOwner: false).isEnabled = true
            session = try ProfileSession(profile: profile, storage: locations, defaults: defaults)
        }

        func coldRestart() async throws {
            await session.retire()
            session = try ProfileSession(profile: profile, storage: locations, defaults: defaults)
        }

        func writeTree(_ key: String, metadata: OfflineBookMetadata?) throws {
            let directory = storage.bookAudioDirectory(for: key)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 120_000).write(to: directory.appendingPathComponent("chapter_0.mp3"))
            if let metadata { try storage.saveMetadataOverride(metadata, for: key) }
            storage.invalidateDownloadedIdsCache()
        }

        enum Outcome { case completed, failed, other }
        func download(
            _ book: Book, from provider: GatedEbookProvider, failingWrites: Bool = false, whileHeld: () async throws -> Void
        ) async throws -> Outcome {
            let service = try await makeService(provider: provider, writer: failingWrites ? FailingDownloadWriter(base: store) : store)
            let gate = PassageAlignmentServiceTests.Gate()
            provider.gate = gate
            let requests = provider.requests
            let running = Task { await service.download(book: book) }
            try await until { provider.requests > requests }
            try await whileHeld()
            gate.open()
            await running.value
            let status = service.tasks.last { $0.bookId == book.downloadKey }?.status
            await service.retire()
            switch status {
            case .completed: return .completed
            case .failed: return .failed
            default: return .other
            }
        }

        func makeService(provider: GatedEbookProvider, writer: any BookWriting) async throws -> UnifiedDownloadService {
            serviceRoots += 1
            let queueRoot = root.appendingPathComponent("queue-\(serviceRoots)")
            let queueStorage = ProfileStorageLocations(profileID: profile.id,
                documentsDirectory: queueRoot.appendingPathComponent("Documents"),
                applicationSupportDirectory: queueRoot.appendingPathComponent("Support"),
                cachesDirectory: queueRoot.appendingPathComponent("Caches"))
            let service = try UnifiedDownloadService(
                storage: queueStorage, defaults: defaults, storageManager: storage, ebookImporter: session.ebooks,
                localLibrary: session.localLibrary, preferences: session.preferences, readerArtifacts: session.readerArtifacts,
                downloadManager: BookDownloadManager(storage: storage, activity: ProfileDownloadActivity(), clientCertificate: { _ in nil }),
                providerConnections: Resolver(provider: provider), presentation: session.appState.presentation,
                bookQuerying: store, bookWriting: writer, libraryCache: session.appState, clientCertificate: { _ in nil }
            )
            service.start()
            try await until { service.networkMonitorCurrentPath.status == .satisfied }
            return service
        }

        func downloadedEbookCount() -> Int {
            let root = session.ebooks.serverEbooksRoot
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            return files.filter { $0.pathExtension == "epub" }.count
        }

        func rescuedDiskIds() async -> Set<String> {
            Set(await store.books(source: Book.BookSource.local.rawValue, providerId: DownloadLinkRecoveryTests.rescueProvider)
                .filter { $0.libraryId == "rescued-downloads" }
                .compactMap(\.partKey))
        }

        func until(_ condition: () async -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                if await condition() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            Issue.record("Condition not reached within 5 seconds")
        }

        func close() async {
            await session.retire()
            defaults.removePersistentDomain(forName: domain)
            if let preferencesDomain = locations.preferencesDomain { defaults.removePersistentDomain(forName: preferencesDomain) }
            try? FileManager.default.removeItem(at: root)
        }

        static func audiobook(
            _ id: String, provider: UUID, backendId: String? = nil, currentTime: TimeInterval = 0, lastUpdate: Date = Date()
        ) -> Book {
            Book(id: id, title: "Synthetic \(id)", duration: 600, source: .audiobookshelf, backendId: backendId,
                currentTime: currentTime, lastUpdate: lastUpdate, providerId: provider, libraryId: "audiobooks")
        }

        static func ebook(_ id: String, provider: UUID, linkedTo audiobook: Book) -> Book {
            Book(id: id, title: "Synthetic \(id)", source: .audiobookshelf, mediaType: .ebook,
                epubLocator: #"{"href":"c1.xhtml","type":"application/xhtml+xml","locations":{"progression":0.25,"totalProgression":0.3}}"#,
                ebookProgress: 0.3, linkedAudiobookStableId: audiobook.stableId, linkedAudiobookChapterOffset: 2,
                providerId: provider, libraryId: "ebooks")
        }

        static func kavitaEbook(_ id: String, provider: GatedEbookProvider, linkedTo audiobook: Book) -> Book {
            Book(id: id, title: "Synthetic \(id)", source: .kavita, mediaType: .ebook, ebookFormat: "epub",
                epubLocator: #"{"href":"c1.xhtml","type":"application/xhtml+xml","locations":{"progression":0.25,"totalProgression":0.3}}"#,
                ebookProgress: 0.3, linkedAudiobookStableId: audiobook.stableId, linkedAudiobookChapterOffset: 2,
                providerId: provider.connection.id, libraryId: "ebooks")
        }

        static func rescued(_ diskId: String, id: String? = nil, currentTime: TimeInterval, lastUpdate: Date) -> Book {
            Book(id: id ?? diskId, ratingKey: id ?? diskId, title: "Rescued \(diskId)", partKey: diskId, source: .local,
                backendId: "rescued-downloads", currentTime: currentTime, lastUpdate: lastUpdate,
                providerId: DownloadLinkRecoveryTests.rescueProvider, libraryId: "rescued-downloads")
        }

        static func metadata(for book: Book) -> OfflineBookMetadata {
            OfflineBookMetadata(id: book.id, stableId: book.stableId, title: book.title, author: nil, narrator: nil,
                duration: book.duration, chapters: nil, audioTracks: nil, coverURLString: nil, source: book.source)
        }
    }

    @MainActor
    final class Resolver: ProviderConnectionAccessing {
        let provider: LibraryProvider
        init(provider: LibraryProvider) { self.provider = provider }
        var connections: [ServerConnection] { [provider.connection] }
        func backend(id: String) -> BackendConfig? { nil }
        func allBackends() -> [BackendConfig] { [] }
        func provider(for providerId: UUID) -> LibraryProvider? { providerId == provider.connection.id ? provider : nil }
        func provider(for book: Book) -> LibraryProvider? { provider(for: book.providerId) }
    }
    final class GatedEbookProvider: LibraryProvider, EbookDownloadProvider {
        var connection = ServerConnection(name: "Synthetic gated fixture", url: "https://example.invalid", type: .kavita)
        var capabilities: ProviderCapabilities { [.downloads] }
        var gate: PassageAlignmentServiceTests.Gate?
        private(set) var requests = 0

        func validateConnection() async throws -> Bool { true }
        func fetchLibraries() async throws -> [Library] { [] }
        func fetchBooks(libraryId: String) async throws -> [Book] { [] }
        func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] { [] }
        func fetchCollections(libraryId: String?) async throws -> [Collection] { [] }
        func fetchSeries(libraryId: String) async throws -> [Series] { [] }
        func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { [] }
        func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book { throw URLError(.resourceUnavailable) }

        func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)?) async throws -> URL {
            requests += 1
            await gate?.waitIgnoringCancellation()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let contents = folder.appendingPathComponent("contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
            let files = [
                "mimetype": "application/epub+zip",
                "META-INF/container.xml": #"<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#,
                "package.opf": #"<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">gated-fixture</dc:identifier><dc:title>Gated fixture</dc:title><dc:language>en</dc:language></metadata><manifest><item id="one" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/></spine></package>"#,
                "c1.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>One</title></head><body><p>A synthetic chapter.</p></body></html>",
            ]
            for (name, value) in files { try Data(value.utf8).write(to: contents.appendingPathComponent(name)) }
            let file = folder.appendingPathComponent("\(book.id).epub")
            try await FileManager.default.zipItem(at: contents, to: file, shouldKeepParent: false)
            return file
        }
    }
    final class FailingDownloadWriter: BookWriting {
        let base: any BookWriting
        init(base: any BookWriting) { self.base = base }
        struct WriteFailed: Error {}

        func upsertBooks(_ books: [Book]) async { await base.upsertBooks(books) }
        func replaceLibrary(books: [Book], libraryId: String, providerId: UUID, allowSparseResult: Bool) async {
            await base.replaceLibrary(books: books, libraryId: libraryId, providerId: providerId, allowSparseResult: allowSparseResult)
        }
        func deleteBooksFromUnknownProviders(validProviderIds: Set<String>) async -> Int {
            await base.deleteBooksFromUnknownProviders(validProviderIds: validProviderIds)
        }
        func deleteBooksFromInactiveLibraries(validProviderIds: Set<String>, restrictedLibraryIds: [String: Set<String>]) async -> Int {
            await base.deleteBooksFromInactiveLibraries(validProviderIds: validProviderIds, restrictedLibraryIds: restrictedLibraryIds)
        }
        func updateEbookFileURL(uniqueId: String, url: URL?) async { await base.updateEbookFileURL(uniqueId: uniqueId, url: url) }
        func updateDownloadedEbook(uniqueId: String, fileURL: URL, epub3Features: EPUB3Features?) async throws -> Bool {
            throw WriteFailed()
        }
        func registerDownloadIfMissing(_ book: Book) async throws { try await base.registerDownloadIfMissing(book) }
        func setHidden(_ hidden: Bool, stableId: String) async { await base.setHidden(hidden, stableId: stableId) }
        func setDeleted(_ deleted: Bool, stableId: String) async { await base.setDeleted(deleted, stableId: stableId) }
        func deleteBooks(uniqueIds: Set<String>) async { await base.deleteBooks(uniqueIds: uniqueIds) }
        func importLegacyBooks(_ books: [Book], hiddenStableIds: Set<String>, deletedStableIds: Set<String>) async {
            await base.importLegacyBooks(books, hiddenStableIds: hiddenStableIds, deletedStableIds: deletedStableIds)
        }
        func clearAllData() async { await base.clearAllData() }
    }
    final class GatedDownloadWriter: BookWriting {
        let base: any BookWriting
        var gate: PassageAlignmentServiceTests.Gate?
        private(set) var heldWrites = 0
        init(base: any BookWriting) { self.base = base }

        func upsertBooks(_ books: [Book]) async { await base.upsertBooks(books) }
        func replaceLibrary(books: [Book], libraryId: String, providerId: UUID, allowSparseResult: Bool) async {
            await base.replaceLibrary(books: books, libraryId: libraryId, providerId: providerId, allowSparseResult: allowSparseResult)
        }
        func deleteBooksFromUnknownProviders(validProviderIds: Set<String>) async -> Int {
            await base.deleteBooksFromUnknownProviders(validProviderIds: validProviderIds)
        }
        func deleteBooksFromInactiveLibraries(validProviderIds: Set<String>, restrictedLibraryIds: [String: Set<String>]) async -> Int {
            await base.deleteBooksFromInactiveLibraries(validProviderIds: validProviderIds, restrictedLibraryIds: restrictedLibraryIds)
        }
        func updateEbookFileURL(uniqueId: String, url: URL?) async { await base.updateEbookFileURL(uniqueId: uniqueId, url: url) }
        func updateDownloadedEbook(uniqueId: String, fileURL: URL, epub3Features: EPUB3Features?) async throws -> Bool {
            heldWrites += 1
            await gate?.waitIgnoringCancellation()
            return try await base.updateDownloadedEbook(uniqueId: uniqueId, fileURL: fileURL, epub3Features: epub3Features)
        }
        func registerDownloadIfMissing(_ book: Book) async throws { try await base.registerDownloadIfMissing(book) }
        func setHidden(_ hidden: Bool, stableId: String) async { await base.setHidden(hidden, stableId: stableId) }
        func setDeleted(_ deleted: Bool, stableId: String) async { await base.setDeleted(deleted, stableId: stableId) }
        func deleteBooks(uniqueIds: Set<String>) async { await base.deleteBooks(uniqueIds: uniqueIds) }
        func importLegacyBooks(_ books: [Book], hiddenStableIds: Set<String>, deletedStableIds: Set<String>) async {
            await base.importLegacyBooks(books, hiddenStableIds: hiddenStableIds, deletedStableIds: deletedStableIds)
        }
        func clearAllData() async { await base.clearAllData() }
    }
}
