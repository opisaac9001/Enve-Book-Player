@preconcurrency import CarPlay
import Combine
import Foundation
import Logging
import UIKit

@MainActor
final class CarPlayNowPlaying {
    private let interfaceController: CPInterfaceController
    private let controller: any PlaybackControlling
    private let nowPlaying: any PlaybackNowPlayingUpdating
    private let playback: CarPlayPlaybackService
    private let conflictResolver: (any PlaybackConflictResolving)?
    private var chapters: CarPlayChapters
    private var cancellables = Set<AnyCancellable>()
    private var isConnected = true

    let template: CPNowPlayingTemplate

    init(interfaceController: CPInterfaceController, environment: CarPlayEnvironment) {
        self.interfaceController = interfaceController
        self.controller = environment.controller
        self.nowPlaying = environment.nowPlayingUpdater
        self.playback = environment.playback
        self.conflictResolver = environment.conflictResolver
        self.chapters = CarPlayChapters(interfaceController: interfaceController, playback: environment.controller)
        template = CPNowPlayingTemplate.shared
        if #available(iOS 18.4, *) {
            template.nowPlayingMode = .default
        }

        setupObservers()
        updateNowPlayingTemplate()
    }

    func invalidate() {
        isConnected = false
        cancellables.removeAll()
    }

    private var isPushingNowPlaying = false

    func showNowPlaying() {
        guard isConnected else { return }
        guard !interfaceController.templates.isEmpty else { return }

        guard !isPushingNowPlaying else { return }
        guard !interfaceController.templates.contains(where: { $0 is CPNowPlayingTemplate }) else { return }

        isPushingNowPlaying = true
        nowPlaying.refreshNowPlayingInfo()
        interfaceController.pushTemplate(template, animated: true) { [weak self] success, error in
            Task { @MainActor in self?.isPushingNowPlaying = false }
            if success {
                self?.nowPlaying.refreshNowPlayingInfo()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.nowPlaying.refreshNowPlayingInfo()
                }
            } else if let error {
                AppLogger.carplay.error("Failed to push Now Playing: \(error)")
            }
        }
    }

    private func setupObservers() {
        controller.snapshots
            .map { $0.currentBook?.uniqueId }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] bookID in
                guard let self = self else { return }

                if bookID == nil {
                    self.hideNowPlaying()
                }
                self.updateNowPlayingTemplate()
            }
            .store(in: &cancellables)

        controller.snapshots
            .map(\.isPlaying)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateNowPlayingTemplate()
            }
            .store(in: &cancellables)

        controller.snapshots
            .map(\.playbackSpeed)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateNowPlayingTemplate()
            }
            .store(in: &cancellables)

        conflictResolver?.conflicts
            .receive(on: RunLoop.main)
            .sink { [weak self] conflict in
                guard let conflict else { return }
                let useServer = conflict.server > conflict.local
                AppLogger.carplay.info("[CarPlay] Auto-resolving sync conflict: using \(useServer ? "server" : "local") time")
                self?.conflictResolver?.resolveConflict(useServer: useServer)
            }
            .store(in: &cancellables)

        controller.snapshots
            .map(\.errorDescription)
            .removeDuplicates()
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                self?.presentPlaybackError(message)
            }
            .store(in: &cancellables)
    }

    private func presentPlaybackError(_ message: String) {
        guard isConnected else { return }
        AppLogger.carplay.error("[CarPlay] Playback error: \(message)")

        let dismiss = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPAlertTemplate(titleVariants: [message], actions: [dismiss])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    private func updateNowPlayingTemplate() {
        let book = controller.snapshot.currentBook
        let resolvedChapters = book.map { playback.chapters(for: $0) } ?? []
        let hasChapters = !resolvedChapters.isEmpty

        let previousChapterButton = Self.makeButton(systemName: "backward.end.fill") { [weak self] in
            self?.seekChapter(offset: -1, chapters: resolvedChapters)
        }
        previousChapterButton.isEnabled = hasChapters

        let chaptersButton = Self.makeButton(systemName: "list.bullet") { [weak self] in
            self?.onChaptersTapped(chapters: resolvedChapters)
        }
        chaptersButton.isEnabled = hasChapters

        let playbackRateButton = Self.makeButton(systemName: "gauge.with.dots.needle.67percent") { [weak self] in
            self?.onPlaybackRateTapped()
        }

        let nextChapterButton = Self.makeButton(systemName: "forward.end.fill") { [weak self] in
            self?.seekChapter(offset: 1, chapters: resolvedChapters)
        }
        nextChapterButton.isEnabled = hasChapters

        template.updateNowPlayingButtons([
            previousChapterButton,
            chaptersButton,
            playbackRateButton,
            nextChapterButton,
        ])
    }

    private func seekChapter(offset: Int, chapters: [Chapter]) {
        guard !chapters.isEmpty else { return }
        let now = controller.snapshot.position
        let currentIndex =
            chapters.firstIndex { now >= $0.start && now < $0.end }
            ?? chapters.lastIndex { now >= $0.start }
            ?? 0
        let target = min(max(currentIndex + offset, 0), chapters.count - 1)
        controller.seek(to: chapters[target].start)
    }

    private static func makeButton(systemName: String, handler: @escaping @MainActor () -> Void) -> CPNowPlayingImageButton {
        let image = UIImage(systemName: systemName) ?? UIImage()
        return CPNowPlayingImageButton(image: image) { _ in
            handler()
        }
    }

    private func onPlaybackRateTapped() {
        AppLogger.carplay.info("[CarPlay] Playback rate button tapped")

        let speedValues: [Float] = [0.75] + (10...30).map { Float($0) / 10.0 }
        let speeds: [(speed: Float, label: String)] = speedValues.map { value in
            let label: String
            if abs(value - 1.0) < 0.01 {
                label = "1.0× (Normal)"
            } else {
                label = String(format: "%.2f×", value)
            }
            return (value, label)
        }

        let currentSpeed = Float(controller.snapshot.playbackSpeed)
        AppLogger.carplay.info("[CarPlay] Current speed: \(currentSpeed)x")

        let items = speeds.map { speed, label -> CPListItem in
            let isSelected = abs(speed - currentSpeed) < 0.01

            let item = CPListItem(text: label, detailText: nil)
            item.isPlaying = isSelected
            item.handler = { [weak self] _, completion in
                AppLogger.carplay.info("[CarPlay] Setting new speed: \(speed)x")
                self?.controller.setPlaybackRate(Double(speed))
                self?.interfaceController.popTemplate(animated: true, completion: nil)
                completion()
            }
            return item
        }

        let section = CPListSection(items: items)
        let listTemplate = CPListTemplate(title: "Playback Speed", sections: [section])
        interfaceController.pushTemplate(listTemplate, animated: true, completion: nil)
    }

    private func onChaptersTapped(chapters resolvedChapters: [Chapter]) {
        chapters.show(resolvedChapters)
    }

    private func hideNowPlaying() {
        guard isConnected else { return }
        guard interfaceController.templates.contains(where: { $0 is CPNowPlayingTemplate }) else { return }

        interfaceController.popToRootTemplate(animated: true) { success, error in
            if !success, let error {
                AppLogger.carplay.error("Failed to hide Now Playing: \(error)")
            }
        }
    }
}
