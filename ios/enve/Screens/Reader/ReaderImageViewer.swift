#if os(iOS)
import SwiftUI
import UIKit

struct ReaderImageViewer: View {
    let illustration: ReaderIllustration
    let backdrop: Color
    let onDismiss: () -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()
            ReaderZoomableImage(
                image: illustration.image,
                backing: illustration.hasTransparency ? .white : nil,
                animatesZoom: !reduceMotion,
                onDismiss: onDismiss
            )
            .ignoresSafeArea()
            .accessibilityElement()
            .accessibilityLabel(illustration.alt ?? "Illustration")
            .accessibilityAddTraits(.isImage)
            .accessibilityHint("Pinch to zoom. Double tap to zoom in or out.")
            .accessibilityIdentifier("reader-image-viewer")
        }
        .overlay(alignment: .topTrailing) {
            GlyphButton(systemImage: "xmark", label: "Close", action: onDismiss)
                .compositingGroup()
                .padding(.top, 12)
                .padding(.trailing, 20)
                .accessibilityIdentifier("reader-image-viewer-close")
        }
        .overlay(alignment: .bottom) {
            if let subtitle = illustration.subtitle {
                Text(subtitle)
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 6 : 3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background {
                        HearthChromeBackground(
                            shape: .rounded(14),
                            fill: hearth.bgElevated,
                            stroke: hearth.hairline,
                            tint: hearth.bgElevated,
                            interactive: false,
                            shadow: true
                        )
                    }
                    .compositingGroup()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
        }
        .accessibilityAction(.escape, onDismiss)
        .statusBarHidden()
    }
}

private struct ReaderZoomableImage: UIViewRepresentable {
    let image: UIImage
    let backing: UIColor?
    let animatesZoom: Bool
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss, animatesZoom: animatesZoom)
    }

    func makeUIView(context: Context) -> ReaderZoomScrollView {
        let coordinator = context.coordinator
        let scrollView = ReaderZoomScrollView()
        scrollView.delegate = coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = backing
        imageView.isAccessibilityElement = false
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
        return scrollView
    }

    func updateUIView(_ scrollView: ReaderZoomScrollView, context: Context) {
        context.coordinator.onDismiss = onDismiss
        context.coordinator.animatesZoom = animatesZoom
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        private static let dismissTravel: CGFloat = 90
        private static let doubleTapScale: CGFloat = 2.5

        var onDismiss: () -> Void
        var animatesZoom: Bool
        weak var imageView: UIImageView?
        weak var scrollView: ReaderZoomScrollView?

        init(onDismiss: @escaping () -> Void, animatesZoom: Bool) {
            self.onDismiss = onDismiss
            self.animatesZoom = animatesZoom
        }

        private var isAtFit: Bool {
            guard let scrollView else { return true }
            return scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
        }

        func layoutImage() {
            guard let scrollView, let imageView, let image = imageView.image else { return }
            let bounds = scrollView.bounds.size
            guard bounds.width > 0, bounds.height > 0, image.size.width > 0, image.size.height > 0 else { return }
            let fitScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let fitted = CGSize(width: image.size.width * fitScale, height: image.size.height * fitScale)
            scrollView.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: fitted)
            scrollView.contentSize = fitted
            centerImage()
        }

        private func centerImage() {
            guard let scrollView, let imageView else { return }
            let bounds = scrollView.bounds.size
            let width = imageView.bounds.width * scrollView.zoomScale
            let height = imageView.bounds.height * scrollView.zoomScale
            let x = max((bounds.width - width) / 2, 0)
            let y = max((bounds.height - height) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard isAtFit, scrollView.contentOffset.y < -scrollView.contentInset.top - Self.dismissTravel else { return }
            onDismiss()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView, let imageView else { return }
            if isAtFit {
                let point = gesture.location(in: imageView)
                let width = scrollView.bounds.width / Self.doubleTapScale
                let height = scrollView.bounds.height / Self.doubleTapScale
                scrollView.zoom(
                    to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height),
                    animated: animatesZoom
                )
            } else {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animatesZoom)
            }
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard isAtFit else { return }
            onDismiss()
        }
    }
}

final class ReaderZoomScrollView: UIScrollView {
    var onBoundsChange: (() -> Void)?
    private var lastBoundsSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            onBoundsChange?()
        }
    }
}
#endif
