import Logging
import SwiftUI
import UIKit

private final class ComicPageLoadingOverlay: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let message = UILabel()
    private let retry = UIButton(type: .system)

    init(onRetry: @escaping () -> Void) {
        super.init(frame: .zero)
        let panel = UIStackView(arrangedSubviews: [spinner, message, retry])
        panel.axis = .vertical
        panel.alignment = .center
        panel.spacing = 12
        panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
        let palette = Hearth.palette(for: .dark)
        panel.backgroundColor = UIColor(palette.bgElevated)
        panel.layer.cornerRadius = 16
        panel.translatesAutoresizingMaskIntoConstraints = false
        message.textColor = UIColor(palette.text)
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.numberOfLines = 0
        message.textAlignment = .center
        spinner.color = UIColor(palette.textSecondary)
        retry.setTitle("Retry page", for: .normal)
        retry.setTitleColor(UIColor(Hearth.accent), for: .normal)
        retry.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        retry.titleLabel?.adjustsFontForContentSizeCategory = true
        retry.accessibilityIdentifier = "comic-page-retry"
        retry.addAction(UIAction { _ in onRetry() }, for: .touchUpInside)
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func install(in parent: UIView) {
        frame = parent.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.addSubview(self)
    }

    func showLoading() {
        isHidden = false
        message.text = "Loading page…"
        retry.isHidden = true
        spinner.startAnimating()
    }

    func showFailure() {
        isHidden = false
        message.text = "Couldn't load this page. Check your connection and try again."
        spinner.stopAnimating()
        retry.isHidden = false
    }

    func hide() {
        spinner.stopAnimating()
        isHidden = true
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !retry.isHidden && retry.bounds.contains(convert(point, to: retry))
    }
}

private enum ComicHorizontalEdge {
    case left
    case right
}

private struct ComicEdgePagingTracker {
    private var startedAtLeftEdge = false
    private var startedAtRightEdge = false

    mutating func begin(in scrollView: UIScrollView, contentWidth: CGFloat) {
        let minimumX = -scrollView.contentInset.left
        let maximumX = max(
            minimumX,
            contentWidth * scrollView.zoomScale - scrollView.bounds.width + scrollView.contentInset.right
        )
        let tolerance: CGFloat = 1
        startedAtLeftEdge = scrollView.contentOffset.x <= minimumX + tolerance
        startedAtRightEdge = scrollView.contentOffset.x >= maximumX - tolerance
    }

    mutating func end(in scrollView: UIScrollView) -> ComicHorizontalEdge? {
        defer {
            startedAtLeftEdge = false
            startedAtRightEdge = false
        }
        guard scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 else { return nil }
        let translation = scrollView.panGestureRecognizer.translation(in: scrollView).x
        let threshold: CGFloat = 56
        if startedAtLeftEdge && translation >= threshold {
            return .left
        }
        if startedAtRightEdge && translation <= -threshold {
            return .right
        }
        return nil
    }
}

struct ComicReaderBridge: View {
    let pages: [URL]
    let pageData: (URL) async throws -> Data
    @Binding var currentPageIndex: Int
    let layout: ReaderComicLayoutOption
    let pageFit: ComicPageFit
    let zoomEnabled: Bool
    let oneHandedZoom: Bool
    let backgroundColor: ComicBackgroundColor
    let spreadEnabled: Bool
    let onVisiblePageChange: (Int) -> Void
    let onTap: (CGPoint, CGSize) -> Void

    @ViewBuilder
    var body: some View {
        if layout == .scroll {
            ComicScrollReader(
                pages: pages,
                pageData: pageData,
                currentPageIndex: $currentPageIndex,
                backgroundColor: backgroundColor,
                zoomEnabled: zoomEnabled,
                onVisiblePageChange: onVisiblePageChange,
                onTap: onTap
            )
        } else {
            ComicPagedReader(
                pages: pages,
                pageData: pageData,
                currentPageIndex: $currentPageIndex,
                layout: layout,
                backgroundColor: backgroundColor,
                zoomEnabled: zoomEnabled,
                oneHandedZoom: oneHandedZoom,
                spreadEnabled: spreadEnabled,
                onLayoutChange: onVisiblePageChange,
                onTap: onTap
            )
        }
    }
}

