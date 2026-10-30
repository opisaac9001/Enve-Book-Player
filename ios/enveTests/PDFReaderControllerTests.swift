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
        let controller = try #require(reader.pdfController)
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
