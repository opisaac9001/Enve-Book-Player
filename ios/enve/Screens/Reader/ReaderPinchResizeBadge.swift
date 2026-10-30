#if os(iOS)
import SwiftUI

struct ReaderPinchResizeBadge: View {
    let fontSize: Double

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 8) {
            Text("Aa")
                .font(.hearthDisplay(15, weight: .semibold))
            Text(ReaderPinchResize.percentLabel(fontSize))
                .font(.hearthUI(14, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(hearth.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            HearthChromeBackground(
                shape: .capsule,
                fill: hearth.bgElevated,
                stroke: hearth.hairline,
                tint: hearth.bgElevated,
                interactive: false,
                shadow: true
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Text size \(ReaderPinchResize.percentLabel(fontSize))")
        .accessibilityIdentifier("reader-pinch-resize-badge")
    }
}
#endif
