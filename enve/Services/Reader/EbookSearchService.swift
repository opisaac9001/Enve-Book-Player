import Combine
import Foundation
import Logging
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared

struct EbookSearchResult: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let locator: Locator
    let locatorJSON: String?
    let chapterTitle: String?
    let contextBefore: String
    let contextAfter: String

    init(
        text: String,
        locator: Locator,
        locatorJSON: String? = nil,
        chapterTitle: String?,
        contextBefore: String,
        contextAfter: String
    ) {
        self.text = text
        self.locator = locator
        self.locatorJSON = locatorJSON
        self.chapterTitle = chapterTitle
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }

    static func == (lhs: EbookSearchResult, rhs: EbookSearchResult) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
@Observable
final class EbookSearchService {
    var results: [EbookSearchResult] = []
    var isSearching = false
    var currentIndex: Int = 0
    var query: String = ""

    @ObservationIgnored private var searchIterator: SearchIterator?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    func search(in publication: Publication, query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        self.query = trimmed
        guard !trimmed.isEmpty else {
            results = []
            currentIndex = 0
            isSearching = false
            return
        }

        results = []
        currentIndex = 0
        isSearching = true

        searchTask = Task {
            defer {
                if self.query == trimmed {
                    self.isSearching = false
                }
            }
            do {
                guard let service = publication.findService(SearchService.self) else {
                    return
                }

                let iterator = try await service.search(query: trimmed, options: nil).get()
                self.searchIterator = iterator

                while !Task.isCancelled {
                    let collection = try await iterator.next().get()
                    guard let collection else { break }
                    let newResults = collection.locators.map { locator in
                        EbookSearchResult(
                            text: locator.text.highlight ?? trimmed,
                            locator: locator,
                            chapterTitle: locator.title,
                            contextBefore: locator.text.before ?? "",
                            contextAfter: locator.text.after ?? ""
                        )
                    }
                    results.append(contentsOf: newResults)
                }
            } catch {
                if !Task.isCancelled {
                    AppLogger.network.error("Search failed: \(error)")
                }
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    func nextResult() {
        guard !results.isEmpty else { return }
        currentIndex = (currentIndex + 1) % results.count
    }

    func previousResult() {
        guard !results.isEmpty else { return }
        currentIndex = (currentIndex - 1 + results.count) % results.count
    }

    var currentResult: EbookSearchResult? {
        guard !results.isEmpty, currentIndex < results.count else { return nil }
        return results[currentIndex]
    }
}
