import CoreGraphics
import Testing

@testable import enve

@MainActor
struct ReaderAnnotationToolbarLayoutTests {
    @Test(arguments: [CGSize(width: 368, height: 800), CGSize(width: 420, height: 912), CGSize(width: 852, height: 393)])
    func lastLineSelectionLeavesBothToolbarsInsideTheViewport(_ size: CGSize) {
        let controls = CGRect(x: (size.width - 220) / 2, y: size.height - 110, width: 220, height: 42)
        let selection = CGRect(x: size.width - 60, y: size.height - 20, width: 40, height: 18)
        let unreserved = ReaderAnnotationToolbarLayout.position(for: selection, in: size, narrationBounds: nil)
        #expect(unreserved.y + ReaderAnnotationToolbarLayout.barHeight / 2 > controls.minY)

        let position = ReaderAnnotationToolbarLayout.position(for: selection, in: size, narrationBounds: controls)
        let annotation = CGRect(
            x: 0, y: position.y - ReaderAnnotationToolbarLayout.barHeight / 2,
            width: size.width, height: ReaderAnnotationToolbarLayout.barHeight
        )
        #expect(annotation.minY >= 0)
        #expect(annotation.maxY + 10 <= controls.minY)
        #expect(!annotation.intersects(controls))
        #expect(controls.maxY <= size.height)
    }

    @Test func upperPageSelectionKeepsItsOriginalPosition() {
        let size = CGSize(width: 420, height: 912)
        let selection = CGRect(x: 30, y: 200, width: 90, height: 20)
        let controls = CGRect(x: 100, y: 800, width: 220, height: 42)
        let original = ReaderAnnotationToolbarLayout.position(for: selection, in: size, narrationBounds: nil)
        #expect(ReaderAnnotationToolbarLayout.position(for: selection, in: size, narrationBounds: controls) == original)
    }

    @Test func missingSelectionFrameStillRespectsMeasuredControls() {
        let size = CGSize(width: 420, height: 912)
        let controls = CGRect(x: 100, y: 740, width: 220, height: 42)
        for frame in [nil, CGRect.zero] {
            let position = ReaderAnnotationToolbarLayout.position(for: frame, in: size, narrationBounds: controls)
            #expect(position.y + ReaderAnnotationToolbarLayout.barHeight / 2 + 10 <= controls.minY)
        }
    }
}
