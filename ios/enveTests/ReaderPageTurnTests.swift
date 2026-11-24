import Foundation
import PDFKit
import Testing
import UIKit

@testable import enve

@MainActor
@Suite(.serialized)
struct ReaderPageTurnTests {
    @Test func curlPreferenceRoundTripsWithoutResettingExistingAppearance() throws {
        let old = try JSONDecoder().decode(ClassicReaderAppearance.self, from: Data(#"{"theme":"sepia","fontSize":1.4}"#.utf8))
        #expect(old.pageTurnAnimation == .standard)
        var appearance = old
        appearance.pageTurnAnimation = .curl
        let restored = try JSONDecoder().decode(ClassicReaderAppearance.self, from: JSONEncoder().encode(appearance))
        #expect(restored.pageTurnAnimation == .curl)
        #expect(restored.theme == .sepia)
        #expect(restored.fontSize == 1.4)
        let unknown = try JSONDecoder().decode(ClassicReaderAppearance.self, from: Data(#"{"pageTurnAnimation":"future"}"#.utf8))
        #expect(unknown.pageTurnAnimation == .standard)
    }

    @Test func scrollingAndReduceMotionSuppressCurlWithoutChangingThePreference() {
        #expect(ReaderPageTurnAnimation.curl.usesCurl(scrolling: false, reduceMotion: false))
        #expect(!ReaderPageTurnAnimation.curl.usesCurl(scrolling: true, reduceMotion: false))
        #expect(!ReaderPageTurnAnimation.curl.usesCurl(scrolling: false, reduceMotion: true))
        #expect(!ReaderPageTurnAnimation.standard.usesCurl(scrolling: false, reduceMotion: false))
    }

    @Test func unavailableSnapshotStillNavigatesExactlyOnceWithoutEngineAnimation() async {
        let animator = ReaderPageTurnAnimator()
        var calls = 0
        let moved = await animator.turn(in: nil, forward: true) { animated in
            #expect(!animated)
            calls += 1
            return true
        }
        #expect(moved)
        #expect(calls == 1)
        #expect(!animator.isTurning)
    }

    @Test func aPendingTurnRejectsASecondCommandAndReleasesAfterFailure() async {
        let animator = ReaderPageTurnAnimator()
        var calls = 0
        let moved = await animator.turn(in: nil, forward: true) { _ in
            calls += 1
            let repeated = await animator.turn(in: nil, forward: false) { _ in
                calls += 1
                return true
            }
            #expect(!repeated)
            return false
        }
        #expect(!moved)
        #expect(calls == 1)
        #expect(!animator.isTurning)
        let next = await animator.turn(in: nil, forward: false) { _ in true }
        #expect(next)
    }

    @Test func aCancelledTurnDoesNotNavigate() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            var called = false
            let animator = ReaderPageTurnAnimator()
            let moved = await animator.turn(in: nil, forward: true) { _ in
                called = true
                return true
            }
            #expect(!moved)
            #expect(!called)
            #expect(!animator.isTurning)
        }
        await task.value
    }

    @Test func renderedTurnKeepsLiveContentMountedAndRemovesTransitionViews() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 500))
        let data = renderer.pdfData { context in
            for title in ["First page", "Second page"] {
                context.beginPage()
                (title as NSString).draw(at: CGPoint(x: 20, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
        }
        let document = try #require(PDFDocument(data: data))
        let reader = PDFReaderController(document: document, initialPageIndex: 0, scrollEnabled: false,
            layout: PDFReadingLayout(), onPageChange: { _ in }, onTap: { _, _ in })
        root.addChild(reader)
        let page = try #require(reader.view)
        page.frame = root.view.bounds
        root.view.addSubview(page)
        reader.didMove(toParent: root)
        root.view.layoutIfNeeded()
        let animator = ReaderPageTurnAnimator()
        for forward in [true, false] {
            let moved = await animator.turn(in: page, forward: forward) { animated in
                #expect(!animated)
                #expect(page.superview === root.view)
                reader.goToPage(forward ? 1 : 0)
                return true
            }
            #expect(moved)
            #expect(root.view.subviews == [page])
            #expect(reader.currentPageIndex() == (forward ? 1 : 0))
            #expect(reader.parent === root)
            #expect(!animator.isTurning)
        }
    }
}