private struct ComicPagedReader: UIViewControllerRepresentable {
    let pages: [URL]
    let pageData: (URL) async throws -> Data
    @Binding var currentPageIndex: Int
    let layout: ReaderComicLayoutOption
    let backgroundColor: ComicBackgroundColor
    let zoomEnabled: Bool
    let oneHandedZoom: Bool
    let spreadEnabled: Bool
    let onLayoutChange: (Int) -> Void
    let onTap: (CGPoint, CGSize) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> ComicPagedViewController {
        let vc = ComicPagedViewController(
            pages: pages,
            pageData: pageData,
            initialIndex: currentPageIndex,
            isRTL: layout == .rightToLeft,
            backgroundColor: backgroundColor.uiColor,
            zoomEnabled: zoomEnabled,
            oneHandedZoom: oneHandedZoom,
            spreadEnabled: spreadEnabled,
            onTap: onTap
        )
        let coordinator = context.coordinator
        vc.pageChangeHandler = { index in
            coordinator.parent.currentPageIndex = index
        }
        vc.layoutChangeHandler = { index in
            coordinator.parent.onLayoutChange(index)
        }
        return vc
    }

    func updateUIViewController(_ vc: ComicPagedViewController, context: Context) {
        vc.updateSettings(
            zoomEnabled: zoomEnabled,
            oneHandedZoom: oneHandedZoom,
            backgroundColor: backgroundColor.uiColor,
            isRTL: layout == .rightToLeft,
            spreadEnabled: spreadEnabled,
            onTap: onTap
        )
        if vc.currentIndex != currentPageIndex {
            vc.navigateTo(index: currentPageIndex, animated: true)
        }
    }

    final class Coordinator {
        var parent: ComicPagedReader
        init(_ parent: ComicPagedReader) { self.parent = parent }
    }
}

