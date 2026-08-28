import SwiftUI

struct EmberButton: View {
    let title: String
    var systemImage: String?
    var tint: Color?
    let action: () -> Void

    @Environment(\.hearth) private var hearth

    private var foreground: Color {
        HearthPalette.readableForeground(on: tint ?? hearth.ember, dark: hearth.onEmber)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.hearthUI(15, weight: .semibold))
                }
                Text(title)
                    .font(.hearthUI(16, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(minHeight: 52)
            .background {
                HearthChromeBackground(
                    shape: .capsule,
                    fill: tint ?? hearth.ember,
                    tint: tint ?? hearth.ember
                )
            }
        }
        .buttonStyle(PressableStyle())
    }
}

struct QuietButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.hearthUI(14, weight: .medium))
                }
                Text(title)
                    .font(.hearthUI(15, weight: .medium))
            }
            .foregroundStyle(hearth.text)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .background {
                HearthChromeBackground(
                    shape: .capsule,
                    fill: hearth.bgElevated,
                    stroke: hearth.hairline,
                    tint: hearth.bgElevated
                )
            }
        }
        .buttonStyle(PressableStyle())
    }
}

struct HearthChip: View {
    let title: String
    var isSelected: Bool
    let action: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.hearthUI(14, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? hearth.readableOnEmber : hearth.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    if isSelected {
                        HearthChromeBackground(
                            shape: .capsule,
                            fill: hearth.ember,
                            tint: hearth.ember
                        )
                    } else {
                        HearthChromeBackground(
                            shape: .capsule,
                            fill: hearth.bgElevated,
                            stroke: hearth.hairline,
                            tint: hearth.bgElevated
                        )
                    }
                }
        }
        .buttonStyle(PressableStyle())
        .frame(minHeight: 44)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

struct ShelfHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Overline(title)
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.hearthUI(13, weight: .medium))
                        .foregroundStyle(hearth.ember)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 24)
    }
}

struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.96)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: configuration.isPressed)
    }
}

struct GlyphButton: View {
    let systemImage: String
    var size: CGFloat = 44
    var glyphSize: CGFloat = 17
    var prominent = false
    var label: String? = nil
    let action: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.hearthUI(glyphSize, weight: .semibold))
                .foregroundStyle(prominent ? hearth.readableOnEmber : hearth.text)
                .frame(width: size, height: size)
                .background {
                    if prominent {
                        HearthChromeBackground(
                            shape: .circle,
                            fill: hearth.ember,
                            tint: hearth.ember
                        )
                    } else {
                        HearthChromeBackground(
                            shape: .circle,
                            fill: hearth.bgElevated,
                            stroke: hearth.hairline,
                            tint: hearth.bgElevated
                        )
                    }
                }
        }
        .buttonStyle(PressableStyle())
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(label ?? systemImage)
    }
}

struct HearthEmpty: View {
    let glyph: String
    let title: String
    var line: String?
    var actionTitle: String?
    var action: (() -> Void)?

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: glyph)
                .font(.system(size: Hearth.scaled(30)))
                .foregroundStyle(hearth.textTertiary)
            Text(title)
                .font(.hearthDisplay(20))
                .foregroundStyle(hearth.text)
                .multilineTextAlignment(.center)
            if let line {
                Text(line)
                    .font(.hearthUI(14))
                    .foregroundStyle(hearth.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                QuietButton(title: actionTitle, action: action)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .padding(.horizontal, 32)
    }
}

enum HearthFormat {

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func remaining(_ seconds: TimeInterval, speed: Double = 1.0) -> String {
        let adjusted = speed > 0 ? seconds / speed : seconds
        return duration(adjusted) + " left"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    static func greeting(now: Date = .now) -> String {
        let weekday = now.formatted(.dateTime.weekday(.wide))
        let hour = Calendar.current.component(.hour, from: now)
        let part: String
        switch hour {
        case 5..<12: part = "morning"
        case 12..<17: part = "afternoon"
        case 17..<22: part = "evening"
        case 22...23: part = "night"
        default: part = "late night"
        }
        return "\(weekday) \(part)"
    }
}

private struct HearthBackBar: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                GlyphButton(systemImage: "chevron.left", label: "Back") { dismiss() }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .navigationBarBackButtonHidden(true)
    }
}

extension View {
    func hearthBackBar() -> some View {
        modifier(HearthBackBar())
    }
}

struct HearthMarqueeText: View {
    let text: String
    var size: CGFloat
    var weight: Font.Weight = .semibold
    var serif: Bool = true
    var color: Color
    var height: CGFloat
    private let gap: CGFloat = 34

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var displayFont: Font {
        serif
            ? .system(size: Hearth.scaled(size), weight: weight, design: .serif)
            : .system(size: Hearth.scaled(size), weight: weight)
    }

    private var textWidth: CGFloat {
        let scaled = Hearth.scaled(size)
        var uiFont = UIFont.systemFont(ofSize: scaled, weight: weight.uiKitWeight)
        if serif, let descriptor = uiFont.fontDescriptor.withDesign(.serif) {
            uiFont = UIFont(descriptor: descriptor, size: scaled)
        }
        return (text as NSString).size(withAttributes: [.font: uiFont]).width
    }

    private var scrolls: Bool { textWidth > containerWidth + 1 && !reduceMotion }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(alignment: .leading) {
                if scrolls {
                    HStack(spacing: gap) {
                        line
                        line
                    }
                    .offset(x: offset)
                } else {
                    line.truncationMode(.tail)
                }
            }
            .clipped()
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear {
                            containerWidth = g.size.width; restart()
                        }
                        .onChange(of: g.size.width) { _, w in
                            containerWidth = w; restart()
                    }
                }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .onChange(of: text) { _, _ in
                offset = 0; restart()
            }
    }

    private var line: some View {
        Text(text)
            .font(displayFont)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    private func restart() {
        offset = 0
        guard scrolls else { return }
        withAnimation(.linear(duration: Double(textWidth + gap) / 32).repeatForever(autoreverses: false)) {
            offset = -(textWidth + gap)
        }
    }
}

private extension Font.Weight {
    var uiKitWeight: UIFont.Weight {
        switch self {
        case .bold: .bold
        case .semibold: .semibold
        case .medium: .medium
        case .light: .light
        case .heavy: .heavy
        case .black: .black
        case .thin: .thin
        default: .regular
        }
    }
}
