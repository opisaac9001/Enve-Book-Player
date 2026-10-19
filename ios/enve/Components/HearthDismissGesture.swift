#if os(iOS)
import SwiftUI
import UIKit

enum HearthDismissGestureStyle {
    /// A see-through full-screen cover that follows a downward pull or leading-edge swipe outside scroll views.
    case cover
    /// Dismisses only on a pull past the top of the screen's scroll view.
    case page
}

extension View {
    func hearthDismissGesture(
        _ style: HearthDismissGestureStyle,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        modifier(HearthDismissGesture(style: style, isEnabled: isEnabled, action: action))
    }

    /// Keeps the cover dismiss gesture from starting on a draggable control such as a scrubber.
    func hearthDismissGestureExclusion() -> some View {
        background(DismissGestureExclusion())
    }
}

private struct HearthDismissGesture: ViewModifier {
    let style: HearthDismissGestureStyle
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var offset: CGSize = .zero

    @ViewBuilder
    func body(content: Content) -> some View {
        if style == .cover {
            gestured(content)
                .presentationBackground(.clear)
        } else {
            gestured(content)
        }
    }

    private func gestured(_ content: Content) -> some View {
        content
            .offset(offset)
            .background {
                DismissGestureInstaller(
                    style: style,
                    isEnabled: isEnabled,
                    isRightToLeft: layoutDirection == .rightToLeft,
                    onDrag: { if !reduceMotion { offset = $0 } },
                    onEnd: finish
                )
            }
            // On a plain view the action lands on every descendant, turning static text into undersized targets.
            .accessibilityElement(children: .contain)
            .accessibilityAction(.escape) {
                if isEnabled { action() }
            }
    }

    private func finish(_ outcome: DismissGestureOutcome) {
        switch outcome {
        case .cancelled:
            withAnimation(.snappy) { offset = .zero }
        case .dismissed(let slideOut):
            guard let slideOut, !reduceMotion else {
                action()
                return
            }
            withAnimation(.smooth(duration: 0.25)) {
                offset = slideOut
            } completion: {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { action() }
            }
        }
    }
}

private enum DismissGestureOutcome {
    case cancelled
    case dismissed(slideOut: CGSize?)
}

private struct DismissGestureInstaller: UIViewRepresentable {
    let style: HearthDismissGestureStyle
    let isEnabled: Bool
    let isRightToLeft: Bool
    let onDrag: (CGSize) -> Void
    let onEnd: (DismissGestureOutcome) -> Void

    func makeCoordinator() -> DismissGestureCoordinator { DismissGestureCoordinator() }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.style = style
        coordinator.isEnabled = isEnabled
        coordinator.isRightToLeft = isRightToLeft
        coordinator.onDrag = onDrag
        coordinator.onEnd = onEnd
    }

    static func dismantleUIView(_ view: InstallerView, coordinator: DismissGestureCoordinator) {
        coordinator.uninstall()
    }

    final class InstallerView: UIView {
        weak var coordinator: DismissGestureCoordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController {
                    coordinator?.install(on: controller)
                    return
                }
                responder = current.next
            }
        }
    }
}

private final class DismissGestureCoordinator: NSObject, UIGestureRecognizerDelegate {
    private enum Mode { case pull, edge }

    var style: HearthDismissGestureStyle = .page
    var isEnabled = true
    var isRightToLeft = false
    var onDrag: (CGSize) -> Void = { _ in }
    var onEnd: (DismissGestureOutcome) -> Void = { _ in }

    private let edgeWidth: CGFloat = 24
    private let dragThreshold: CGFloat = 120
    private let overscrollThreshold: CGFloat = 80
    private let flickVelocity: CGFloat = 800

