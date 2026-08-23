@preconcurrency import CarPlay
import Foundation
import UIKit

@MainActor
final class CarPlayDownloaded: CarPlayPage {
    private let interfaceController: CPInterfaceController
    private let environment: CarPlayEnvironment
    private weak var nowPlaying: CarPlayNowPlaying?
    private var isLoadingBook = false
    private var downloadIndexKeys: Set<String> = []
    private var downloadIndexBooks: [Book] = []

    let template: CPListTemplate

    init(interfaceController: CPInterfaceController, environment: CarPlayEnvironment, nowPlaying: CarPlayNowPlaying) {
        self.interfaceController = interfaceController
        self.environment = environment
        self.nowPlaying = nowPlaying

        template = CPListTemplate(title: "Downloaded", sections: [])
        template.tabTitle = "Downloaded"
        template.tabImage = UIImage(systemName: "arrow.down.circle.fill")
        template.emptyViewTitleVariants = ["No Downloads"]
        template.emptyViewSubtitleVariants = ["Download books in the app for offline listening"]
    }

    func willAppear() {
        reload()
    }

    func reload() {
        Task { @MainActor in
            let items = await buildBookItems()
            if items.isEmpty {
                template.updateSections([])
            } else {
                let section = CPListSection(items: items)
                template.updateSections([section])
            }
        }
    }

    @MainActor
    private func buildBookItems() async -> [CPListItem] {

        let downloadedIds = await environment.downloads.downloadedAudiobookIds()

        let candidateLimit = min(500, Int(CPListTemplate.maximumItemCount))
        let audiobooks = await downloadedAudiobookBooks(downloadedIds: downloadedIds)
        let readaloudEbooks = (await environment.catalog.downloadedEbooks(limit: candidateLimit))
            .filter { environment.playback.isReadaloudPlayable($0) }
        let downloadedBooks = (audiobooks + readaloudEbooks)
            .filter { environment.playback.isDownloaded($0, downloadedIds: downloadedIds) }

        guard !downloadedBooks.isEmpty else { return [] }

        let sorted = downloadedBooks.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        let capped = Array(sorted.prefix(Int(CPListTemplate.maximumItemCount)))

        return capped.map { book in
            let item = CPListItem(
                text: book.title,
                detailText: book.author
            )

            item.isPlaying = environment.playback.isCurrent(book)
            item.setCarPlayCover(for: book)

            item.handler = { [weak self] _, completion in
                self?.onBookSelected(book, completion: completion)
            }

            return item
        }
    }

    private func downloadedAudiobookBooks(downloadedIds: Set<String>) async -> [Book] {
        guard !downloadedIds.isEmpty else { return [] }
        if downloadedIds == downloadIndexKeys { return downloadIndexBooks }

        let all = await environment.catalog.allBooks()
        let recent = environment.progress.recentlyPlayed()
        let matched = await environment.downloads.downloadedAudiobooks(from: all + recent, downloadedIds: downloadedIds)

        downloadIndexKeys = downloadedIds
        downloadIndexBooks = matched
        return matched
    }

    private func onBookSelected(_ book: Book, completion: @escaping () -> Void) {
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
            reload()
        }
    }
}
