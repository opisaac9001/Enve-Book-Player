#if os(iOS)
import Combine
import UIKit
import WidgetKit

@MainActor
final class BookWidgetBridge {
    static let shared = BookWidgetBridge()

    private var cancellables = Set<AnyCancellable>()
    private var lastSnapshot: BookWidgetSnapshot?
    private var lastArtworkID: String?
    private var pendingArtworkID: String?
    private var hasStarted = false
    private let playback: any PlaybackControlling

    private init(playback: any PlaybackControlling = ActivePlayback.controller) {
        self.playback = playback
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, _, _, _, _ in
                Task { @MainActor in BookWidgetBridge.shared.handleCommand() }
            },
            BookWidgetShared.darwinCommandName as CFString,
            nil,
            .deliverImmediately
        )

        playback.snapshots
        .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] _ in self?.publish() }
        .store(in: &cancellables)

        publish()
    }

    private func handleCommand() {
        guard let command = BookWidgetShared.takeCommand() else { return }
        switch command {
        case "toggle": PlayerViewModel.shared.togglePlay()
        case "tts.toggle": NowPlayingCoordinator.shared.toggleActivePlayback()
        case "backward": PlayerViewModel.shared.skipBackward()
        case "forward": PlayerViewModel.shared.skipForward()
        default: break
        }
    }

    private func publish() {
        let playback = playback.snapshot
        let book = playback.currentBook ?? PlayerViewModel.shared.currentBook
        let elapsed = playback.duration > 0 ? playback.position : PlayerViewModel.shared.progress
        let duration = playback.duration > 0 ? playback.duration : (book?.duration ?? PlayerViewModel.shared.duration)
        let chapter = book?.chapters?.last { elapsed >= $0.start && elapsed < $0.end }?.title ?? ""
        let preferences = PlayerViewModel.shared.preferences
        let snapshot = BookWidgetSnapshot(
            id: book?.stableId ?? "",
            title: book?.title ?? "",
            author: book?.author ?? "Unknown Author",
            chapter: chapter,
            isPlaying: playback.isPlaying,
            hasBook: book != nil,
            elapsed: elapsed,
            duration: duration,
            skipBackward: Int(preferences.skipBackwardAmount),
            skipForward: Int(preferences.skipForwardAmount)
        )

        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        BookWidgetShared.saveSnapshot(snapshot)
        publishArtwork(for: book)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func publishArtwork(for book: Book?) {
        guard let destination = BookWidgetShared.artworkFileURL else { return }
        guard let book, let coverURL = book.coverURL else {
            lastArtworkID = nil
            pendingArtworkID = nil
            try? FileManager.default.removeItem(at: destination)
            return
        }
        let artworkID = book.stableId
        guard artworkID != lastArtworkID, artworkID != pendingArtworkID else { return }
        pendingArtworkID = artworkID

        Task(priority: .utility) {
            defer { pendingArtworkID = nil }
            let image: UIImage?
            if let cached = await DiskImageCache.shared.image(for: coverURL) {
                image = cached
            } else if coverURL.isFileURL {
                image = UIImage(contentsOfFile: coverURL.path)
            } else if let data = try? await URLSession.shared.data(from: coverURL).0 {
                image = UIImage(data: data)
            } else {
                image = nil
            }

            guard let image else { return }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let canvas = CGSize(width: 360, height: 540)
            let scale = max(canvas.width / image.size.width, canvas.height / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let drawRect = CGRect(
                x: (canvas.width - drawSize.width) / 2,
                y: (canvas.height - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            let resized = UIGraphicsImageRenderer(
                size: canvas,
                format: format
            ).image { _ in
                image.draw(in: drawRect)
            }
            try? resized.jpegData(compressionQuality: 0.86)?.write(to: destination, options: .atomic)
            lastArtworkID = artworkID
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
#endif
