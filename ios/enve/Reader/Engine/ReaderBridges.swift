import Combine
import GameController
import Logging
import MediaPlayer
import PDFKit
@preconcurrency import ReadiumAdapterGCDWebServer
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

struct EbookReaderInitialSelection: Equatable {
    let chapterID: String
    let chapterIndex: Int
    let chapterTitle: String
    let locatorJSON: String?
}

struct ClassicTOCEntry: Identifiable, Equatable {
    let id: String
    let link: ReadiumShared.Link?
    let depth: Int
    let displayTitle: String
    let href: String

    init(id: String, link: ReadiumShared.Link, depth: Int, displayTitle: String) {
        self.id = id
        self.link = link
        self.depth = depth
        self.displayTitle = displayTitle
        self.href = link.href
    }

    init(id: String, displayTitle: String, href: String, level: Int) {
        self.id = id
        self.link = nil
        self.depth = level
        self.displayTitle = displayTitle
        self.href = href
    }
}

final class AnnotationResponderBridge: UIViewController {
    let adapter: any ReaderEngineAdapter
    private var readerController: UIViewController { adapter.viewController }
    var onHighlight: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onSelectionDismiss: (() -> Void)?
    var onDoubleTap: ((CGPoint) -> Void)?
    var isDoubleTapEnabled: Bool = false
    var isScrollMode: Bool = false
    var isSelectionActive: Bool = false {
        didSet {
            guard isSelectionActive != oldValue else { return }
            updatePaginationLock()
        }
    }
    var isPinchResizeEnabled = false
    var onPinchResize: ((ReaderPinchResizeEvent) -> Void)?
    private var isPinchResizing = false {
        didSet {
            guard isPinchResizing != oldValue else { return }
            updatePaginationLock()
        }
    }
    private var pinchGesture: UIPinchGestureRecognizer?
    private var doubleTapGesture: UITapGestureRecognizer?
    private var selectionDismissTapGesture: UITapGestureRecognizer?
    private var foliateTapGesture: UITapGestureRecognizer?
    private var foliatePagePanGesture: UIPanGestureRecognizer?
    private var foliateSelectionLongPressGesture: UILongPressGestureRecognizer?
    private var lastFoliatePagePanTranslation = CGPoint.zero
    private var lockedPagingScrollViews: [(view: UIScrollView, wasEnabled: Bool)] = []
    private var selectionPageHolds: [SelectionPageHold] = []

