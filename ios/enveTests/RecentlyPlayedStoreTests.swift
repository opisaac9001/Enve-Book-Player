import Foundation
import Testing

@testable import enve

@MainActor
struct RecentlyPlayedStoreTests {
    @Test func writesStayInTheInjectedProfileDefaults() throws {
        let owner = try Suite()
        let child = try Suite()
        defer { owner.remove(); child.remove() }
        let standardBefore = UserDefaults.standard.data(forKey: "recentlyPlayedBooks")
        let book = Book(id: "shared", title: "Child's book", source: .audiobookshelf)

        BookProgressStore(defaults: child.defaults).saveRecentlyPlayed(book, date: Date(timeIntervalSince1970: 100))

        #expect(BookProgressStore(defaults: child.defaults).loadSnapshots().map(\.stableId) == [book.stableId])
        #expect(BookProgressStore(defaults: owner.defaults).loadSnapshots().isEmpty)
        #expect(UserDefaults.standard.data(forKey: "recentlyPlayedBooks") == standardBefore)
    }

    @Test func interleavedSavesAndRemovalsAreNotLost() async throws {
        let suite = try Suite()
        defer { suite.remove() }
        let store = BookProgressStore(defaults: suite.defaults)
        let books = (0..<20).map { Book(id: "book-\($0)", title: "Book \($0)", source: .audiobookshelf) }

        await withTaskGroup(of: Void.self) { group in
            for (index, book) in books.enumerated() {
                group.addTask { @MainActor in
                    store.saveRecentlyPlayed(book, date: Date(timeIntervalSince1970: Double(index)))
                    if index.isMultiple(of: 4) { store.remove(stableId: book.stableId) }
                }
            }
        }

        let expected = Set(books.enumerated().filter { !$0.offset.isMultiple(of: 4) }.map(\.element.stableId))
        #expect(Set(store.loadSnapshots().map(\.stableId)) == expected)
        #expect(Set(BookProgressStore(defaults: suite.defaults).loadSnapshots().map(\.stableId)) == expected)
    }

    @Test func newestSaveLeadsAndTheListStaysCapped() throws {
        let suite = try Suite()
        defer { suite.remove() }
        let store = BookProgressStore(defaults: suite.defaults)
        for index in 0..<55 {
            store.saveRecentlyPlayed(Book(id: "book-\(index)", title: "Book \(index)", source: .audiobookshelf), date: .now)
        }
        let replayed = Book(id: "book-10", title: "Book 10", source: .audiobookshelf)
        store.saveRecentlyPlayed(replayed, date: .now)

        let snapshots = BookProgressStore(defaults: suite.defaults).loadSnapshots()
        #expect(snapshots.count == 50)
        #expect(snapshots.first?.stableId == replayed.stableId)
        #expect(snapshots.filter { $0.stableId == replayed.stableId }.count == 1)
    }

    private struct Suite {
        let name = "recently-played-\(UUID().uuidString)"
        let defaults: UserDefaults
        init() throws { defaults = try #require(UserDefaults(suiteName: name)) }
        func remove() { defaults.removePersistentDomain(forName: name) }
    }
}