    private weak var host: UIView?
    private lazy var pan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        return pan
    }()
    private let observedScrollViews = NSHashTable<UIScrollView>.weakObjects()
    private var mode: Mode?
    private var touchStart: CGPoint = .zero
    private var touchInScrollView = false
    private var touchExcluded = false
    private var scrollArmed = false
    private var pastThreshold = false

    func install(on controller: UIViewController) {
        if style == .cover {
            var presented = controller
            while let parent = presented.parent { presented = parent }
            // The presenter stays on screen behind the see-through cover; keep VoiceOver out of it.
            if presented.presentingViewController != nil {
                presented.presentationController?.containerView?.accessibilityViewIsModal = true
            }
        }
        guard host !== controller.view else { return }
        uninstall()
        controller.view.addGestureRecognizer(pan)
        host = controller.view
    }

    func uninstall() {
        host?.removeGestureRecognizer(pan)
        host = nil
        for scrollView in observedScrollViews.allObjects {
            scrollView.panGestureRecognizer.removeTarget(self, action: #selector(handleScrollPan(_:)))
        }
        observedScrollViews.removeAllObjects()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let host, isEnabled else { return false }
        touchStart = touch.location(in: host)
        touchExcluded = isExcluded(touchStart, in: host)
        let scrollView = verticalScrollView(containing: touch.view, in: host)
        touchInScrollView = scrollView != nil
        if let scrollView, !observedScrollViews.contains(scrollView) {
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(handleScrollPan(_:)))
            observedScrollViews.add(scrollView)
        }
        guard style == .cover, !touchExcluded else { return false }
        return !touchInScrollView || isInLeadingEdge(touchStart, of: host)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let host, gestureRecognizer === pan else { return false }
        let translation = pan.translation(in: host)
        if isInLeadingEdge(touchStart, of: host), abs(translation.x) > abs(translation.y), trailingDistance(translation) > 0 {
            mode = .edge
            return true
        }
        if !touchInScrollView, translation.y > 0, translation.y > abs(translation.x) {
            mode = .pull
            return true
        }
        return false
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let host, let mode else { return }
        let translation = pan.translation(in: host)
        let distance = max(0, mode == .edge ? trailingDistance(translation) : translation.y)
        switch pan.state {
        case .began, .changed:
            onDrag(mode == .edge ? CGSize(width: distance, height: 0) : CGSize(width: 0, height: distance))
            notePastThreshold(distance >= dragThreshold)
        case .ended:
            let velocity = pan.velocity(in: host)
            let speed = mode == .edge ? trailingDistance(velocity) : velocity.y
            if distance >= dragThreshold || (speed >= flickVelocity && distance > 30) {
                let size = host.bounds.size
                onEnd(.dismissed(slideOut: mode == .edge ? CGSize(width: size.width, height: 0) : CGSize(width: 0, height: size.height)))
            } else {
                onEnd(.cancelled)
            }
            reset()
        default:
            onEnd(.cancelled)
            reset()
        }
    }

    @objc private func handleScrollPan(_ pan: UIPanGestureRecognizer) {
        guard let scrollView = pan.view as? UIScrollView else { return }
        let overscroll = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        switch pan.state {
        case .began:
            scrollArmed = isEnabled && !touchExcluded && overscroll >= -1
        case .changed:
            if scrollArmed { notePastThreshold(overscroll >= overscrollThreshold) }
        case .ended:
            let flicked = overscroll > 20 && pan.velocity(in: scrollView).y >= flickVelocity
            if scrollArmed, isEnabled, overscroll >= overscrollThreshold || flicked {
                onEnd(.dismissed(slideOut: nil))
            }
            scrollArmed = false
            pastThreshold = false
        default:
            scrollArmed = false
            pastThreshold = false
        }
    }

    private func reset() {
        mode = nil
        pastThreshold = false
    }

    private func notePastThreshold(_ isPast: Bool) {
        if isPast, !pastThreshold { PlatformHaptics.impact(.light) }
        pastThreshold = isPast
    }

    private func trailingDistance(_ point: CGPoint) -> CGFloat {
        isRightToLeft ? -point.x : point.x
    }

    private func isInLeadingEdge(_ point: CGPoint, of host: UIView) -> Bool {
        guard style == .cover else { return false }
        return isRightToLeft ? point.x >= host.bounds.width - edgeWidth : point.x <= edgeWidth
    }

    private func verticalScrollView(containing view: UIView?, in host: UIView) -> UIScrollView? {
        var current = view
        while let view = current, view !== host {
            if let scrollView = view as? UIScrollView,
                scrollView.alwaysBounceVertical || scrollView.contentSize.height > scrollView.bounds.height
            {
                return scrollView
            }
            current = view.superview
        }
        return nil
    }

    private func isExcluded(_ point: CGPoint, in host: UIView) -> Bool {
        var pending = host.subviews
        while let view = pending.popLast() {
            if view is DismissGestureExclusion.MarkerView, view.convert(view.bounds, to: host).contains(point) {
                return true
            }
            pending.append(contentsOf: view.subviews)
        }
        return false
    }
}

private struct DismissGestureExclusion: UIViewRepresentable {
    func makeUIView(context: Context) -> MarkerView { MarkerView() }
    func updateUIView(_ view: MarkerView, context: Context) {}

    final class MarkerView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }
    }
}
#endif
