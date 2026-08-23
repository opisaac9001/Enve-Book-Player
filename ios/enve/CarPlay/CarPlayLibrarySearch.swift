@preconcurrency import CarPlay
import Foundation
import UIKit

@MainActor
final class CarPlayLibrarySearch: CarPlayPage {
    private let interfaceController: CPInterfaceController
    private let environment: CarPlayEnvironment
    private weak var nowPlaying: CarPlayNowPlaying?
    private var isLoadingBook = false

    let template: CPListTemplate

    init(interfaceController: CPInterfaceController, environment: CarPlayEnvironment, nowPlaying: CarPlayNowPlaying) {
        self.interfaceController = interfaceController
        self.environment = environment
        self.nowPlaying = nowPlaying

        template = CPListTemplate(title: "All Books", sections: [])
        template.tabTitle = "All Books"
        template.tabImage = UIImage(systemName: "magnifyingglass")
        template.emptyViewTitleVariants = ["No Books"]
        template.emptyViewSubtitleVariants = ["Add sources in Enve to see your library"]
    }

    func willAppear() {
        reload()
    }

    func reload() {
        Task { @MainActor in
            template.updateSections(await buildSections())
        }
    }

    @MainActor
    private func buildSections() async -> [CPListSection] {
        let maxTotalItems = min(200, Int(CPListTemplate.maximumItemCount))
        let audiobooks = (await environment.catalog.pagedBooks(offset: 0, limit: maxTotalItems, mediaType: "audiobook"))
            .filter { ($0.duration ?? 0) > 0 || environment.playback.isReadaloudPlayable($0) }
        let readaloudEbooks = (await environment.catalog.recentEbooks(limit: maxTotalItems))
            .filter { environment.playback.isReadaloudPlayable($0) }
        let allBooks = Array(Dictionary(grouping: audiobooks + readaloudEbooks, by: \.uniqueId).compactMap { $0.value.first })
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let downloadedIds = await environment.downloads.downloadedAudiobookIds()

        let groups = CarPlayCatalog.alphabeticalGroups(
            allBooks,
            maxSections: Int(CPListTemplate.maximumSectionCount),
            maxItems: maxTotalItems
        )

        return groups.map { group in
            let items = group.books.map { book -> CPListItem in
                let item = CPListItem(text: book.title, detailText: book.author)
                item.isPlaying = environment.playback.isCurrent(book)
                item.applyDownloadStateBadge(isDownloaded: environment.playback.isDownloaded(book, downloadedIds: downloadedIds))
                item.handler = { [weak self] _, completion in
                    self?.playBook(book, completion: completion)
                }
                return item
            }
            return CPListSection(items: items, header: group.letter, sectionIndexTitle: group.letter)
        }
    }

    private func playBook(_ book: Book, completion: @escaping () -> Void) {
        if environment.playback.isCurrent(book) {
            nowPlaying?.showNowPlaying()
            completion()
            return
        }
        guard !isLoadingBook else { completion(); return }
        isLoadingBook = true

        Task {
            let started = await environment.playback.play(book)
            isLoadingBook = false
            if started {
                nowPlaying?.showNowPlaying()
            }
            completion()
        }
    }
}