private final class ComicPagedViewController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    let pages: [URL]
    let pageData: (URL) async throws -> Data
    private(set) var currentIndex: Int
    private var isRTL: Bool
    private var bgColor: UIColor
    private var zoomEnabled: Bool
    private var oneHandedZoom: Bool
    private var spreadEnabled: Bool
    private var isLandscape = false
    private var onTap: (CGPoint, CGSize) -> Void
    var pageChangeHandler: ((Int) -> Void)?
    var layoutChangeHandler: ((Int) -> Void)?

    private var pageVC: UIPageViewController!

    private var isSpreadActive: Bool { spreadEnabled && isLandscape }

    init(
        pages: [URL],
        pageData: @escaping (URL) async throws -> Data,
        initialIndex: Int,
        isRTL: Bool,
        backgroundColor: UIColor,
        zoomEnabled: Bool,
        oneHandedZoom: Bool,
        spreadEnabled: Bool,
        onTap: @escaping (CGPoint, CGSize) -> Void
    ) {
        self.pages = pages
        self.pageData = pageData
        self.currentIndex = max(0, min(initialIndex, pages.count - 1))
        self.isRTL = isRTL
        self.bgColor = backgroundColor
        self.zoomEnabled = zoomEnabled
        self.oneHandedZoom = oneHandedZoom
        self.spreadEnabled = spreadEnabled
        self.onTap = onTap
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColor

        let direction: UIPageViewController.NavigationOrientation = .horizontal
        pageVC = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: direction,
            options: [.interPageSpacing: 4]
        )
        pageVC.dataSource = self
        pageVC.delegate = self
        pageVC.view.backgroundColor = bgColor

        addChild(pageVC)
        pageVC.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageVC.view)
        NSLayoutConstraint.activate([
            pageVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            pageVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pageVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        pageVC.didMove(toParent: self)

        applyLayoutDirection()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let landscape = view.bounds.width > view.bounds.height
        let wasSpread = spreadEnabled && isLandscape
        isLandscape = landscape
        let nowSpread = spreadEnabled && isLandscape

        if pageVC.viewControllers?.isEmpty != false {
            showCurrentPage(animated: false)
        } else if wasSpread != nowSpread {
            showCurrentPage(animated: false)
            notifyLayoutChange()
        }
    }

    // The current page survives rotation; a spread only decides which neighbour shares the screen.
    func navigateTo(index: Int, animated: Bool) {
        let bounded = max(0, min(index, pages.count - 1))
        guard bounded != currentIndex else { return }
        let direction: UIPageViewController.NavigationDirection = bounded > currentIndex ? .forward : .reverse
        currentIndex = bounded
        if isSpreadActive {
            let visibleRange = (pageVC.viewControllers?.first as? ComicSpreadPageViewController)?.pageRange
            guard spreadRange(containing: bounded) != visibleRange,
                let vc = makeSpreadVC(containing: bounded)
            else { return }
            pageVC.setViewControllers([vc], direction: direction, animated: animated)
        } else if let vc = makeSingleVC(for: bounded) {
            pageVC.setViewControllers([vc], direction: direction, animated: animated)
        }
    }

    private func notifyLayoutChange() {
        let index = currentIndex
        Task { @MainActor [weak self] in
            self?.layoutChangeHandler?(index)
        }
    }

    func updateSettings(
        zoomEnabled: Bool,
        oneHandedZoom: Bool,
        backgroundColor: UIColor,
        isRTL: Bool,
        spreadEnabled: Bool,
        onTap: @escaping (CGPoint, CGSize) -> Void
    ) {
        let rtlChanged = self.isRTL != isRTL
        let spreadChanged = self.spreadEnabled != spreadEnabled
        self.zoomEnabled = zoomEnabled
        self.oneHandedZoom = oneHandedZoom
        self.bgColor = backgroundColor
        self.isRTL = isRTL
        self.spreadEnabled = spreadEnabled
        self.onTap = onTap

        view.backgroundColor = bgColor
        pageVC?.view.backgroundColor = bgColor

        if rtlChanged { applyLayoutDirection() }
        if spreadChanged || rtlChanged { showCurrentPage(animated: false) }

        if let current = pageVC?.viewControllers?.first as? ComicSinglePageViewController {
            current.updateSettings(
                zoomEnabled: zoomEnabled,
                oneHandedZoom: oneHandedZoom,
                backgroundColor: bgColor,
                onTap: onTap
            )
        }
    }

    private func showCurrentPage(animated: Bool) {
        if isSpreadActive {
            if let vc = makeSpreadVC(containing: currentIndex) {
                pageVC.setViewControllers([vc], direction: .forward, animated: animated)
            }
        } else {
            if let vc = makeSingleVC(for: currentIndex) {
                pageVC.setViewControllers([vc], direction: .forward, animated: animated)
            }
        }
    }

    private func applyLayoutDirection() {
        pageVC?.view.semanticContentAttribute = isRTL ? .forceRightToLeft : .forceLeftToRight
        for subview in pageVC?.view.subviews ?? [] {
            if let scrollView = subview as? UIScrollView {
                scrollView.semanticContentAttribute = isRTL ? .forceRightToLeft : .forceLeftToRight
            }
        }
    }

    private func makeSingleVC(for index: Int) -> ComicSinglePageViewController? {
        guard index >= 0, index < pages.count else { return nil }
        let vc = ComicSinglePageViewController(
            pageURL: pages[index],
            pageData: pageData,
            pageIndex: index,
            backgroundColor: bgColor,
            zoomEnabled: zoomEnabled,
            oneHandedZoom: oneHandedZoom,
            onTap: onTap
        )
        vc.zoomChangeHandler = { [weak self] isZoomed in
            self?.setPageSwipeEnabled(!isZoomed)
        }
        vc.edgePageHandler = { [weak self] edge in
            self?.turnPage(from: edge)
        }
        return vc
    }

    private func spreadRange(containing index: Int) -> ClosedRange<Int> {
        ReaderPagedPagePolicy.comicSpread(
            containing: index,
            pageCount: pages.count,
            step: 2,
            isWidePage: { [pages] in ComicWidePageRegistry.shared.isWide(pages[$0]) }
        )
    }

    private func makeSpreadVC(containing index: Int) -> ComicSpreadPageViewController? {
        guard pages.indices.contains(index) else { return nil }
        let range = spreadRange(containing: index)
        let isPair = range.count == 2

        let leftURL: URL
        let rightURL: URL?
        if isRTL && isPair {
            leftURL = pages[range.upperBound]
            rightURL = pages[range.lowerBound]
        } else {
            leftURL = pages[range.lowerBound]
            rightURL = isPair ? pages[range.upperBound] : nil
        }

        let vc = ComicSpreadPageViewController(
            leftPageURL: leftURL,
            rightPageURL: rightURL,
            pageRange: range,
            pageData: pageData,
            backgroundColor: bgColor,
            zoomEnabled: zoomEnabled,
            oneHandedZoom: oneHandedZoom,
            onTap: onTap
        )
        vc.zoomChangeHandler = { [weak self] isZoomed in
            self?.setPageSwipeEnabled(!isZoomed)
        }
        vc.edgePageHandler = { [weak self] edge in
            self?.turnPage(from: edge)
        }
        vc.widePageHandler = { [weak self] in
            self?.refreshSpreadsAfterWidePageDiscovery()
        }
        return vc
    }

    // Streamed page dimensions arrive after decoding, so refresh an outdated pair.
    private func refreshSpreadsAfterWidePageDiscovery() {
        guard isSpreadActive,
            let visible = pageVC.viewControllers?.first as? ComicSpreadPageViewController
        else { return }
        if spreadRange(containing: currentIndex) != visible.pageRange {
            showCurrentPage(animated: false)
            notifyLayoutChange()
        } else {
            pageVC.setViewControllers([visible], direction: .forward, animated: false)
        }
    }

    private func turnPage(from edge: ComicHorizontalEdge) {
        let advances = isRTL ? edge == .left : edge == .right
        let targetIndex = ReaderPagedPagePolicy.adjacentComicPageIndex(
            from: currentIndex,
            by: advances ? 1 : -1,
            pageCount: pages.count,
            step: isSpreadActive ? 2 : 1,
            isWidePage: { [pages] in ComicWidePageRegistry.shared.isWide(pages[$0]) }
        )
        guard targetIndex != currentIndex else { return }
        setPageSwipeEnabled(true)
        navigateTo(index: targetIndex, animated: true)
        pageChangeHandler?(currentIndex)
    }

    private func setPageSwipeEnabled(_ enabled: Bool) {
        for subview in pageVC?.view.subviews ?? [] {
            if let scrollView = subview as? UIScrollView {
                scrollView.isScrollEnabled = enabled
            }
        }
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        if let spread = viewController as? ComicSpreadPageViewController {
            return makeSpreadVC(containing: spread.pageRange.lowerBound - 1)
        }
        guard let page = viewController as? ComicSinglePageViewController else { return nil }
        return makeSingleVC(for: page.pageIndex - 1)
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        if let spread = viewController as? ComicSpreadPageViewController {
            return makeSpreadVC(containing: spread.pageRange.upperBound + 1)
        }
        guard let page = viewController as? ComicSinglePageViewController else { return nil }
        return makeSingleVC(for: page.pageIndex + 1)
    }

    func pageViewController(
        _ pvc: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        guard completed else { return }
        if let spread = pvc.viewControllers?.first as? ComicSpreadPageViewController {
            currentIndex = spread.pageRange.lowerBound
            pageChangeHandler?(currentIndex)
        } else if let current = pvc.viewControllers?.first as? ComicSinglePageViewController {
            currentIndex = current.pageIndex
            pageChangeHandler?(currentIndex)
        }
    }
}

