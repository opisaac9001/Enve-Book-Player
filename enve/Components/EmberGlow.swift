import SwiftUI

struct EmberGlow: View {
    var tint: Color
    var isBreathing: Bool
    var intensity: Double = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        GeometryReader { geo in
            let base = max(geo.size.width, geo.size.height)
            ZStack {
                RadialGradient(
                    colors: [tint.opacity(0.38 * intensity), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: base * (phase ? 0.62 : 0.55)
                )
                RadialGradient(
                    colors: [tint.opacity(0.18 * intensity), .clear],
                    center: .center,
                    startRadius: base * 0.1,
                    endRadius: base * (phase ? 0.95 : 0.85)
                )
            }
            .scaleEffect(phase ? 1.04 : 1.0)
            .animation(
                shouldAnimate ? .easeInOut(duration: 3.6).repeatForever(autoreverses: true) : .default,
                value: phase
            )
            .onAppear { if shouldAnimate { phase = true } }
            .onChange(of: isBreathing) { _, breathing in
                if breathing && !reduceMotion {
                    phase = true
                } else {
                    withAnimation(.easeOut(duration: 1.2)) { phase = false }
                }
            }
        }
        .allowsHitTesting(false)
        .drawingGroup()
    }

    private var shouldAnimate: Bool {
        isBreathing && !reduceMotion
    }
}
