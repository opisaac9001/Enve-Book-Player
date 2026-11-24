#if os(iOS)
import UIKit

@MainActor
final class ReaderPageTurnAnimator {
    private(set) var isTurning = false

    func turn(in view: UIView?, forward: Bool, operation: (Bool) async -> Bool) async -> Bool {
        guard !isTurning, !Task.isCancelled else { return false }
        isTurning = true
        defer { isTurning = false }

        guard let view, view.window != nil, let parent = view.superview,
            !view.bounds.isEmpty,
            let before = view.snapshotView(afterScreenUpdates: false)
        else {
            return await operation(false)
        }

        // Keep the live renderer mounted so selection, locator and progress ownership do not change.
        let overlay = UIView(frame: view.convert(view.bounds, to: parent))
        overlay.accessibilityElementsHidden = true
        before.frame = overlay.bounds
        overlay.addSubview(before)
        parent.insertSubview(overlay, aboveSubview: view)
        defer { overlay.removeFromSuperview() }

        let moved = await operation(false)
        guard moved, !Task.isCancelled, !UIAccessibility.isReduceMotionEnabled,
            view.window != nil, view.superview === parent,
            view.convert(view.bounds, to: parent) == overlay.frame,
            let after = view.snapshotView(afterScreenUpdates: true)
        else { return moved }

        after.frame = overlay.bounds
        await withCheckedContinuation { continuation in
            UIView.transition(
                from: before,
                to: after,
                duration: 0.35,
                options: [forward ? .transitionCurlUp : .transitionCurlDown, .curveEaseInOut]
            ) { _ in
                continuation.resume()
            }
        }
        return moved
    }
}
#endif