private final class ComicSpreadPageViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {

    let pageRange: ClosedRange<Int>
    private let pageData: (URL) async throws -> Data
    private let leftPageURL: URL
    private let rightPageURL: URL?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let leadingImageView = UIImageView()
    private let trailingImageView = UIImageView()
    private var bgColor: UIColor
    private var zoomEnabled: Bool
    private var oneHandedZoom: Bool
    private var onTap: (CGPoint, CGSize) -> Void
    var zoomChangeHandler: ((Bool) -> Void)?
    var edgePageHandler: ((ComicHorizontalEdge) -> Void)?
    var widePageHandler: (() -> Void)?

    private var oneHandedZoomGesture: UILongPressGestureRecognizer?
    private var oneHandedZoomStartY: CGFloat = 0
    private var oneHandedZoomStartScale: CGFloat = 1.0
    private var isOneHandedZooming = false
    private var pendingImages = 0
    private var imageTasks: [Task<Void, Never>] = []
    private var imageGeneration = 0
    private var hasPageFailure = false
    private lazy var pageLoading = ComicPageLoadingOverlay { [weak self] in self?.loadImages() }
    private var edgePagingTracker = ComicEdgePagingTracker()

    init(
        leftPageURL: URL,
        rightPageURL: URL?,
        pageRange: ClosedRange<Int>,
        pageData: @escaping (URL) async throws -> Data,
        backgroundColor: UIColor,
        zoomEnabled: Bool,
        oneHandedZoom: Bool,
        onTap: @escaping (CGPoint, CGSize) -> Void
    ) {
        self.pageData = pageData
        self.leftPageURL = leftPageURL
        self.rightPageURL = rightPageURL
        self.pageRange = pageRange
        self.bgColor = backgroundColor
        self.zoomEnabled = zoomEnabled
        self.oneHandedZoom = oneHandedZoom
        self.onTap = onTap
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColor

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = zoomEnabled ? 4.0 : 1.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = bgColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        scrollView.addSubview(contentView)

        leadingImageView.contentMode = .scaleAspectFit
        leadingImageView.clipsToBounds = true
        contentView.addSubview(leadingImageView)

        trailingImageView.contentMode = .scaleAspectFit
        trailingImageView.clipsToBounds = true
        contentView.addSubview(trailingImageView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        applyOneHandedZoom()
        pageLoading.install(in: view)
        loadImages()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isOneHandedZooming else { return }
        layoutSpread()
    }

    deinit { imageTasks.forEach { $0.cancel() } }

    private func loadImages() {
        imageTasks.forEach { $0.cancel() }
        imageGeneration += 1
        let generation = imageGeneration
        pendingImages = rightPageURL != nil ? 2 : 1
        hasPageFailure = false
        pageLoading.showLoading()
        var pages = [(leftPageURL, leadingImageView)]
        if let rightPageURL { pages.append((rightPageURL, trailingImageView)) }
        imageTasks = pages.map { url, imageView in
            Task { [weak self, pageData] in
                do {
                    let data = try await pageData(url)
                    try Task.checkCancellation()
                    guard let image = UIImage(data: data) else { throw ServerPageStreamingService.StreamingError.invalidPageData }
                    guard let self, imageGeneration == generation else { return }
                    recordShape(of: image, at: url)
                    imageView.image = image
                    pendingImages -= 1
                    if pendingImages == 0 {
                        if !hasPageFailure { pageLoading.hide() }
                        layoutSpread()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, imageGeneration == generation else { return }
                    pendingImages -= 1
                    hasPageFailure = true
                    pageLoading.showFailure()
                    layoutSpread()
                }
            }
        }
    }

    private func recordShape(of image: UIImage, at url: URL) {
        let isWide = ComicWidePageRegistry.shared.record(image.size, for: url)
        if isWide && rightPageURL != nil { widePageHandler?() }
    }

    private func layoutSpread() {
        let boundsSize = scrollView.bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return }

        let leftSize = leadingImageView.image?.size ?? CGSize(width: 100, height: 140)
        let hasRight = rightPageURL != nil && trailingImageView.image != nil
        let rightSize = hasRight ? (trailingImageView.image?.size ?? leftSize) : .zero

        if hasRight {
            let combinedW = leftSize.width + rightSize.width
            let combinedH = max(leftSize.height, rightSize.height)
            let fitScale = min(boundsSize.width / combinedW, boundsSize.height / combinedH)

            let totalW = combinedW * fitScale
            let totalH = combinedH * fitScale
            let leftW = leftSize.width * fitScale
            let rightW = rightSize.width * fitScale

            contentView.frame = CGRect(x: 0, y: 0, width: totalW, height: totalH)
            leadingImageView.frame = CGRect(x: 0, y: 0, width: leftW, height: totalH)
            trailingImageView.frame = CGRect(x: leftW, y: 0, width: rightW, height: totalH)
            trailingImageView.isHidden = false
        } else {
            let fitScale = min(boundsSize.width / leftSize.width, boundsSize.height / leftSize.height)
            let w = leftSize.width * fitScale
            let h = leftSize.height * fitScale
            contentView.frame = CGRect(x: 0, y: 0, width: w, height: h)
            leadingImageView.frame = CGRect(x: 0, y: 0, width: w, height: h)
            trailingImageView.isHidden = true
        }

        scrollView.contentSize = contentView.frame.size
        scrollView.zoomScale = 1.0
        centerContent()
    }

    private func centerContent() {
        let boundsSize = scrollView.bounds.size
        let cs = scrollView.contentSize
        let ox = max((boundsSize.width - cs.width * scrollView.zoomScale) / 2, 0)
        let oy = max((boundsSize.height - cs.height * scrollView.zoomScale) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: oy, left: ox, bottom: oy, right: ox)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        if !isOneHandedZooming {
            zoomChangeHandler?(scrollView.zoomScale > scrollView.minimumZoomScale + 0.01)
        }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        zoomChangeHandler?(scale > scrollView.minimumZoomScale + 0.01)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        edgePagingTracker.begin(in: scrollView, contentWidth: contentView.bounds.width)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard let edge = edgePagingTracker.end(in: scrollView) else { return }
        edgePageHandler?(edge)
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        onTap(gesture.location(in: view), view.bounds.size)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: contentView)
            let targetScale = min(scrollView.maximumZoomScale, 2.5)
            let w = scrollView.bounds.width / targetScale
            let h = scrollView.bounds.height / targetScale
            scrollView.zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h), animated: true)
        }
    }

    private func applyOneHandedZoom() {
        if oneHandedZoom && zoomEnabled {
            if oneHandedZoomGesture == nil {
                let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleOneHandedZoom(_:)))
                gesture.minimumPressDuration = 0.25
                gesture.delegate = self
                scrollView.addGestureRecognizer(gesture)
                oneHandedZoomGesture = gesture
            }
            oneHandedZoomGesture?.isEnabled = true
        } else {
            oneHandedZoomGesture?.isEnabled = false
        }
    }

    @objc private func handleOneHandedZoom(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            isOneHandedZooming = true
            oneHandedZoomStartY = gesture.location(in: view).y
            oneHandedZoomStartScale = scrollView.zoomScale
            zoomChangeHandler?(true)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            let deltaY = oneHandedZoomStartY - gesture.location(in: view).y
            let scaleFactor = pow(2.0, deltaY / 200.0)
            scrollView.zoomScale = min(
                max(
                    oneHandedZoomStartScale * scaleFactor,
                    scrollView.minimumZoomScale
                ),
                scrollView.maximumZoomScale
            )
        case .ended, .cancelled:
            isOneHandedZooming = false
            var finalScale = scrollView.zoomScale
            if finalScale < scrollView.minimumZoomScale + 0.05 {
                finalScale = scrollView.minimumZoomScale
                scrollView.setZoomScale(finalScale, animated: true)
            }
            centerContent()
            zoomChangeHandler?(finalScale > scrollView.minimumZoomScale + 0.01)
        default: break
        }
    }

    func gestureRecognizer(_ gr: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gr === oneHandedZoomGesture
    }
}