    init(adapter: any ReaderEngineAdapter) {
        self.adapter = adapter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        if let oldParent = readerController.parent, oldParent !== self {
            readerController.willMove(toParent: nil)
            readerController.view.removeFromSuperview()
            readerController.removeFromParent()
        }
        if readerController.parent !== self {
            addChild(readerController)
        }
        readerController.view.frame = view.bounds
        readerController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if readerController.view.superview !== view {
            view.addSubview(readerController.view)
        }
        readerController.didMove(toParent: self)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTapGesture(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        view.addGestureRecognizer(doubleTap)
        self.doubleTapGesture = doubleTap

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchGesture(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
        pinchGesture = pinch

        if adapter.kind == .foliate {
            let foliateTap = UITapGestureRecognizer(
                target: self,
                action: #selector(handleFoliateTapGesture(_:))
            )
            foliateTap.cancelsTouchesInView = false
            foliateTap.delegate = self
            foliateTap.require(toFail: doubleTap)
            view.addGestureRecognizer(foliateTap)
            foliateTapGesture = foliateTap

            let pagePan = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleFoliatePagePanGesture(_:))
            )
            pagePan.cancelsTouchesInView = false
            pagePan.maximumNumberOfTouches = 1
            pagePan.delegate = self
            view.addGestureRecognizer(pagePan)
            foliatePagePanGesture = pagePan

            let selectionLongPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleFoliateSelectionLongPressGesture(_:))
            )
            selectionLongPress.minimumPressDuration = 0.35
            selectionLongPress.cancelsTouchesInView = false
            selectionLongPress.delegate = self
            view.addGestureRecognizer(selectionLongPress)
            foliateSelectionLongPressGesture = selectionLongPress
            pagePan.require(toFail: selectionLongPress)
            foliateTap.require(toFail: selectionLongPress)
        }

        let selectionDismissTap = UITapGestureRecognizer(target: self, action: #selector(handleSelectionDismissTap(_:)))
        selectionDismissTap.cancelsTouchesInView = false
        selectionDismissTap.delegate = self
        selectionDismissTap.require(toFail: doubleTap)
        view.addGestureRecognizer(selectionDismissTap)
        self.selectionDismissTapGesture = selectionDismissTap

        for gr in readerController.view.gestureRecognizers ?? [] {
            if let singleTap = gr as? UITapGestureRecognizer, singleTap.numberOfTapsRequired == 1 {
                singleTap.require(toFail: doubleTap)
            }
        }
    }

    private func updatePaginationLock() {
        guard isSelectionActive || isPinchResizing else {
            selectionPageHolds.removeAll()
            for (scrollView, wasEnabled) in lockedPagingScrollViews {
                scrollView.isScrollEnabled = wasEnabled
            }
            lockedPagingScrollViews.removeAll()
            return
        }
        if lockedPagingScrollViews.isEmpty {
            var pagingScrollViews: [UIScrollView] = []
            func walk(_ view: UIView) {
                if let scrollView = view as? UIScrollView,
                    scrollView.contentSize.width > scrollView.bounds.width + 1,
                    scrollView.contentSize.height <= scrollView.bounds.height + 1
                {
                    pagingScrollViews.append(scrollView)
                }
                for child in view.subviews {
                    walk(child)
                }
            }
            walk(readerController.view)
            lockedPagingScrollViews = pagingScrollViews.map { ($0, $0.isScrollEnabled) }
            for (scrollView, _) in lockedPagingScrollViews {
                scrollView.isScrollEnabled = false
            }
        }
        if !isSelectionActive {
            selectionPageHolds.removeAll()
        } else if selectionPageHolds.isEmpty {
            selectionPageHolds = lockedPagingScrollViews.map { SelectionPageHold(scrollView: $0.view) }
        }
    }

    @objc private func handleDoubleTapGesture(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, isDoubleTapEnabled else { return }
        let point = gesture.location(in: readerController.view)
        onDoubleTap?(point)
    }

    @objc private func handlePinchGesture(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            isPinchResizing = true
            onPinchResize?(.began)
        case .changed:
            onPinchResize?(.changed(scale: Double(gesture.scale)))
        case .ended:
            isPinchResizing = false
            onPinchResize?(.ended(scale: Double(gesture.scale)))
        case .cancelled, .failed:
            isPinchResizing = false
            onPinchResize?(.cancelled)
        default:
            break
        }
    }

    @objc private func handleFoliateTapGesture(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, !isSelectionActive else { return }
        let point = gesture.location(in: readerController.view)
        adapter.onTap?(point, readerController.view.bounds.size)
    }

    @objc private func handleFoliatePagePanGesture(_ gesture: UIPanGestureRecognizer) {
        guard !isScrollMode,
            !isSelectionActive,
            let foliateAdapter = adapter as? FoliateReaderEngineAdapter
        else {
            return
        }
        let translation = gesture.translation(in: readerController.view)
        switch gesture.state {
        case .began:
            lastFoliatePagePanTranslation = .zero
        case .changed:
            let delta = CGPoint(
                x: translation.x - lastFoliatePagePanTranslation.x,
                y: translation.y - lastFoliatePagePanTranslation.y
            )
            lastFoliatePagePanTranslation = translation
            foliateAdapter.updateInteractivePageDrag(
                delta: CGPoint(x: -delta.x, y: -delta.y)
            )
        case .ended, .cancelled:
            let delta = CGPoint(
                x: translation.x - lastFoliatePagePanTranslation.x,
                y: translation.y - lastFoliatePagePanTranslation.y
            )
            foliateAdapter.updateInteractivePageDrag(
                delta: CGPoint(x: -delta.x, y: -delta.y)
            )
            let velocity = gesture.velocity(in: readerController.view)
            foliateAdapter.endInteractivePageDrag(
                velocity: CGPoint(x: -velocity.x / 1000, y: -velocity.y / 1000)
            )
            lastFoliatePagePanTranslation = .zero
        default:
            break
        }
    }

    @objc private func handleFoliateSelectionLongPressGesture(
        _ gesture: UILongPressGestureRecognizer
    ) {
        guard gesture.state == .ended,
            let foliateAdapter = adapter as? FoliateReaderEngineAdapter
        else {
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(75))
            _ = await foliateAdapter.refreshSelection()
        }
    }

    @objc private func handleSelectionDismissTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, isSelectionActive else { return }
        onSelectionDismiss?()
    }

    @objc func highlightSelection(_ sender: Any?) {
        onHighlight?()
    }

    @objc func annotateSelection(_ sender: Any?) {
        onAnnotate?()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(highlightSelection(_:)) || action == #selector(annotateSelection(_:)) {
            return adapter.currentSelection != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

extension AnnotationResponderBridge: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === doubleTapGesture {
            return isDoubleTapEnabled
        }
        if gestureRecognizer === pinchGesture {
            return isPinchResizeEnabled && !isSelectionActive
        }
        if gestureRecognizer === foliateTapGesture {
            return !isSelectionActive
        }
        if gestureRecognizer === foliatePagePanGesture {
            guard !isScrollMode,
                !isSelectionActive,
                let pan = gestureRecognizer as? UIPanGestureRecognizer
            else {
                return false
            }
            let velocity = pan.velocity(in: readerController.view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }
        if gestureRecognizer === foliateSelectionLongPressGesture {
            return adapter.kind == .foliate
        }
        if gestureRecognizer === selectionDismissTapGesture {
            return isSelectionActive
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === doubleTapGesture || other === doubleTapGesture {
            let peer = gestureRecognizer === doubleTapGesture ? other : gestureRecognizer
            // From iOS 27, Foliate's WebKit tap recognizers end before this one and would otherwise fail it.
            return peer is UIPanGestureRecognizer
                || (adapter.kind == .foliate && peer is UITapGestureRecognizer && peer.view !== view)
        }
        if gestureRecognizer === selectionDismissTapGesture || other === selectionDismissTapGesture {
            // WebKit also handles taps that collapse its native selection. Keep the
            // annotation snapshot in sync instead of letting its recognizer win alone.
            return true
        }
        return true
    }
}

struct ReaderEngineControllerBridge: UIViewControllerRepresentable {
    let adapter: any ReaderEngineAdapter
    let onHighlight: () -> Void
    let onAnnotate: () -> Void
    let onSelectionDismiss: () -> Void
    var onDoubleTap: ((CGPoint) -> Void)?
    var isDoubleTapEnabled: Bool = false
    var isScrollMode: Bool = false
    var isSelectionActive: Bool = false
    var isPinchResizeEnabled: Bool = false
    var onPinchResize: ((ReaderPinchResizeEvent) -> Void)?

    func makeUIViewController(context: Context) -> AnnotationResponderBridge {
        let bridge = AnnotationResponderBridge(adapter: adapter)
        bridge.onHighlight = onHighlight
        bridge.onAnnotate = onAnnotate
        bridge.onSelectionDismiss = onSelectionDismiss
        bridge.onDoubleTap = onDoubleTap
        bridge.isDoubleTapEnabled = isDoubleTapEnabled
        bridge.isScrollMode = isScrollMode
        bridge.isSelectionActive = isSelectionActive
        bridge.isPinchResizeEnabled = isPinchResizeEnabled
        bridge.onPinchResize = onPinchResize
        return bridge
    }

    func updateUIViewController(_ vc: AnnotationResponderBridge, context: Context) {
        vc.onHighlight = onHighlight
        vc.onAnnotate = onAnnotate
        vc.onSelectionDismiss = onSelectionDismiss
        vc.onDoubleTap = onDoubleTap
        vc.isDoubleTapEnabled = isDoubleTapEnabled
        vc.isScrollMode = isScrollMode
        vc.isSelectionActive = isSelectionActive
        vc.isPinchResizeEnabled = isPinchResizeEnabled
        vc.onPinchResize = onPinchResize
    }
}

struct HTMLReaderBridge: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct PDFReaderBridge: UIViewControllerRepresentable {
    let controller: PDFReaderController

    func makeUIViewController(context: Context) -> PDFReaderController { controller }
    func updateUIViewController(_ vc: PDFReaderController, context: Context) {}
}

@MainActor
final class PDFReaderController: UIViewController {
    private let document: PDFKit.PDFDocument
    private let onPageChange: (Int) -> Void
    private let onTap: (CGPoint, CGSize) -> Void

    private var pdfView: PDFView!
    private var lastReportedIndex: Int
    private var suppressNotifications = false
    private var pendingInitialPageIndex: Int?
    private var scrollEnabled: Bool
    private var layout: PDFReadingLayout
    private var fittedViewport = CGSize.zero
    private var fittedSpread: ClosedRange<Int>?

    init(
        document: PDFKit.PDFDocument,
        initialPageIndex: Int,
        scrollEnabled: Bool,
        layout: PDFReadingLayout,
        onPageChange: @escaping (Int) -> Void,
        onTap: @escaping (CGPoint, CGSize) -> Void
    ) {
        self.document = document
        self.lastReportedIndex = initialPageIndex
        self.scrollEnabled = scrollEnabled
        self.layout = layout
        self.onPageChange = onPageChange
        self.onTap = onTap
        super.init(nibName: nil, bundle: nil)
        buildPDFView(navigateToIndex: initialPageIndex)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let index = pendingInitialPageIndex {
            pendingInitialPageIndex = nil
            suppressNotifications = true
            if let page = document.page(at: index) {
                pdfView.go(to: page)
            }
            lastReportedIndex = index
            suppressNotifications = false
        }
        fitPagesIfNeeded()
    }

    func goToPage(_ index: Int) {
        let bounded = clampedIndex(index)
        guard let page = document.page(at: bounded) else { return }
        let wasSuppressing = suppressNotifications
        suppressNotifications = true
        defer { suppressNotifications = wasSuppressing }
        pdfView.go(to: page)
        lastReportedIndex = bounded
        if viewIfLoaded?.window == nil { pendingInitialPageIndex = bounded }
        fitPagesIfNeeded()
    }

    // Wide pages reserve horizontal swipes for panning.
    var allowsSwipePageTurns: Bool {
        let spread = spread(containing: lastReportedIndex)
        let content = ReaderPagedPagePolicy.pdfSpreadSize(pageSizes: spread.map(displayedSize(ofPageAt:)))
        return content.width * pdfView.scaleFactor <= pdfView.bounds.width + 1
    }

    // PDFKit may report the spread partner; keep the requested page as the selection.
    func currentPageIndex() -> Int {
        if let pendingInitialPageIndex { return pendingInitialPageIndex }
        guard let page = pdfView.currentPage else { return lastReportedIndex }
        let index = document.index(for: page)
        return spread(containing: index).contains(lastReportedIndex) ? lastReportedIndex : index
    }

    func configure(scrollEnabled: Bool, layout: PDFReadingLayout) {
        guard scrollEnabled != self.scrollEnabled || layout != self.layout else { return }
        var pairing = layout
        pairing.pageAdjust = self.layout.pageAdjust
        if scrollEnabled == self.scrollEnabled, pairing == self.layout {
            self.layout = layout
            fittedViewport = .zero
            fitPagesIfNeeded()
            return
        }
        let currentIndex = currentPageIndex()
        self.scrollEnabled = scrollEnabled
        self.layout = layout
        suppressNotifications = true
        NotificationCenter.default.removeObserver(self)
        pdfView.removeFromSuperview()
        buildPDFView(navigateToIndex: currentIndex)
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        suppressNotifications = false
    }

    private func buildPDFView(navigateToIndex index: Int) {
        let pdf = PDFView()
        pdf.autoScales = false
        pdf.displaysPageBreaks = false
        // Paged turns are handled by the reader's drag gesture.
        pdf.usePageViewController(false)
        if scrollEnabled {
            pdf.displayMode = layout.twoPageEnabled ? .twoUpContinuous : .singlePageContinuous
            pdf.displayDirection = .vertical
        } else {
            pdf.displayMode = layout.twoPageEnabled ? .twoUp : .singlePage
            pdf.displayDirection = .horizontal
        }
        pdf.displaysAsBook = layout.twoPageEnabled && layout.showsCoverSeparately
        pdf.document = document

        let bounded = clampedIndex(index)
        if let page = document.page(at: bounded) {
            pdf.go(to: page)
        }
        lastReportedIndex = bounded
        pendingInitialPageIndex = bounded > 0 ? bounded : nil

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        pdf.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdf
        )

        self.pdfView = pdf
        fittedViewport = .zero
        fittedSpread = nil
    }

    private func fitPagesIfNeeded() {
        let viewport = pdfView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        // PDFKit updates `currentPage` lazily after `go(to:)`, so the fit follows the controller's own selection.
        let index = pendingInitialPageIndex ?? lastReportedIndex
        let spread = spread(containing: index)
        // Scrolled flow keeps the reader's zoom while pages pass; only paged turns reset it.
        guard viewport != fittedViewport || (!scrollEnabled && spread != fittedSpread) else { return }
        let content = ReaderPagedPagePolicy.pdfSpreadSize(pageSizes: spread.map(displayedSize(ofPageAt:)))
        guard let scale = layout.pageAdjust.scale(fitting: content, in: viewport) else { return }
        fittedViewport = viewport
        fittedSpread = spread

        let wasSuppressing = suppressNotifications
        suppressNotifications = true
        defer { suppressNotifications = wasSuppressing }
        // PDFKit resets zoom while settling navigation, so apply the scale after layout.
        pdfView.layoutIfNeeded()
        // Widen the range first because each bound clamps the current scale.
        pdfView.minScaleFactor = min(pdfView.minScaleFactor, scale)
        pdfView.maxScaleFactor = scale * PDFPageAdjust.maximumZoom
        pdfView.minScaleFactor = scale
        pdfView.scaleFactor = scale
        pdfView.layoutIfNeeded()
        centerOverflowingContent()
    }

    private func displayedSize(ofPageAt index: Int) -> CGSize {
        guard let page = document.page(at: index) else { return .zero }
        let bounds = page.bounds(for: pdfView.displayBox)
        let quarterTurns = (page.rotation / 90) % 2
        return quarterTurns == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
    }

    // Cropped and filled pages open on their middle, matching the Android viewport.
    private func centerOverflowingContent() {
        guard let scrollView = pdfScrollView else { return }
        let inset = scrollView.adjustedContentInset
        let size = scrollView.bounds.size
        var offset = scrollView.contentOffset
        let overflowX = scrollView.contentSize.width + inset.left + inset.right - size.width
        if overflowX > 1 {
            offset.x = overflowX / 2 - inset.left
        }
        let overflowY = scrollView.contentSize.height + inset.top + inset.bottom - size.height
        if !scrollEnabled, overflowY > 1 {
            offset.y = overflowY / 2 - inset.top
        }
        scrollView.setContentOffset(offset, animated: false)
    }

    // PDFKit hosts its pages in a scroll view it does not expose.
    private var pdfScrollView: UIScrollView? {
        var queue = pdfView.subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scrollView = view as? UIScrollView { return scrollView }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func clampedIndex(_ index: Int) -> Int {
        min(max(0, index), max(document.pageCount - 1, 0))
    }

    private func spread(containing index: Int) -> ClosedRange<Int> {
        ReaderPagedPagePolicy.pdfSpread(containing: index, pageCount: document.pageCount, layout: layout)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let v = gesture.view else { return }
        onTap(gesture.location(in: v), v.bounds.size)
    }

    @objc private func handlePageChanged(_ notification: Notification) {
        guard !suppressNotifications else { return }
        guard let page = pdfView.currentPage else { return }
        let index = document.index(for: page)
        guard !spread(containing: index).contains(lastReportedIndex) else { return }
        lastReportedIndex = index
        onPageChange(index)
        fitPagesIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

struct VolumeButtonNavigationCapture: UIViewRepresentable {
    let isEnabled: Bool
    let onIncrease: () -> Void
    let onDecrease: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onIncrease: onIncrease, onDecrease: onDecrease)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        view.addSubview(volumeView)
        context.coordinator.attach(volumeView: volumeView)
        context.coordinator.setEnabled(isEnabled)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.setEnabled(isEnabled)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject {
        nonisolated(unsafe) private let onIncrease: () -> Void
        nonisolated(unsafe) private let onDecrease: () -> Void
        private let session = AVAudioSession.sharedInstance()
        nonisolated(unsafe) private var previousVolume: Float
        private weak var slider: UISlider?
        nonisolated(unsafe) private var enabled = false
        nonisolated(unsafe) private var isResetting = false
        private var isObservingVolume = false
        private var isStopped = false

        init(onIncrease: @escaping () -> Void, onDecrease: @escaping () -> Void) {
            self.onIncrease = onIncrease
            self.onDecrease = onDecrease
            self.previousVolume = AVAudioSession.sharedInstance().outputVolume
            super.init()
            // Volume KVO only delivers on an active session, so register once activation has been attempted.
            AudioSessionQueue.perform {
                try AVAudioSession.sharedInstance().setActive(true)
            } completion: { [weak self] failure in
                guard let self, !self.isStopped else { return }
                if let failure {
                    AppLogger.library.error("Volume button capture could not activate the audio session: \(failure)")
                }
                self.session.addObserver(self, forKeyPath: "outputVolume", options: [.new], context: nil)
                self.isObservingVolume = true
                self.previousVolume = self.session.outputVolume
            }
        }

        func attach(volumeView: MPVolumeView) {
            slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
            resetVolumeIfNeeded()
        }

        func setEnabled(_ enabled: Bool) {
            self.enabled = enabled
            previousVolume = session.outputVolume
            if enabled {
                resetVolumeIfNeeded()
            }
        }

        func stop() {
            isStopped = true
            guard isObservingVolume else { return }
            session.removeObserver(self, forKeyPath: "outputVolume")
            isObservingVolume = false
        }

        nonisolated override func observeValue(
            forKeyPath keyPath: String?,
            of object: Any?,
            change: [NSKeyValueChangeKey: Any]?,
            context: UnsafeMutableRawPointer?
        ) {
            guard keyPath == "outputVolume", enabled, !isResetting else { return }
            let newVolume = session.outputVolume
            defer { previousVolume = newVolume }
            guard abs(newVolume - previousVolume) > 0.0001 else { return }
            if newVolume > previousVolume {
                Task { @MainActor in self.onIncrease() }
            } else {
                Task { @MainActor in self.onDecrease() }
            }
            Task { @MainActor in self.resetVolumeIfNeeded() }
        }

        private func resetVolumeIfNeeded() {
            guard let slider else { return }
            isResetting = true
            slider.value = 0.5
            slider.sendActions(for: .touchUpInside)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.previousVolume = self.session.outputVolume
                self.isResetting = false
            }
        }
    }
}

enum ReaderHardwarePageTurn: Equatable {
    case forward, backward
    // Left and right follow the page progression; forward and backward never flip.
    case left, right

    func isForward(rightToLeft: Bool) -> Bool {
        switch self {
        case .forward: true
        case .backward: false
        case .left: rightToLeft
        case .right: !rightToLeft
        }
    }
}

enum ReaderGamepadPageTurnButton: CaseIterable {
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger, dpadLeft, dpadRight

    var turn: ReaderHardwarePageTurn {
        switch self {
        case .rightShoulder, .rightTrigger: .forward
        case .leftShoulder, .leftTrigger: .backward
        case .dpadLeft: .left
        case .dpadRight: .right
        }
    }

    func input(on gamepad: GCExtendedGamepad) -> GCControllerButtonInput {
        switch self {
        case .leftShoulder: gamepad.leftShoulder
        case .rightShoulder: gamepad.rightShoulder
        case .leftTrigger: gamepad.leftTrigger
        case .rightTrigger: gamepad.rightTrigger
        case .dpadLeft: gamepad.dpad.left
        case .dpadRight: gamepad.dpad.right
        }
    }
}

enum ReaderHardwarePageTurnPolicy {
    struct KeyBinding {
        let input: String
        let turn: ReaderHardwarePageTurn
    }

    // Page turners in keyboard mode send these keys; volume-mode turners stay with the volume buttons setting.
    static let keyBindings = [
        KeyBinding(input: UIKeyCommand.inputLeftArrow, turn: .left),
        KeyBinding(input: UIKeyCommand.inputRightArrow, turn: .right),
        KeyBinding(input: UIKeyCommand.inputUpArrow, turn: .backward),
        KeyBinding(input: UIKeyCommand.inputDownArrow, turn: .forward),
        KeyBinding(input: " ", turn: .forward),
        KeyBinding(input: "\r", turn: .forward),
        KeyBinding(input: UIKeyCommand.inputPageDown, turn: .forward),
        KeyBinding(input: UIKeyCommand.inputPageUp, turn: .backward),
        KeyBinding(input: UIKeyCommand.f1, turn: .backward),
        KeyBinding(input: UIKeyCommand.f2, turn: .forward),
    ]

    static func turn(forKeyInput input: String?) -> ReaderHardwarePageTurn? {
        keyBindings.first { $0.input == input }?.turn
    }

    // The same keys by HID usage, for presses UIKit hands on without matching a command.
    static func turn(forKeyCode keyCode: UIKeyboardHIDUsage) -> ReaderHardwarePageTurn? {
        switch keyCode {
        case .keyboardLeftArrow: .left
        case .keyboardRightArrow: .right
        case .keyboardUpArrow, .keyboardPageUp, .keyboardF1: .backward
        case .keyboardDownArrow, .keyboardPageDown, .keyboardF2, .keyboardSpacebar, .keyboardReturnOrEnter: .forward
        default: nil
        }
    }

    static func acceptsInput(isEnabled: Bool, isSceneActive: Bool, isCoveredByPresentation: Bool, isEditingText: Bool) -> Bool {
        isEnabled && isSceneActive && !isCoveredByPresentation && !isEditingText
    }

    // A gamepad is not tied to a window, so the reader focused last takes its presses.
    static func gamepadTarget(focusedAt focusDates: [Date?]) -> Int? {
        focusDates.enumerated()
            .compactMap { offset, date in date.map { (offset, $0) } }
            .max { $0.1 < $1.1 }?
            .0
    }
}

// Controller handlers are app-wide; one relay prevents reader windows from overwriting each other.
@MainActor
final class ReaderGamepadPageTurnRelay {
    static let shared = ReaderGamepadPageTurnRelay()

    private let captures = NSHashTable<ReaderHardwareNavigationCapture.HardwareCaptureController>.weakObjects()
    private var boundButtons: [GCControllerButtonInput] = []
    private var connectionObservers: [NSObjectProtocol] = []

    private init() {}

    func register(_ capture: ReaderHardwareNavigationCapture.HardwareCaptureController) {
        captures.add(capture)
        if connectionObservers.isEmpty {
            for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
                connectionObservers.append(
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                        MainActor.assumeIsolated { ReaderGamepadPageTurnRelay.shared.bindControllers() }
                    }
                )
            }
        }
        bindControllers()
    }

    func unregister(_ capture: ReaderHardwareNavigationCapture.HardwareCaptureController) {
        captures.remove(capture)
        bindControllers()
    }

    private func bindControllers() {
        for button in boundButtons {
            button.pressedChangedHandler = nil
        }
        boundButtons = []
        guard captures.count > 0 else {
            for observer in connectionObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            connectionObservers = []
            return
        }
        for controller in GCController.controllers() {
            guard let gamepad = controller.extendedGamepad else { continue }
            // The handlers assume the main queue; background events stay off, the framework default.
            controller.handlerQueue = .main
            for button in ReaderGamepadPageTurnButton.allCases {
                let input = button.input(on: gamepad)
                input.pressedChangedHandler = { @Sendable _, _, pressed in
                    guard pressed else { return }
                    MainActor.assumeIsolated { ReaderGamepadPageTurnRelay.shared.deliver(button) }
                }
                boundButtons.append(input)
            }
        }
    }

    private func deliver(_ button: ReaderGamepadPageTurnButton) {
        let candidates = captures.allObjects
        guard let target = ReaderHardwarePageTurnPolicy.gamepadTarget(
            focusedAt: candidates.map { $0.acceptsGamepadInput ? $0.focusedAt : nil }
        ) else { return }
        candidates[target].turn(button.turn)
    }
}

