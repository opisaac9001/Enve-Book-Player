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
    private unowned let profileSession: ProfileSession?
    private var artworkTask: Task<Void, Never>?
    private var isRevoked = false
    private let playback: any PlaybackControlling

    init(playback: any PlaybackControlling = ActivePlayback.controller, profileSession: ProfileSession? = nil) {
        self.profileSession = profileSession
        self.playback = playback
    }

    func start() {
        guard !hasStarted else { return }
        isRevoked = false
        hasStarted = true

        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let bridge = Unmanaged<BookWidgetBridge>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in bridge.handleCommand() }
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

    func revoke() {
        hasStarted = false
        isRevoked = true
        cancellables.removeAll()
        artworkTask?.cancel()
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), nil, nil)
        lastSnapshot = nil
        lastArtworkID = nil
        pendingArtworkID = nil
        Self.clearSharedSnapshot()
    }

    static func clearSharedSnapshot() {
        BookWidgetShared.saveSnapshot(BookWidgetSnapshot(id: "", title: "", author: "", chapter: "", isPlaying: false,
            hasBook: false, elapsed: 0, duration: 0, skipBackward: 30, skipForward: 30))
        if let artwork = BookWidgetShared.artworkFileURL { try? FileManager.default.removeItem(at: artwork) }
        _ = BookWidgetShared.takeCommand()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func retire() async {
        revoke()
        await artworkTask?.value
    }

    private func handleCommand() {
        guard !isRevoked, let command = BookWidgetShared.takeCommand() else { return }
        switch command {
        case "toggle": (profileSession?.playback.player ?? PlayerViewModel.shared).togglePlay()
        case "tts.toggle": NowPlayingCoordinator.shared.toggleActivePlayback()
        case "backward": (profileSession?.playback.player ?? PlayerViewModel.shared).skipBackward()
        case "forward": (profileSession?.playback.player ?? PlayerViewModel.shared).skipForward()
        default: break
        }
    }

    private func publish() {
        guard !isRevoked else { return }
        let playback = playback.snapshot
        let book = playback.currentBook ?? (profileSession?.playback.player ?? PlayerViewModel.shared).currentBook
        let elapsed = playback.duration > 0 ? playback.position : (profileSession?.playback.player ?? PlayerViewModel.shared).progress
        let duration = playback.duration > 0 ? playback.duration : (book?.duration ?? (profileSession?.playback.player ?? PlayerViewModel.shared).duration)
        let chapter = book?.chapters?.last { elapsed >= $0.start && elapsed < $0.end }?.title ?? ""
        let preferences = (profileSession?.playback.player ?? PlayerViewModel.shared).preferences
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

        artworkTask?.cancel()
        artworkTask = Task(priority: .utility) { [self] in
            defer { pendingArtworkID = nil }
            let image: UIImage?
            if let cached = await (profileSession?.imageCache ?? DiskImageCache.shared).image(for: coverURL) {
                image = cached
            } else if coverURL.isFileURL {
                image = UIImage(contentsOfFile: coverURL.path)
            } else if let data = try? await (profileSession?.networkSession ?? URLSession.shared).data(from: coverURL).0 {
                image = UIImage(data: data)
            } else {
                image = nil
            }

            guard !Task.isCancelled, !isRevoked, let image else { return }
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
