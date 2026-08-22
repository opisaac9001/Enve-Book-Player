import Foundation
@preconcurrency import ReadiumShared

@MainActor
final class ReaderSearchModel {
    let searchService = EbookSearchService()

    func search(in publication: Publication?, query: String) {
        guard let publication else { return }
        searchService.search(in: publication, query: query)
    }
}