struct ReaderHardwareNavigationCapture: UIViewControllerRepresentable {
    let isRightToLeft: Bool
    let keyboardEnabled: Bool
    let gameControllersEnabled: Bool
    let onForward: () -> Void
    let onBackward: () -> Void

    func makeUIViewController(context: Context) -> HardwareCaptureController {
        let controller = HardwareCaptureController()
        apply(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: HardwareCaptureController, context: Context) {
        apply(to: controller)
    }

    static func dismantleUIViewController(_ controller: HardwareCaptureController, coordinator: ()) {
        controller.tearDown()
    }

    private func apply(to controller: HardwareCaptureController) {
        controller.isRightToLeft = isRightToLeft
        controller.keyboardEnabled = keyboardEnabled
        controller.gameControllersEnabled = gameControllersEnabled
        controller.onForward = onForward
        controller.onBackward = onBackward
        controller.resumeNavigation()
    }

    final class HardwareCaptureController: UIViewController {
        var isRightToLeft = false
        var keyboardEnabled = true
        var gameControllersEnabled = true
        var onForward: () -> Void = {}
        var onBackward: () -> Void = {}
        private(set) var focusedAt: Date?
        private var observers: [NSObjectProtocol] = []
        private var lastKeyTurn: (source: KeySource, at: Date)?

        private enum KeySource { case keyCommand, press }

        // One stable list: UIKit may read `keyCommands` before this responder is first responder.
        private static let pageKeyCommands = ReaderHardwarePageTurnPolicy.keyBindings.map { binding in
            let command = UIKeyCommand(
                input: binding.input, modifierFlags: [], action: #selector(HardwareCaptureController.handleKeyCommand(_:))
            )
            command.wantsPriorityOverSystemBehavior = true
            return command
        }

        override var canBecomeFirstResponder: Bool { true }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false

            let focusChanges: [(Notification.Name, ownSenderOnly: Bool)] = [
                (UITextField.textDidEndEditingNotification, false),
                (UITextView.textDidEndEditingNotification, false),
                (UIScene.didActivateNotification, true),
                (UIWindow.didBecomeKeyNotification, true),
            ]
            for (name, ownSenderOnly) in focusChanges {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                        // Only the identity crosses into the actor; the sender itself is not Sendable.
                        let sender = ownSenderOnly ? (notification.object as AnyObject?).map(ObjectIdentifier.init) : nil
                        MainActor.assumeIsolated {
                            self?.resumeNavigation(from: sender)
                        }
                    }
                )
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            resumeNavigation()
            ReaderGamepadPageTurnRelay.shared.register(self)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            ReaderGamepadPageTurnRelay.shared.unregister(self)
        }

