import CoreMedia
import CoreVideo
import Foundation
import Logging
@preconcurrency import ReadiumNavigator
import UIKit
import WebKit

enum ReaderCompanionLayoutPolicy {
    // A receiver only counts as a television canvas once it is meaningfully wider than tall.
    static let wideAspectThreshold: Double = 1.2
    static let maximumCanvasAspectRatio: Double = 2.4
    static let canvasHeight: CGFloat = 540

    static func columnCount(forAspectRatio aspectRatio: Double) -> ReadiumNavigator.ColumnCount? {
        aspectRatio > wideAspectThreshold ? .two : nil
    }

    static func canvasSize(forAspectRatio aspectRatio: Double) -> CGSize? {
        guard aspectRatio > wideAspectThreshold else { return nil }
        let aspect = min(aspectRatio, maximumCanvasAspectRatio)
        return CGSize(width: (canvasHeight * aspect).rounded(), height: canvasHeight)
    }

    static func broadcastTotalPages(_ totalPages: Int) -> Int {
        max(1, totalPages)
    }

    static func pageIndex(progress: Double?, totalPages: Int) -> Int {
        max(0, Int((progress ?? 0) * Double(broadcastTotalPages(totalPages))))
    }
}

@MainActor
protocol ReaderCompanionHosting: AnyObject {
    var companionIsFixedLayoutBook: Bool { get }
    var companionHasMediaOverlay: Bool { get }
    var companionScrollEnabled: Bool { get }
    var companionOverlayPlayer: MediaOverlayPlayer? { get }
    var companionProgress: Double? { get }
    var companionTotalPages: Int { get }
    var companionChapterTitle: String? { get }
    var companionPageSourceViewController: UIViewController? { get }
    var companionHighlightSourceViewController: UIViewController? { get }
    func companionDidChange()
    func companionPageForward() async
    func companionPageBackward() async
    func companionToggleReadAloud()
    func companionReapplyReflowableLayout(onLayoutSettled: @escaping @MainActor () async -> Void)
}

@MainActor
final class ReaderCompanionController {
    weak var host: (any ReaderCompanionHosting)?

    private let session = ReaderCompanionSnapshot()
    private let book: Book

    init(book: Book) {
        self.book = book
        session.onChange = { [weak self] in
            self?.host?.companionDidChange()
        }
    }

    deinit {
        Task { @MainActor in
            if CompanionBroadcasterService.shared.isBroadcasting {
                await CompanionBroadcasterService.shared.stop(reason: .userClosedReader)
            }
        }
    }

    var isActive: Bool { session.isActive }

    var columnOverride: ReadiumNavigator.ColumnCount? { session.columnOverride }

    private var isFixedLayoutBook: Bool { host?.companionIsFixedLayoutBook ?? false }
    private var overlayPlayer: MediaOverlayPlayer? { host?.companionOverlayPlayer }
    private var totalPages: Int { host?.companionTotalPages ?? 0 }
    private var progress: Double? { host?.companionProgress }
    private var chapterTitle: String? { host?.companionChapterTitle }

    var castingCanvasSize: CGSize? {
        guard session.isActive,
            let host,
            !host.companionIsFixedLayoutBook,
            !host.companionScrollEnabled,
            let viewport = CompanionBroadcasterService.shared.receiverViewport
        else { return nil }
        return ReaderCompanionLayoutPolicy.canvasSize(forAspectRatio: viewport.aspectRatio)
    }

