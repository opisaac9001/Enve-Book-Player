import SwiftUI

struct HearthSpineShadow: View {
    enum Axis {
        case vertical
        case horizontal
    }

    var axis: Axis = .vertical
    var depth: Double = 0.5

    @Environment(\.hearth) private var hearth

    private let breadth: CGFloat = 84

    var body: some View {
        let shade = Color.black.opacity(hearth.isInk ? 0.6 : 0.3)
        let gradient = LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: shade.opacity(0.3 * depth), location: 0.4),
                .init(color: shade.opacity(0.85 * depth), location: 0.5),
                .init(color: shade.opacity(0.3 * depth), location: 0.6),
                .init(color: .clear, location: 1),
            ],
            startPoint: axis == .vertical ? .leading : .top,
            endPoint: axis == .vertical ? .trailing : .bottom
        )
        Rectangle()
            .fill(gradient)
            .frame(
                width: axis == .vertical ? breadth : nil,
                height: axis == .horizontal ? breadth : nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