        // PDFKit and WebKit can take focus on a tap without restoring the reader responder.
        func resumeNavigation() {
            resumeNavigation(from: nil)
        }

        private func resumeNavigation(from sender: ObjectIdentifier?) {
            guard let window = viewIfLoaded?.window else { return }
            // Another window's or scene's focus change is not ours to answer.
            if let sender, sender != ObjectIdentifier(window), sender != window.windowScene.map(ObjectIdentifier.init) {
                return
            }
            if isCoveredByPresentation {
                // Sheet dismissal may not send an appearance callback to the presenting reader.
                transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.resumeNavigation()
                }
                return
            }
            // Ending one field can mean another field is taking keyboard focus.
            guard !Self.isEditingText(in: window) else { return }
            if (becomeFirstResponder() || isFirstResponder), window.isKeyWindow {
                focusedAt = Date()
            }
        }

        private static func isEditingText(in window: UIWindow) -> Bool {
            (window.windowScene?.windows ?? [window]).contains { hasFocusedTextInput(in: $0) }
        }

        // PDFKit selection adopts UITextInput without accepting typing.
        private static func hasFocusedTextInput(in view: UIView) -> Bool {
            if view.isFirstResponder, view is any UITextInput {
                if let textView = view as? UITextView { return textView.isEditable }
                return !isInsidePDFView(view)
            }
            return view.subviews.contains { hasFocusedTextInput(in: $0) }
        }

        private static func isInsidePDFView(_ view: UIView) -> Bool {
            sequence(first: view, next: \.superview).contains { $0 is PDFView }
        }

        private var isCoveredByPresentation: Bool {
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            return root.presentedViewController != nil
        }

        private func acceptsInput(isEnabled: Bool) -> Bool {
            guard let window = viewIfLoaded?.window else { return false }
            return ReaderHardwarePageTurnPolicy.acceptsInput(
                isEnabled: isEnabled,
                isSceneActive: window.windowScene?.activationState == .foregroundActive,
                isCoveredByPresentation: isCoveredByPresentation,
                isEditingText: Self.isEditingText(in: window)
            )
        }

        var acceptsGamepadInput: Bool {
            acceptsInput(isEnabled: gameControllersEnabled)
        }

        var acceptsKeyboardInput: Bool {
            acceptsInput(isEnabled: keyboardEnabled)
        }

        func tearDown() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
            ReaderGamepadPageTurnRelay.shared.unregister(self)
        }

        override var keyCommands: [UIKeyCommand]? {
            keyboardEnabled ? Self.pageKeyCommands : nil
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(handleKeyCommand(_:)) { return acceptsKeyboardInput }
            return super.canPerformAction(action, withSender: sender)
        }

        @objc private func handleKeyCommand(_ command: UIKeyCommand) {
            guard acceptsKeyboardInput, let turn = ReaderHardwarePageTurnPolicy.turn(forKeyInput: command.input) else { return }
            deliver(turn, from: .keyCommand)
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var unhandled = Set<UIPress>()
            for press in presses {
                if acceptsKeyboardInput, let key = press.key,
                    key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty,
                    let turn = ReaderHardwarePageTurnPolicy.turn(forKeyCode: key.keyCode)
                {
                    deliver(turn, from: .press)
                } else {
                    unhandled.insert(press)
                }
            }
            if !unhandled.isEmpty {
                super.pressesBegan(unhandled, with: event)
            }
        }

        // Should a press ever reach both paths, the second arrival within a frame is the same key.
        private func deliver(_ turn: ReaderHardwarePageTurn, from source: KeySource) {
            if let last = lastKeyTurn, last.source != source, Date().timeIntervalSince(last.at) < 0.05 { return }
            lastKeyTurn = (source, Date())
            self.turn(turn)
        }

        func turn(_ turn: ReaderHardwarePageTurn) {
            turn.isForward(rightToLeft: isRightToLeft) ? onForward() : onBackward()
        }
    }
}