private final class ComicSinglePageViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {

    let pageIndex: Int
    private let pageURL: URL
    private let pageData: (URL) async throws -> Data
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var bgColor: UIColor
    private var zoomEnabled: Bool
    private var oneHandedZoom: Bool
    private var onTap: (CGPoint, CGSize) -> Void
    var zoomChangeHandler: ((Bool) -> Void)?
    var edgePageHandler: ((ComicHorizontalEdge) -> Void)?

    private var oneHandedZoomGesture: UILongPressGestureRecognizer?
    private var oneHandedZoomStartY: CGFloat = 0
    private var oneHandedZoomStartScale: CGFloat = 1.0
    private var isOneHandedZooming = false
    private var edgePagingTracker = ComicEdgePagingTracker()

    private var imageTask: Task<Void, Never>?
    private lazy var pageLoading = ComicPageLoadingOverlay { [weak self] in self?.loadImage() }

    init(
        pageURL: URL,
        pageData: @escaping (URL) async throws -> Data,
        pageIndex: Int,
        backgroundColor: UIColor,
        zoomEnabled: Bool,
        oneHandedZoom: Bool,
        onTap: @escaping (CGPoint, CGSize) -> Void
    ) {
        self.pageURL = pageURL
        self.pageData = pageData
        self.pageIndex = pageIndex
        self.bgColor = backgroundColor
        self.zoomEnabled = zoomEnabled
        self.oneHandedZoom = oneHandedZoom
        self.onTap = onTap
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColor

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = zoomEnabled ? 4.0 : 1.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = bgColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.require(toFail: doubleTap)

        scrollView.addGestureRecognizer(doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        applyOneHandedZoom()
        pageLoading.install(in: view)
        loadImage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isOneHandedZooming else { return }
        layoutImageForCurrentZoom()
    }

    func updateSettings(
        zoomEnabled: Bool,
        oneHandedZoom: Bool,
        backgroundColor: UIColor,
        onTap: @escaping (CGPoint, CGSize) -> Void
    ) {
        self.zoomEnabled = zoomEnabled
        self.oneHandedZoom = oneHandedZoom
        self.bgColor = backgroundColor
        self.onTap = onTap
        view.backgroundColor = bgColor
        scrollView.backgroundColor = bgColor
        scrollView.maximumZoomScale = zoomEnabled ? 4.0 : 1.0
        if !zoomEnabled && scrollView.zoomScale > 1.0 {
            scrollView.setZoomScale(1.0, animated: true)
        }
        applyOneHandedZoom()
    }

    deinit { imageTask?.cancel() }

    private func loadImage() {
        imageTask?.cancel()
        pageLoading.showLoading()
        imageTask = Task { [weak self, pageURL, pageData] in
            do {
                let data = try await pageData(pageURL)
                try Task.checkCancellation()
                guard let image = UIImage(data: data) else { throw ServerPageStreamingService.StreamingError.invalidPageData }
                ComicWidePageRegistry.shared.record(image.size, for: pageURL)
                self?.imageView.image = image
                self?.layoutImageForCurrentZoom()
                self?.pageLoading.hide()
            } catch is CancellationError {
                return
            } catch {
                self?.pageLoading.showFailure()
            }
        }
    }

    private func layoutImageForCurrentZoom() {
        guard let image = imageView.image else { return }
        let boundsSize = scrollView.bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return }

        let imageSize = image.size
        let widthScale = boundsSize.width / imageSize.width
        let heightScale = boundsSize.height / imageSize.height
        let fitScale = min(widthScale, heightScale)

        let fittedWidth = imageSize.width * fitScale
        let fittedHeight = imageSize.height * fitScale

        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = zoomEnabled ? 4.0 : 1.0

        imageView.frame = CGRect(x: 0, y: 0, width: fittedWidth, height: fittedHeight)
        scrollView.contentSize = CGSize(width: fittedWidth, height: fittedHeight)

        scrollView.zoomScale = 1.0

        centerImage()
    }

