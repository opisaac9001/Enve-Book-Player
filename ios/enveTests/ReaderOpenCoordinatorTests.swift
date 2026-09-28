import Foundation
import Testing

@testable import enve

@MainActor
struct ReaderOpenCoordinatorTests {
    @Test func openingAStaleCopyKeepsTheStoredPositionAndTimestamp() async {
        let savedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let stored = Book(
            id: "reader-open-stale-copy-\(UUID().uuidString)",
            title: "Stale Copy",
            source: .local,
            mediaType: .ebook,
            epubLocator: #"{"href":"chapter1.xhtml","locations":{"fragments":["sentence260"],"totalProgression":0.113}}"#,
            ebookProgress: 0.113,
            lastUpdate: savedAt
        )
        var staleCopy = stored
        staleCopy.epubLocator = #"{"href":"chapter1.xhtml","locations":{"fragments":["sentence206"],"totalProgression":0.105}}"#
        staleCopy.ebookProgress = 0.105
        staleCopy.lastUpdate = savedAt.addingTimeInterval(-600)

        let appState = AppState.shared
        appState.hotCache.insert(stored)
        defer { appState.hotCache.remove(uniqueId: stored.uniqueId) }

        var presented: Book?
        let coordinator = ReaderOpenCoordinator(present: { presented = $0 })
        coordinator.open(staleCopy)
        for _ in 0..<1000 where presented == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(presented?.epubLocator == stored.epubLocator)
        #expect(presented?.lastUpdate == savedAt)
        let current = appState.bookInMemory(uniqueId: stored.uniqueId)
        #expect(current?.epubLocator == stored.epubLocator)
        #expect(current?.lastUpdate == savedAt)
    }
}