extension SwiftUI.Color {
    init?(legacyHexString: String) {
        let cleaned = legacyHexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
            return nil
        }
        self.init(hex: value)
    }
}

extension UIColor {
    convenience init?(legacyHexString: String) {
        let cleaned = legacyHexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
            return nil
        }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    convenience init?(hexString: String) {
        var cleaned = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if cleaned.count == 8 {
            guard let value = UInt64(cleaned, radix: 16) else { return nil }
            self.init(
                red: CGFloat((value >> 24) & 0xFF) / 255,
                green: CGFloat((value >> 16) & 0xFF) / 255,
                blue: CGFloat((value >> 8) & 0xFF) / 255,
                alpha: CGFloat(value & 0xFF) / 255
            )
            return
        }
        if cleaned.count == 3 {
            cleaned = cleaned.map { "\($0)\($0)" }.joined()
        }
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension DateFormatter {
    static let bookloreFallback: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()
}

// WebKit auto-scrolls a paginated web view while a selection handle nears the page edge, which strands
// the reader between pages. The hold snaps each nudge back; a sustained push turns exactly one page.
@MainActor
private final class SelectionPageHold {
    private static let nudgeGap: TimeInterval = 0.25
    private static let turnDwell: TimeInterval = 0.5

    private let scrollView: UIScrollView
    private var heldX: CGFloat
    private var observation: NSKeyValueObservation?
    private var isRestoring = false
    private var isArmed = false
    private var nudgeStart = Date.distantPast
    private var lastNudge = Date.distantPast

    init(scrollView: UIScrollView) {
        self.scrollView = scrollView
        let width = max(scrollView.bounds.width, 1)
        heldX = (scrollView.contentOffset.x / width).rounded() * width
        observation = scrollView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.offsetChanged() }
        }
    }

    private func offsetChanged() {
        guard !isRestoring, abs(scrollView.contentOffset.x - heldX) > 0.5 else { return }
        let now = Date()
        let forward = scrollView.contentOffset.x > heldX
        if now.timeIntervalSince(lastNudge) > Self.nudgeGap {
            nudgeStart = now
            isArmed = true
        }
        lastNudge = now
        if isArmed, now.timeIntervalSince(nudgeStart) >= Self.turnDwell {
            let width = scrollView.bounds.width
            let maxX = max(0, scrollView.contentSize.width - width)
            heldX = min(max(0, heldX + (forward ? width : -width)), maxX)
            isArmed = false
        }
        isRestoring = true
        scrollView.contentOffset.x = heldX
        isRestoring = false
    }
}