    private func centerImage() {
        let boundsSize = scrollView.bounds.size
        let contentSize = scrollView.contentSize

        let offsetX = max((boundsSize.width - contentSize.width * scrollView.zoomScale) / 2, 0)
        let offsetY = max((boundsSize.height - contentSize.height * scrollView.zoomScale) / 2, 0)

        scrollView.contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()

        if !isOneHandedZooming {
            let isZoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            zoomChangeHandler?(isZoomed)
        }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        let isZoomed = scale > scrollView.minimumZoomScale + 0.01
        zoomChangeHandler?(isZoomed)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        edgePagingTracker.begin(in: scrollView, contentWidth: imageView.bounds.width)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard let edge = edgePagingTracker.end(in: scrollView) else { return }
        edgePageHandler?(edge)
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: view)
        onTap(location, view.bounds.size)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let targetScale = min(scrollView.maximumZoomScale, 2.5)
            let zoomWidth = scrollView.bounds.width / targetScale
            let zoomHeight = scrollView.bounds.height / targetScale
            let zoomRect = CGRect(
                x: point.x - zoomWidth / 2,
                y: point.y - zoomHeight / 2,
                width: zoomWidth,
                height: zoomHeight
            )
            scrollView.zoom(to: zoomRect, animated: true)
        }
    }

    private func applyOneHandedZoom() {
        if oneHandedZoom && zoomEnabled {
            if oneHandedZoomGesture == nil {
                let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleOneHandedZoom(_:)))
                gesture.minimumPressDuration = 0.25
                gesture.delegate = self
                scrollView.addGestureRecognizer(gesture)
                oneHandedZoomGesture = gesture
            }
            oneHandedZoomGesture?.isEnabled = true
        } else {
            oneHandedZoomGesture?.isEnabled = false
        }
    }

    @objc private func handleOneHandedZoom(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            isOneHandedZooming = true
            oneHandedZoomStartY = gesture.location(in: view).y
            oneHandedZoomStartScale = scrollView.zoomScale
            zoomChangeHandler?(true)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

        case .changed:
            let currentY = gesture.location(in: view).y
            let deltaY = oneHandedZoomStartY - currentY
            let sensitivity: CGFloat = 200.0
            let scaleFactor = pow(2.0, deltaY / sensitivity)
            let newScale = min(
                max(
                    oneHandedZoomStartScale * scaleFactor,
                    scrollView.minimumZoomScale
                ),
                scrollView.maximumZoomScale
            )
            scrollView.zoomScale = newScale

        case .ended, .cancelled:
            isOneHandedZooming = false

            var finalScale = scrollView.zoomScale
            if finalScale < scrollView.minimumZoomScale + 0.05 {
                finalScale = scrollView.minimumZoomScale
                scrollView.setZoomScale(finalScale, animated: true)
            }

            centerImage()
            let isZoomed = finalScale > scrollView.minimumZoomScale + 0.01
            zoomChangeHandler?(isZoomed)

        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === oneHandedZoomGesture
    }
}

