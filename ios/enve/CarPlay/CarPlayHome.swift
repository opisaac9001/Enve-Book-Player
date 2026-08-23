@preconcurrency import CarPlay
import Combine
import Foundation
import UIKit

@MainActor
final class CarPlayHome: CarPlayPage {
    private let interfaceController: CPInterfaceController
    private let environment: CarPlayEnvironment
    private weak var nowPlaying: CarPlayNowPlaying?
    private var isLoadingBook = false
    private var cancellable: AnyCancellable?

    let template: CPListTemplate

    init(interfaceController: CPInterfaceController, environment: CarPlayEnvironment, nowPlaying: CarPlayNowPlaying) {
        self.interfaceController = interfaceController
        self.environment = environment
        self.nowPlaying = nowPlaying

        template = CPListTemplate(title: "Continue Listening", sections: [])
        template.tabTitle = "Continue"
        template.tabImage = UIImage(systemName: "play.circle.fill")
        template.emptyViewTitleVariants = ["Nothing to Resume"]
        template.emptyViewSubtitleVariants = ["Start a book in Enve and it will appear here"]

        cancellable = environment.controller.snapshots
            .map { $0.currentBook?.uniqueId }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
    }

    func willAppear() {
        reload()
    }

    func reload() {
        Task { @MainActor in
            let sections = await buildSections()
            template.updateSections(sections)
        }
    }

    @MainActor
    private func buildSections() async -> [CPListSection] {
        var sections: [CPListSection] = []

        let continueListening = await environment.catalog.continueListeningBooks(limit: 50)

        if !continueListening.isEmpty {

            var lastUpdated: [String: TimeInterval] = [:]
            for book in continueListening {
                lastUpdated[book.stableId] = environment.progress.lastProgressUpdate(stableId: book.stableId)
            }
            let sorted = CarPlayCatalog.continueListeningOrder(continueListening, lastUpdated: lastUpdated)

            let downloadedIds = await environment.downloads.downloadedAudiobookIds()

            let limited = Array(sorted.prefix(50))
            let items = limited.map { createBookItem(for: $0, downloadedIds: downloadedIds) }
            let section = CPListSection(items: items, header: "Continue Listening", sectionIndexTitle: nil)
            sections.append(section)
        }

        return sections
    }

    private func createBookItem(for book: Book, downloadedIds: Set<String>) -> CPListItem {
        let item = CPListItem(
            text: book.title,
            detailText: book.author
        )

        item.isPlaying = environment.playback.isCurrent(book)
        item.setCarPlayCover(for: book)
        item.applyDownloadStateBadge(isDownloaded: environment.playback.isDownloaded(book, downloadedIds: downloadedIds))

        item.handler = { [weak self] _, completion in
            self?.onBookSelected(book, completion: completion)
        }

        return item
    }

    private func onBookSelected(_ book: Book, completion: @escaping () -> Void) {
        if environment.playback.isCurrent(book) {
            nowPlaying?.showNowPlaying()
            completion()
            return
        }
        guard !isLoadingBook else { completion(); return }
        isLoadingBook = true

        let playback = environment.playback
        Task { [weak self] in
            let started = await playback.play(book)
            guard let self else { completion(); return }
            isLoadingBook = false
            if started {
                nowPlaying?.showNowPlaying()
            }
            completion()
            reload()
        }
    }
}
