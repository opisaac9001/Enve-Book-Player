import Foundation
import PDFKit
import Testing
import UIKit

@testable import enve

@MainActor
final class PDFReaderControllerTests {
    private let fixture: OfflineAvailabilityFixture
    private let pdfURL: URL
    private let twoPage = PDFReadingLayout(twoPageEnabled: true)
    private let coverSeparately = PDFReadingLayout(twoPageEnabled: true, showsCoverSeparately: true)

    init() throws {
        fixture = try OfflineAvailabilityFixture()
        pdfURL = try Self.writePDF(pageCount: 6)
    }

    deinit {
        let captured = fixture
        let url = pdfURL
        Task { @MainActor in
            await captured.close()
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func aFreshBookOpensAsSinglePages() async throws {
        let (reader, host) = try await open(bookID: UUID().uuidString)
        #expect(reader.pdfLayout == PDFReadingLayout())
        #expect(host.pagedVisiblePageRange == 1...1)
        let pdfView = try embeddedPDFView(reader)
        #expect(pdfView.displayMode == .singlePage)
        #expect(!pdfView.displaysAsBook)
    }

    @Test func pagedTurnsAdvanceWholeSpreadsAndReturnToTheCover() async throws {
        let (reader, host) = try await open(bookID: UUID().uuidString)
        reader.setPDFLayout(coverSeparately)
        #expect(host.pagedVisiblePageRange == 1...1)

        reader.stepPDFPage(by: 1)
        #expect(host.pagedVisiblePageRange == 2...3)
        #expect(reader.currentPDFPageIndex == 1)
        reader.stepPDFPage(by: 1)
        #expect(host.pagedVisiblePageRange == 4...5)
        reader.stepPDFPage(by: 1)
        #expect(host.pagedVisiblePageRange == 6...6)
        reader.stepPDFPage(by: 1)
        #expect(host.pagedVisiblePageRange == 6...6)
        reader.stepPDFPage(by: -1)
        #expect(host.pagedVisiblePageRange == 4...5)
        reader.stepPDFPage(by: -1)
        reader.stepPDFPage(by: -1)
        #expect(host.pagedVisiblePageRange == 1...1)
        #expect(reader.currentPDFPageIndex == 0)

        reader.setPDFLayout(twoPage)
        #expect(host.pagedVisiblePageRange == 1...2)
        reader.stepPDFPage(by: 1)
        #expect(host.pagedVisiblePageRange == 3...4)
        reader.stepPDFPage(by: 1)
        #expect(host.pagedVisiblePageRange == 5...6)
        #expect(host.pagedCurrentProgress == 1)
        reader.stepPDFPage(by: 1)
        #expect(host.pagedVisiblePageRange == 5...6)
    }

    @Test func togglingPairingOnAnInnerPageKeepsItVisibleWithoutAStatsTick() async throws {
        let (reader, host) = try await open(bookID: UUID().uuidString)
        reader.requestPDFPage(1)
        #expect(host.pagedVisiblePageRange == 2...2)
        let navigationsBefore = host.userNavigations
        let progressBefore = host.pagedCurrentProgress

        reader.setPDFLayout(coverSeparately)
        #expect(host.pagedVisiblePageRange == 2...3)
        #expect(reader.currentPDFPageIndex == 1)
        #expect(try embeddedPDFView(reader).displaysAsBook)

        reader.setPDFLayout(twoPage)
        #expect(host.pagedVisiblePageRange == 1...2)
        #expect(reader.currentPDFPageIndex == 1)
        let paired = try embeddedPDFView(reader)
        #expect(paired.displayMode == .twoUp)
        #expect(!paired.displaysAsBook)

        reader.setPDFLayout(PDFReadingLayout())
        #expect(host.pagedVisiblePageRange == 2...2)
        #expect(host.userNavigations == navigationsBefore)
        #expect(host.pagedCurrentProgress == progressBefore)
        #expect(reader.pdfController?.currentPageIndex() == 1)
    }

    @Test func scrolledFlowUsesContinuousTwoUpAndUnchangedSettingsKeepTheView() async throws {
        var appearance = ClassicReaderAppearance()
        appearance.pdfScrollEnabled = true
        let (reader, _) = try await open(bookID: UUID().uuidString, appearance: appearance)
        reader.setPDFLayout(twoPage)
        let scrolled = try embeddedPDFView(reader)
        #expect(scrolled.displayMode == .twoUpContinuous)
        #expect(scrolled.displayDirection == .vertical)

        reader.applyAppearance(appearance)
        #expect(try embeddedPDFView(reader) === scrolled)
        reader.setPDFLayout(twoPage)
        #expect(try embeddedPDFView(reader) === scrolled)

        appearance.pdfScrollEnabled = false
        reader.applyAppearance(appearance)
        let paged = try embeddedPDFView(reader)
        #expect(paged !== scrolled)
        #expect(paged.displayMode == .twoUp)
        #expect(paged.displayDirection == .horizontal)
    }

    @Test func theStoredLayoutIsRestoredForTheSameBookOnly() async throws {
        let bookID = UUID().uuidString
        let (reader, _) = try await open(bookID: bookID)
        reader.requestPDFPage(2)
        reader.setPDFLayout(coverSeparately)

        let (reopened, host) = try await open(bookID: bookID)
        #expect(reopened.pdfLayout == coverSeparately)
        #expect(host.pagedVisiblePageRange == 1...1)
        let pdfView = try embeddedPDFView(reopened)
        #expect(pdfView.displayMode == .twoUp)
        #expect(pdfView.displaysAsBook)

        let (other, otherHost) = try await open(bookID: UUID().uuidString)
        #expect(other.pdfLayout == PDFReadingLayout())
        #expect(otherHost.pagedVisiblePageRange == 1...1)
        #expect(try embeddedPDFView(other).displayMode == .singlePage)
    }

    @Test func pendingSelectionSurvivesLayoutAndFlowChangesBeforePresentation() throws {
        let document = try #require(PDFDocument(url: pdfURL))
        var callbacks: [Int] = []
        let controller = PDFReaderController(document: document, initialPageIndex: 4, scrollEnabled: false,
            layout: twoPage, onPageChange: { callbacks.append($0) }, onTap: { _, _ in })
        controller.configure(scrollEnabled: true, layout: coverSeparately)
        #expect(controller.currentPageIndex() == 4)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        controller.view.layoutIfNeeded()
        #expect(controller.currentPageIndex() == 4)
        controller.goToPage(2)
        controller.configure(scrollEnabled: false, layout: twoPage)
        controller.view.layoutIfNeeded()
        #expect(controller.currentPageIndex() == 2)
        #expect(callbacks.isEmpty)
    }

    @Test func pageAdjustSetsPDFKitsRestingScaleAndPinchRangeAndRefitsOnRotation() throws {
        let document = try #require(PDFDocument(url: pdfURL))
        var callbacks: [Int] = []
        let controller = PDFReaderController(document: document, initialPageIndex: 2, scrollEnabled: false,
            layout: PDFReadingLayout(pageAdjust: .fillWidth), onPageChange: { callbacks.append($0) }, onTap: { _, _ in })
        layOut(controller, width: 400, height: 900)
        let pdfView = try embeddedPDFView(in: controller)
        #expect(!pdfView.autoScales)
        expectScale(pdfView, 400.0 / 300)

        layOut(controller, width: 900, height: 400)
        expectScale(pdfView, 3)
        #expect(controller.currentPageIndex() == 2)

        let landscapeScales: [(PDFPageAdjust, CGFloat)] = [(.crop, 3), (.fit, 1), (.fillHeight, 1), (.fillWidth, 3)]
        for (adjust, scale) in landscapeScales {
            controller.configure(scrollEnabled: false, layout: PDFReadingLayout(pageAdjust: adjust))
            #expect(try embeddedPDFView(in: controller) === pdfView, "Changing the page adjust must not rebuild the view")
            expectScale(pdfView, scale)
            #expect(controller.currentPageIndex() == 2)
        }
        #expect(callbacks.isEmpty)
    }

    @Test func pagedTurnsRefitEachSpreadWhileScrolledFlowKeepsThePinchZoom() throws {
        let document = try #require(PDFDocument(url: pdfURL))
        let paged = PDFReaderController(document: document, initialPageIndex: 0, scrollEnabled: false,
            layout: PDFReadingLayout(twoPageEnabled: true, showsCoverSeparately: true), onPageChange: { _ in }, onTap: { _, _ in })
        layOut(paged, width: 900, height: 700)
        let pagedView = try embeddedPDFView(in: paged)
        // The cover alone fits by height; the 600-point pair fits by width.
        expectScale(pagedView, 1.75)
        paged.goToPage(1)
        expectScale(pagedView, 1.5)
        #expect(paged.currentPageIndex() == 1)
        pagedView.scaleFactor = 4
        paged.goToPage(3)
        expectScale(pagedView, 1.5)
        #expect(paged.currentPageIndex() == 3)
        paged.goToPage(0)
        expectScale(pagedView, 1.75)
        #expect(paged.currentPageIndex() == 0)

        // Raising and lowering the base on a pair, without leaving it.
        paged.goToPage(2)
        expectScale(pagedView, 1.5)
        paged.configure(scrollEnabled: false, layout: PDFReadingLayout(twoPageEnabled: true, showsCoverSeparately: true, pageAdjust: .fillHeight))
        expectScale(pagedView, 1.75)
        paged.configure(scrollEnabled: false, layout: PDFReadingLayout(twoPageEnabled: true, showsCoverSeparately: true, pageAdjust: .crop))
        expectScale(pagedView, 1.75)
        paged.configure(scrollEnabled: false, layout: PDFReadingLayout(twoPageEnabled: true, showsCoverSeparately: true, pageAdjust: .fit))
        expectScale(pagedView, 1.5)
        #expect(paged.currentPageIndex() == 2)
        #expect(try embeddedPDFView(in: paged) === pagedView)

        let scrolled = PDFReaderController(document: document, initialPageIndex: 0, scrollEnabled: true,
            layout: PDFReadingLayout(), onPageChange: { _ in }, onTap: { _, _ in })
        layOut(scrolled, width: 900, height: 700)
        let scrolledView = try embeddedPDFView(in: scrolled)
        expectScale(scrolledView, 1.75)
        scrolledView.scaleFactor = 2.5
        scrolled.goToPage(4)
        expectScale(scrolledView, 2.5, resting: 1.75)
        #expect(scrolled.currentPageIndex() == 4)
    }

    @Test func pageAdjustIsRememberedPerBookWithoutMovingTheSelection() async throws {
        let bookID = UUID().uuidString
        let (reader, host) = try await open(bookID: bookID)
        reader.requestPDFPage(3)
        let navigationsBefore = host.userNavigations
        let pdfView = try embeddedPDFView(reader)

        reader.setPDFLayout(PDFReadingLayout(pageAdjust: .crop))
        #expect(try embeddedPDFView(reader) === pdfView)
        #expect(host.pagedVisiblePageRange == 4...4)
        #expect(host.userNavigations == navigationsBefore)
        #expect(reader.pdfController?.currentPageIndex() == 3)

        let (reopened, _) = try await open(bookID: bookID)
        #expect(reopened.pdfLayout == PDFReadingLayout(pageAdjust: .crop))
        let (other, _) = try await open(bookID: UUID().uuidString)
        #expect(other.pdfLayout.pageAdjust == .fit)
    }

    private func layOut(_ controller: PDFReaderController, width: CGFloat, height: CGFloat) {
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        controller.view.layoutIfNeeded()
    }

    // PDFKit page gaps slightly change the rendered scale and may lower the pinch floor.
    private func expectScale(
        _ pdfView: PDFView,
        _ scale: CGFloat,
        resting: CGFloat? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let base = resting ?? scale
        let shownPage = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) }
        let state =
            "PDFKit scale \(pdfView.scaleFactor) in \(pdfView.minScaleFactor)...\(pdfView.maxScaleFactor), "
            + "size-to-fit \(pdfView.scaleFactorForSizeToFit), page \(shownPage.map(String.init) ?? "none"), "
            + "bounds \(pdfView.bounds.size), mode \(pdfView.displayMode.rawValue)"
        #expect(abs(pdfView.scaleFactor - scale) <= scale * 0.005, "expected scale \(scale); \(state)", sourceLocation: sourceLocation)
        #expect(pdfView.minScaleFactor <= pdfView.scaleFactor + 0.001, "pinch floor above the shown scale; \(state)", sourceLocation: sourceLocation)
        #expect(
            abs(pdfView.maxScaleFactor - base * PDFPageAdjust.maximumZoom) < 0.001,
            "expected pinch ceiling \(base * PDFPageAdjust.maximumZoom); \(state)",
            sourceLocation: sourceLocation
        )
    }

    private func open(
        bookID: String,
        appearance: ClassicReaderAppearance = ClassicReaderAppearance()
    ) async throws -> (ReaderPagedContentController, Host) {
        let host = Host()
        let reader = ReaderPagedContentController(
            book: fixture.book(id: bookID, url: pdfURL),
            providerResolver: EmptyResolver(),
            libraryCache: fixture.session.appState.libraryCache,
            appearanceController: ReaderAppearanceController(appearance: appearance, persist: { _ in }),
            profileSession: fixture.session
        )
        reader.host = host
        try await reader.openPDF(at: pdfURL, initialSelection: nil)
        return (reader, host)
    }

    private func embeddedPDFView(_ reader: ReaderPagedContentController) throws -> PDFView {
        try embeddedPDFView(in: try #require(reader.pdfController))
    }

    private func embeddedPDFView(in controller: PDFReaderController) throws -> PDFView {
        controller.loadViewIfNeeded()
        return try #require(controller.view.subviews.compactMap { $0 as? PDFView }.first)
    }

    private static func writePDF(pageCount: Int) throws -> URL {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in 0..<pageCount {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(bounds)
                ("\(page + 1)" as NSString).draw(
                    at: CGPoint(x: 24, y: 24),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black]
                )
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-layout-\(UUID().uuidString).pdf")
        try data.write(to: url)
        return url
    }

    @MainActor
    private final class Host: ReaderPagedContentHosting {
        var pagedReaderState: ClassicReaderModel.State = .loading
        var pagedTotalPages = 0
        var pagedVisiblePageRange: ClosedRange<Int>?
        var pagedCurrentProgress: Double?
        var pagedPublicationFileURL: URL? { nil }
        var userNavigations = 0

        func pagedWillChange() {}
        func pagedPrepareArtifacts(loadingAnnotations: Bool) {}
        func pagedApplyPageState(visibleRange: ClosedRange<Int>, progress: Double, sectionTitle: String, isUserNavigation: Bool) {
            pagedVisiblePageRange = visibleRange
            pagedCurrentProgress = progress
            if isUserNavigation { userNavigations += 1 }
        }
        func pagedHandleTap(at point: CGPoint, in size: CGSize) {}
    }

    private final class EmptyResolver: LibraryProviderResolving {
        func provider(for providerId: UUID) -> LibraryProvider? { nil }
        func provider(for book: Book) -> LibraryProvider? { nil }
    }
}