private struct ComicScrollReader: View {
    let pages: [URL]
    let pageData: (URL) async throws -> Data
    @Binding var currentPageIndex: Int
    let backgroundColor: ComicBackgroundColor
    let zoomEnabled: Bool
    let onVisiblePageChange: (Int) -> Void
    let onTap: (CGPoint, CGSize) -> Void
    @State private var visiblePageIndex: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, pageURL in
                        ComicScrollZoomablePageView(
                            pageURL: pageURL,
                            pageData: pageData,
                            backgroundColor: backgroundColor,
                            zoomEnabled: zoomEnabled,
                            onTap: onTap
                        )
                        .aspectRatio(0.72, contentMode: .fit)
                        .onAppear {
                            visiblePageIndex = index
                            onVisiblePageChange(index)
                        }
                        .id(index)
                    }
                }
            }
            .background(backgroundColor.swiftUIColor)
            .onAppear {
                visiblePageIndex = currentPageIndex
                proxy.scrollTo(currentPageIndex, anchor: .top)
            }
            .onChange(of: currentPageIndex) { _, newValue in
                guard visiblePageIndex != newValue else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .top)
                }
            }
        }
    }
}

private final class ZoomScrollView: UIScrollView {
    var onBoundsChange: (() -> Void)?
    private var lastBoundsSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            onBoundsChange?()
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            return zoomScale > minimumZoomScale + 0.01
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

private struct ComicScrollZoomablePageView: UIViewRepresentable {
    let pageURL: URL
    let pageData: (URL) async throws -> Data
    let backgroundColor: ComicBackgroundColor
    let zoomEnabled: Bool
    let onTap: (CGPoint, CGSize) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(pageData: pageData, onTap: onTap) }