    func start() async {
        guard !session.isActive else { return }
        do {
            try await CompanionBroadcasterService.shared.start(
                bookTitle: book.title,
                bookStableId: book.stableId,
                hasMediaOverlay: host?.companionHasMediaOverlay ?? false
            )
            session.isActive = true

            CompanionBroadcasterService.shared.pageCommandHandler = { [weak self] direction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch direction {
                    case .next: await self.host?.companionPageForward()
                    case .previous: await self.host?.companionPageBackward()
                    }
                }
            }

            CompanionBroadcasterService.shared.viewportInfoHandler = { [weak self] viewport in
                Task { @MainActor [weak self] in
                    self?.applyViewport(viewport)
                }
            }

            CompanionBroadcasterService.shared.readAloudCommandHandler = { [weak self] action in
                Task { @MainActor [weak self] in
                    await self?.handleReadAloudCommand(action)
                }
            }

            CompanionBroadcasterService.shared.receiverConnectedHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.broadcastCurrentPageIfActive()
                    await self?.broadcastReadAloudState()
                }
            }

            await broadcastCurrentPageIfActive()
            await broadcastReadAloudState()

            if isFixedLayoutBook {
                await startVideoMirror()
            }
        } catch {
            AppLogger.network.warning("[Companion] Failed to start broadcasting: \(error.localizedDescription)")
        }
    }

    func stop() async {
        guard session.isActive else { return }
        CompanionBroadcasterService.shared.pageCommandHandler = nil
        CompanionBroadcasterService.shared.viewportInfoHandler = nil
        CompanionBroadcasterService.shared.readAloudCommandHandler = nil
        CompanionBroadcasterService.shared.receiverConnectedHandler = nil
        if let capture = session.screenCapture {
            capture.stop()
            session.screenCapture = nil
            session.videoStreamStarted = false
            await CompanionBroadcasterService.shared.stopVideoStream()
        }
        await CompanionBroadcasterService.shared.stop(reason: .userClosedReader)
        session.isActive = false

        if session.columnOverride != nil {
            session.columnOverride = nil
            reapplyLayout()
        }
    }

    func locationDidChange() {
        guard session.isActive else { return }
        Task { @MainActor [weak self] in
            await self?.broadcastCurrentPageIfActive()
        }
    }

    func readAloudStateDidChange() {
        guard session.isActive else { return }
        Task { @MainActor [weak self] in
            await self?.broadcastReadAloudState()
        }
    }

    private func broadcastReadAloudState() async {
        guard session.isActive else { return }
        await CompanionBroadcasterService.shared.sendMediaOverlayState(
            isPlaying: overlayPlayer?.isPlaying ?? false,
            speed: overlayPlayer?.playbackRate
        )
    }

    private func broadcastCurrentPageIfActive() async {
        guard session.isActive else { return }

        guard !CompanionBroadcasterService.shared.isVideoStreaming else { return }
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard session.isActive else {
            AppLogger.network.info("[Companion] broadcast skipped. Session ended")
            return
        }
        guard let readerController = host?.companionPageSourceViewController else {
            AppLogger.network.warning("[Companion] broadcast skipped. Navigator not ready")
            return
        }
        guard let image = await Self.renderSnapshot(of: readerController) else {
            AppLogger.network.warning("[Companion] broadcast skipped. Snapshot failed")
            return
        }

        let pageIndex = ReaderCompanionLayoutPolicy.pageIndex(progress: progress, totalPages: totalPages)
        AppLogger.network.info("[Companion] Sending page \(pageIndex) (\(Int(image.size.width))×\(Int(image.size.height)))")
        await CompanionBroadcasterService.shared.sendPage(
            image: image,
            pageIndex: pageIndex,
            totalPages: ReaderCompanionLayoutPolicy.broadcastTotalPages(totalPages),
            chapterTitle: chapterTitle
        )
    }

    func broadcastHighlightFrameIfActive() async {
        guard session.isActive else { return }

        guard !CompanionBroadcasterService.shared.isVideoStreaming else { return }
        guard session.shouldBroadcastHighlight() else { return }
        guard let navigatorController = host?.companionHighlightSourceViewController,
            let image = await Self.renderSnapshot(of: navigatorController)
        else { return }
        let pageIndex = ReaderCompanionLayoutPolicy.pageIndex(progress: progress, totalPages: totalPages)
        await CompanionBroadcasterService.shared.sendPage(
            image: image,
            pageIndex: pageIndex,
            totalPages: ReaderCompanionLayoutPolicy.broadcastTotalPages(totalPages),
            chapterTitle: chapterTitle
        )
    }

    private func startVideoMirror() async {
        let capture = CompanionScreenCapture()
        session.screenCapture = capture
        session.videoStreamStarted = false
        capture.onVideoFrame = { [weak self] pixelBuffer, pts in
            guard let self else { return }
            if !self.session.videoStreamStarted {
                self.session.videoStreamStarted = true
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                Task { @MainActor in
                    await CompanionBroadcasterService.shared.startVideoStream(width: width, height: height)
                    CompanionBroadcasterService.shared.encodeVideoFrame(pixelBuffer, presentationTime: pts)
                }
            } else {
                CompanionBroadcasterService.shared.encodeVideoFrame(pixelBuffer, presentationTime: pts)
            }
        }
        let started = await capture.start()
        if !started {
            AppLogger.network.warning("[Companion] video mirror unavailable. Falling back to snapshots")
            session.screenCapture = nil
        }
    }

    private func handleReadAloudCommand(_ action: ReadAloudCommandPayload.Action) async {
        guard let player = overlayPlayer else { return }
        switch action {
        case .togglePlay:
            host?.companionToggleReadAloud()
        case .nextClip:
            player.next()
        case .previousClip:
            player.previous()
        case .cycleSpeed:
            let speeds = ReaderCompanionSnapshot.readAloudSpeeds
            let current = player.playbackRate
            let idx = speeds.firstIndex(where: { abs($0 - current) < 0.01 }) ?? speeds.firstIndex(of: 1.0) ?? 0
            let next = speeds[(idx + 1) % speeds.count]
            player.setSpeed(next)
        }
        await broadcastReadAloudState()
    }

    private func applyViewport(_ viewport: ViewportInfoPayload) {
        guard !isFixedLayoutBook else { return }
        let desired = ReaderCompanionLayoutPolicy.columnCount(forAspectRatio: viewport.aspectRatio)
        guard session.columnOverride != desired else { return }
        session.columnOverride = desired
        reapplyLayout()
    }

    private func reapplyLayout() {
        host?.companionReapplyReflowableLayout { [weak self] in
            await self?.broadcastCurrentPageIfActive()
        }
    }

    private static func renderSnapshot(of navigator: UIViewController) async -> UIImage? {
        let view = navigator.view!
        guard view.bounds.width > 0 && view.bounds.height > 0 else { return nil }
        if let webView = firstWebView(in: view), webView.bounds.width > 0 {
            if let image = try? await webView.takeSnapshot(configuration: nil) {
                return image
            }
        }
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        return renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
    }

    private static func firstWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = firstWebView(in: subview) { return found }
        }
        return nil
    }
}
