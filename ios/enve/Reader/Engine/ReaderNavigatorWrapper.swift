import Foundation
@preconcurrency import ReadiumNavigator

@MainActor
final class ReaderNavigatorWrapper {
    func visiblePageRange(from viewport: NavigatorViewport?) -> ClosedRange<Int>? {
        viewport?.positions
    }
}
