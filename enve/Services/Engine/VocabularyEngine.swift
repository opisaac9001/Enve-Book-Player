import Foundation

struct VocabularySnapshot {
    let entries: [VocabEntry]
    let booksById: [String: Book]
}

@MainActor
@Observable
final class VocabularyEngine {
    private let appState: AppState

    init(appState: AppState = .shared) {
        self.appState = appState
    }

    func snapshot() async -> VocabularySnapshot {
        let entries = await appState.bookStore.allVocabEntries()
            .sorted { $0.lookedUpAt > $1.lookedUpAt }
        let bookIds = Set(entries.map(\.bookStableId))
        let books = await appState.bookStore.booksByStableIds(bookIds)
        return VocabularySnapshot(entries: entries, booksById: books)
    }

    func save(_ entry: VocabEntry) async {
        await appState.bookStore.upsertVocabEntry(entry)
    }

    func delete(_ entry: VocabEntry) async {
        await appState.bookStore.deleteVocabEntry(id: entry.id)
    }
}
