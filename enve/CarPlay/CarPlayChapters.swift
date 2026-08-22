@preconcurrency import CarPlay
import Foundation

@MainActor
final class CarPlayChapters {
    private let interfaceController: CPInterfaceController
    private let playback: any PlaybackControlling

    init(interfaceController: CPInterfaceController, playback: any PlaybackControlling) {
        self.interfaceController = interfaceController
        self.playback = playback
    }

    func show(_ chapters: [Chapter]) {
        guard !chapters.isEmpty else { return }

        let currentTime = playback.snapshot.position
        let currentIndex =
            chapters.firstIndex(where: {
                currentTime >= $0.start && currentTime < $0.end
            }) ?? 0

        let capped = chapters.enumerated().prefix(Int(CPListTemplate.maximumItemCount))

        let items = capped.map { offset, chapter -> CPListItem in
            let chapterNumber = offset + 1
            return createListItem(for: chapter, number: chapterNumber, isCurrent: offset == currentIndex)
        }

        let section = CPListSection(items: items)
        let listTemplate = CPListTemplate(title: "Chapters", sections: [section])
        interfaceController.pushTemplate(listTemplate, animated: true, completion: nil)
    }

    private func createListItem(for chapter: Chapter, number: Int, isCurrent: Bool) -> CPListItem {
        let durationText = formatDuration(chapter.duration)
        let title = "\(number). \(chapter.title)"

        let item = CPListItem(
            text: title,
            detailText: durationText
        )

        item.isPlaying = isCurrent

        item.handler = { [weak self] _, completion in
            self?.onChapterSelected(chapter)
            completion()
        }

        return item
    }

    private func onChapterSelected(_ chapter: Chapter) {
        playback.seek(to: chapter.start)
        interfaceController.popTemplate(animated: true, completion: nil)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
