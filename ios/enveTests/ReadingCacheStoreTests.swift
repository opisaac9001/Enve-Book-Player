import Foundation
import Testing

@testable import enve

@MainActor
final class ReadingCacheStoreTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReadingCacheStoreTests-\(UUID().uuidString)", isDirectory: true)
    private let defaultsName = "ReadingCacheStoreTests.\(UUID().uuidString)"
    private var caches: URL { root.appendingPathComponent("Caches", isDirectory: true) }

    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: defaultsName)
    }

    @Test func evictsLeastRecentlyUsedPagesUntilWithinBudget() async throws {
        let store = makeStore(byteLimit: 300)
        let pages = try (0..<5).map { index in
            try makeFile("StreamedPages/book/0000\(index).page", bytes: 100, usedSecondsAgo: Double(50 - index * 10))
        }

        await store.trim()

        #expect(pages.map(exists) == [false, false, true, true, true])
        #expect(await store.sizeBytes() == 300)
    }

    @Test func touchingAnAssetKeepsItFromEviction() async throws {
        let store = makeStore(byteLimit: 200)
        let oldest = try makeFile("ReaderEbooks/a.epub", bytes: 100, usedSecondsAgo: 30)
        let middle = try makeFile("ReaderEbooks/b.epub", bytes: 100, usedSecondsAgo: 20)
        let newest = try makeFile("ReaderEbooks/c.epub", bytes: 100, usedSecondsAgo: 10)

        await store.touch(oldest)
        await store.trim()

        #expect(exists(oldest))
        #expect(!exists(middle))
        #expect(exists(newest))
    }

    @Test func protectedArchiveDirectoriesStayWholeWhileOthersAreEvictedWhole() async throws {
        let store = makeStore(byteLimit: 300)
        let pinnedPage = try makeFile("ComicPages/pinned/001.jpg", bytes: 100, usedSecondsAgo: 100)
        let pinnedSibling = try makeFile("ComicPages/pinned/002.jpg", bytes: 100, usedSecondsAgo: 100)
        try setUsed(caches.appendingPathComponent("ComicPages/pinned"), secondsAgo: 100)
        try makeFile("ComicPages/idle/001.jpg", bytes: 100, usedSecondsAgo: 50)
        try makeFile("ComicPages/idle/002.jpg", bytes: 100, usedSecondsAgo: 50)
        let idle = caches.appendingPathComponent("ComicPages/idle")
        try setUsed(idle, secondsAgo: 50)
        let recent = try makeFile("ReaderEbooks/recent.epub", bytes: 100, usedSecondsAgo: 10)

        await store.protect([pinnedPage], owner: "reader")
        await store.trim()

        #expect(exists(pinnedPage) && exists(pinnedSibling))
        #expect(!exists(idle))
        #expect(exists(recent))
    }

    @Test func clearRemovesOnlyInactiveAssetsUntilTheReaderReleasesThem() async throws {
        let store = makeStore(byteLimit: 10_000)
        let activePage = try makeFile("StreamedPages/book/00000.page", bytes: 100, usedSecondsAgo: 5)
        let idlePage = try makeFile("StreamedPages/book/00001.page", bytes: 100, usedSecondsAgo: 5)
        let epubResource = try makeFile("StreamedEpubs/connection/book-1/OEBPS/ch1.xhtml", bytes: 150, usedSecondsAgo: 5)
        let converted = try makeFile("ConvertedEbooks/a.epub", bytes: 50, usedSecondsAgo: 5)

        await store.protect([activePage], owner: "reader")
        let first = await store.clear()

        #expect(first == ReadingCacheClearResult(removedBytes: 300, remainingBytes: 100, activeBytes: 100))
        #expect(first.retainsActiveAssets)
        #expect(exists(activePage))
        #expect(![idlePage, epubResource, converted].contains(where: exists))

        await store.release(owner: "reader")
        let second = await store.clear()

        #expect(second == ReadingCacheClearResult(removedBytes: 100, remainingBytes: 0, activeBytes: 0))
        #expect(!second.retainsActiveAssets)
        #expect(!exists(activePage))
    }

    @Test func filesOutsideTheManagedRootsAreNeverMeasuredOrRemoved() async throws {
        let store = makeStore(byteLimit: 0)
        let offline = root.appendingPathComponent("Documents/Ebooks/kept.epub")
        try FileManager.default.createDirectory(at: offline.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: offline)
        let otherProfile = try makeFile("Profiles/child/Caches/StreamedPages/book/00000.page", bytes: 100, usedSecondsAgo: 500)
        let unrelated = try makeFile("Thumbnails/cover.jpg", bytes: 100, usedSecondsAgo: 500)
        let managed = try makeFile("StreamedPages/book/00000.page", bytes: 100, usedSecondsAgo: 500)

        #expect(await store.sizeBytes() == 100)
        await store.trim()
        _ = await store.clear()

        #expect(!exists(managed))
        #expect(exists(offline) && exists(otherProfile) && exists(unrelated))
        await #expect(throws: ReadingCacheError.outsideManagedRoots) {
            try await store.write(Data([1]), to: otherProfile, lease: ReadingCacheWriteLease(), generation: store.clearGeneration)
        }
        #expect(try Data(contentsOf: otherProfile).count == 100)
    }

    @Test func revokedLeasesStaleGenerationsAndCanceledTasksDropWrites() async throws {
        let store = makeStore(byteLimit: 10_000)
        let target = caches.appendingPathComponent("StreamedPages/book/00000.page")

        let revoked = ReadingCacheWriteLease()
        revoked.revoke()
        #expect(try await !store.write(Data([1]), to: target, lease: revoked, generation: store.clearGeneration))

        let staleGeneration = store.clearGeneration
        _ = await store.clear()
        #expect(try await !store.write(Data([1]), to: target, lease: ReadingCacheWriteLease(), generation: staleGeneration))

        let canceled = try await Task { () async throws -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.write(Data([1]), to: target, lease: ReadingCacheWriteLease(), generation: store.clearGeneration)
        }.value
        #expect(!canceled)
        #expect(!exists(target))

        #expect(try await store.write(Data([1]), to: target, lease: ReadingCacheWriteLease(), generation: store.clearGeneration))
        #expect(exists(target))
    }

    @Test func budgetedWritesEvictOtherBooksButNeverTheirOwnPages() async throws {
        let store = makeStore(byteLimit: 250)
        let otherBook = try makeFile("StreamedPages/other/00000.page", bytes: 100, usedSecondsAgo: 60)
        let ownOlder = try makeFile("StreamedPages/book/00000.page", bytes: 100, usedSecondsAgo: 30)
        let bookDirectory = caches.appendingPathComponent("StreamedPages/book", isDirectory: true)
        let lease = ReadingCacheWriteLease()

        let admitted = try await store.write(
            Data(repeating: 2, count: 100), to: bookDirectory.appendingPathComponent("00001.page"),
            lease: lease, generation: store.clearGeneration, admission: .ifRoom(sparing: bookDirectory))
        let refused = try await store.write(
            Data(repeating: 2, count: 100), to: bookDirectory.appendingPathComponent("00002.page"),
            lease: lease, generation: store.clearGeneration, admission: .ifRoom(sparing: bookDirectory))

        #expect(admitted)
        #expect(!refused)
        #expect(!exists(otherBook))
        #expect(exists(ownOlder))
        #expect(!exists(bookDirectory.appendingPathComponent("00002.page")))
        #expect(await store.sizeBytes() == 200)
    }

    @Test func theBudgetPersistsPerProfileDefaults() async throws {
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let store = ReadingCacheStore(cachesDirectory: caches, defaults: defaults)
        #expect(store.limitMegabytes == ReadingCacheStore.defaultLimitMegabytes)

        await store.setLimit(megabytes: 64)
        await store.setLimit(megabytes: 100)

        #expect(store.limitMegabytes == 64)
        #expect(store.limitBytes == 64 * 1_048_576)
        let reopened = ReadingCacheStore(cachesDirectory: caches, defaults: defaults)
        #expect(reopened.limitMegabytes == 64)
        #expect(reopened.limitBytes == 64 * 1_048_576)
    }

    private func makeStore(byteLimit: Int64) -> ReadingCacheStore {
        ReadingCacheStore(cachesDirectory: caches, defaults: UserDefaults(suiteName: defaultsName)!, byteLimit: byteLimit)
    }

    @discardableResult
    private func makeFile(_ relativePath: String, bytes: Int, usedSecondsAgo: TimeInterval) throws -> URL {
        let url = caches.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        try setUsed(url, secondsAgo: usedSecondsAgo)
        return url
    }

    private func setUsed(_ url: URL, secondsAgo: TimeInterval) throws {
        var url = url
        var values = URLResourceValues()
        let date = Date(timeIntervalSinceNow: -secondsAgo)
        values.contentModificationDate = date
        values.contentAccessDate = date
        try url.setResourceValues(values)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