    func makeUIView(context: Context) -> ZoomScrollView {
        let coordinator = context.coordinator
        let scrollView = ZoomScrollView()
        scrollView.delegate = coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = zoomEnabled ? 4.0 : 1.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = backgroundColor.uiColor
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        scrollView.addSubview(imageView)

        coordinator.imageView = imageView
        coordinator.scrollView = scrollView
        scrollView.onBoundsChange = { [weak coordinator] in
            coordinator?.layoutImage()
        }

        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        coordinator.pageLoading.install(in: scrollView)
        coordinator.loadImage(from: pageURL)
        return scrollView
    }

    func updateUIView(_ scrollView: ZoomScrollView, context: Context) {
        context.coordinator.onTap = onTap
        scrollView.backgroundColor = backgroundColor.uiColor
        scrollView.maximumZoomScale = zoomEnabled ? 4.0 : 1.0
        if !zoomEnabled && scrollView.zoomScale > 1.0 {
            scrollView.setZoomScale(1.0, animated: false)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let pageData: (URL) async throws -> Data
        var onTap: (CGPoint, CGSize) -> Void
        weak var imageView: UIImageView?
        weak var scrollView: ZoomScrollView?

        init(pageData: @escaping (URL) async throws -> Data, onTap: @escaping (CGPoint, CGSize) -> Void) {
            self.pageData = pageData
            self.onTap = onTap
        }

        private var imageTask: Task<Void, Never>?
        private var pageURL: URL?
        lazy var pageLoading = ComicPageLoadingOverlay { [weak self] in
            guard let self, let pageURL else { return }
            loadImage(from: pageURL)
        }

        deinit { imageTask?.cancel() }

        func loadImage(from url: URL) {
            imageTask?.cancel()
            pageURL = url
            pageLoading.showLoading()
            imageTask = Task { [weak self, pageData] in
                do {
                    let data = try await pageData(url)
                    try Task.checkCancellation()
                    guard let image = UIImage(data: data) else { throw ServerPageStreamingService.StreamingError.invalidPageData }
                    self?.imageView?.image = image
                    self?.layoutImage()
                    self?.pageLoading.hide()
                } catch is CancellationError {
                    return
                } catch {
                    self?.pageLoading.showFailure()
                }
            }
        }

        func layoutImage() {
            guard let scrollView, let imageView, let image = imageView.image else { return }
            let boundsSize = scrollView.bounds.size
            guard boundsSize.width > 0, boundsSize.height > 0 else { return }

            let fitScale = min(boundsSize.width / image.size.width, boundsSize.height / image.size.height)
            let fittedSize = CGSize(width: image.size.width * fitScale, height: image.size.height * fitScale)
            imageView.frame = CGRect(origin: .zero, size: fittedSize)
            scrollView.contentSize = fittedSize
            scrollView.zoomScale = 1.0
            centerImage()
        }

        private func centerImage() {
            guard let scrollView, let imageView else { return }
            let boundsSize = scrollView.bounds.size
            let scaledWidth = imageView.frame.width * scrollView.zoomScale
            let scaledHeight = imageView.frame.height * scrollView.zoomScale
            let offsetX = max((boundsSize.width - scaledWidth) / 2, 0)
            let offsetY = max((boundsSize.height - scaledHeight) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                guard let imageView else { return }
                let point = gesture.location(in: imageView)
                let targetScale = min(scrollView.maximumZoomScale, 2.5)
                let w = scrollView.bounds.width / targetScale
                let h = scrollView.bounds.height / targetScale
                scrollView.zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h), animated: true)
            }
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            onTap(gesture.location(in: scrollView), scrollView.bounds.size)
        }
    }
}
