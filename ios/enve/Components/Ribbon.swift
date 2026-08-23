import SwiftUI

struct Ribbon: View {
    var progress: Double
    var tint: Color
    var ticks: [Double] = []
    var height: CGFloat = 3

    @Environment(\.hearth) private var hearth

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, geo.size.width * clamped))
                ForEach(ticks.filter { $0 > 0.005 && $0 < 0.995 }, id: \.self) { tick in
                    Rectangle()
                        .fill(hearth.bg.opacity(0.85))
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * tick)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }

    private var clamped: Double { min(max(progress, 0), 1) }

    private var trackColor: Color {
        hearth.isInk ? .white.opacity(0.14) : .black.opacity(0.10)
    }
}
