import Combine
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
    private var doubleTapGesture: UITapGestureRecognizer?
    private var selectionDismissTapGesture: UITapGestureRecognizer?
    private var foliateTapGesture: UITapGestureRecognizer?
    private var foliatePagePanGesture: UIPanGestureRecognizer?
    private var foliateSelectionLongPressGesture: UILongPressGestureRecognizer?
    private var lastFoliatePagePanTranslation = CGPoint.zero
    private var lockedPagingScrollViews: [(view: UIScrollView, wasEnabled: Bool)] = []

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
        }

        let selectionDismissTap = UITapGestureRecognizer(target: self, action: #selector(handleSelectionDismissTap(_:)))
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
        if isSelectionActive {
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
        } else {
            for (scrollView, wasEnabled) in lockedPagingScrollViews {
                scrollView.isScrollEnabled = wasEnabled
            }
            lockedPagingScrollViews.removeAll()
        }
    }

    @objc private func handleDoubleTapGesture(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, isDoubleTapEnabled else { return }
        let point = gesture.location(in: readerController.view)
        onDoubleTap?(point)
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
            return gestureRecognizer is UIPanGestureRecognizer
                || other is UIPanGestureRecognizer
        }
        if gestureRecognizer === selectionDismissTapGesture || other === selectionDismissTapGesture {
            if gestureRecognizer is UIPanGestureRecognizer || other is UIPanGestureRecognizer {
                return true
            }
            return false
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

    func makeUIViewController(context: Context) -> AnnotationResponderBridge {
        let bridge = AnnotationResponderBridge(adapter: adapter)
        bridge.onHighlight = onHighlight
        bridge.onAnnotate = onAnnotate
        bridge.onSelectionDismiss = onSelectionDismiss
        bridge.onDoubleTap = onDoubleTap
        bridge.isDoubleTapEnabled = isDoubleTapEnabled
        bridge.isScrollMode = isScrollMode
        bridge.isSelectionActive = isSelectionActive
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
final class PDFReaderController: UIViewController, UIGestureRecognizerDelegate {
    private let document: PDFKit.PDFDocument
    private let onPageChange: (Int) -> Void
    private let onTap: (CGPoint, CGSize) -> Void

    private var pdfView: PDFView!
    private var lastReportedIndex: Int
    private var isScrollEnabled: Bool
    private var suppressNotifications = false
    private var pendingInitialPageIndex: Int?
    private var pagePanStartIndex: Int?

    init(
        document: PDFKit.PDFDocument,
        initialPageIndex: Int,
        scrollEnabled: Bool,
        onPageChange: @escaping (Int) -> Void,
        onTap: @escaping (CGPoint, CGSize) -> Void
    ) {
        self.document = document
        self.lastReportedIndex = initialPageIndex
        self.isScrollEnabled = scrollEnabled
        self.onPageChange = onPageChange
        self.onTap = onTap
        super.init(nibName: nil, bundle: nil)
        buildPDFView(scrollEnabled: scrollEnabled, navigateToIndex: initialPageIndex)
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
    }

    func goToPage(_ index: Int) {
        let bounded = clampedIndex(index)
        guard let page = document.page(at: bounded) else { return }
        pdfView.go(to: page)
        lastReportedIndex = bounded
    }

    func currentPageIndex() -> Int {
        guard let page = pdfView.currentPage else { return lastReportedIndex }
        return document.index(for: page)
    }

    func setScrollEnabled(_ enabled: Bool) {
        let currentIndex = currentPageIndex()
        isScrollEnabled = enabled
        suppressNotifications = true
        NotificationCenter.default.removeObserver(self)
        pdfView.removeFromSuperview()
        buildPDFView(scrollEnabled: enabled, navigateToIndex: currentIndex)
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

    private func buildPDFView(scrollEnabled: Bool, navigateToIndex index: Int) {
        let pdf = PDFView()
        pdf.autoScales = true
        pdf.displaysPageBreaks = false
        if scrollEnabled {
            pdf.displayMode = .singlePageContinuous
            pdf.displayDirection = .vertical
            pdf.usePageViewController(false)
        } else {
            pdf.displayMode = .singlePage
            pdf.displayDirection = .horizontal
            pdf.usePageViewController(true, withViewOptions: nil)
        }
        pdf.document = document

        let bounded = clampedIndex(index)
        if let page = document.page(at: bounded) {
            pdf.go(to: page)
        }
        lastReportedIndex = bounded

        if scrollEnabled && bounded > 0 {
            pendingInitialPageIndex = bounded
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        pdf.addGestureRecognizer(tap)
        if !scrollEnabled {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePagePan(_:)))
            pan.cancelsTouchesInView = false
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            pdf.addGestureRecognizer(pan)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdf
        )

        self.pdfView = pdf
    }

    private func clampedIndex(_ index: Int) -> Int {
        min(max(0, index), max(document.pageCount - 1, 0))
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let v = gesture.view else { return }
        onTap(gesture.location(in: v), v.bounds.size)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        !isScrollEnabled || !(gestureRecognizer is UIPanGestureRecognizer)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        !isScrollEnabled
    }

    @objc private func handlePagePan(_ gesture: UIPanGestureRecognizer) {
        guard !isScrollEnabled else { return }
        switch gesture.state {
        case .began:
            pagePanStartIndex = currentPageIndex()
        case .ended:
            let translation = gesture.translation(in: pdfView)
            let velocity = gesture.velocity(in: pdfView)
            let horizontal = abs(translation.x) > abs(translation.y) * 1.2
            let crossedDistance = abs(translation.x) > 40
            let flicked = abs(velocity.x) > 350
            guard horizontal, crossedDistance || flicked else {
                pagePanStartIndex = nil
                return
            }
            let startIndex = pagePanStartIndex ?? currentPageIndex()
            let targetIndex = translation.x < 0 ? startIndex + 1 : startIndex - 1
            pagePanStartIndex = nil
            goToPage(targetIndex)
            onPageChange(currentPageIndex())
        case .cancelled, .failed:
            pagePanStartIndex = nil
        default:
            break
        }
    }

    @objc private func handlePageChanged(_ notification: Notification) {
        guard !suppressNotifications else { return }
        guard let page = pdfView.currentPage else { return }
        let index = document.index(for: page)
        guard index != lastReportedIndex else { return }
        lastReportedIndex = index
        onPageChange(index)
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

        init(onIncrease: @escaping () -> Void, onDecrease: @escaping () -> Void) {
            self.onIncrease = onIncrease
            self.onDecrease = onDecrease
            self.previousVolume = AVAudioSession.sharedInstance().outputVolume
            super.init()
            try? session.setActive(true)
            session.addObserver(self, forKeyPath: "outputVolume", options: [.new], context: nil)
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
            session.removeObserver(self, forKeyPath: "outputVolume")
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

struct ReaderKeyboardNavigationCapture: UIViewControllerRepresentable {
    let isRightToLeft: Bool
    let onForward: () -> Void
    let onBackward: () -> Void

    func makeUIViewController(context: Context) -> KeyboardCaptureController {
        let controller = KeyboardCaptureController()
        apply(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: KeyboardCaptureController, context: Context) {
        apply(to: controller)
    }

    static func dismantleUIViewController(_ controller: KeyboardCaptureController, coordinator: ()) {
        controller.tearDown()
    }

    private func apply(to controller: KeyboardCaptureController) {
        controller.isRightToLeft = isRightToLeft
        controller.onForward = onForward
        controller.onBackward = onBackward
    }

    final class KeyboardCaptureController: UIViewController {
        var isRightToLeft = false
        var onForward: () -> Void = {}
        var onBackward: () -> Void = {}
        private var editingObservers: [NSObjectProtocol] = []

        override var canBecomeFirstResponder: Bool { true }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false

            for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
                editingObservers.append(
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.viewIfLoaded?.window != nil else { return }
                            self.becomeFirstResponder()
                        }
                    }
                )
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            becomeFirstResponder()
        }

        func tearDown() {
            for observer in editingObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            editingObservers = []
        }

        override var keyCommands: [UIKeyCommand]? {
            let commands = [
                UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleLeftArrow)),
                UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleRightArrow)),
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleBackwardKey)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleForwardKey)),
                UIKeyCommand(input: " ", modifierFlags: [], action: #selector(handleForwardKey)),
                UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(handleForwardKey)),
                UIKeyCommand(input: UIKeyCommand.inputPageDown, modifierFlags: [], action: #selector(handleForwardKey)),
                UIKeyCommand(input: UIKeyCommand.inputPageUp, modifierFlags: [], action: #selector(handleBackwardKey)),
            ]
            for command in commands {
                command.wantsPriorityOverSystemBehavior = true
            }
            return commands
        }

        @objc private func handleLeftArrow() { isRightToLeft ? onForward() : onBackward() }
        @objc private func handleRightArrow() { isRightToLeft ? onBackward() : onForward() }
        @objc private func handleForwardKey() { onForward() }
        @objc private func handleBackwardKey() { onBackward() }
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
