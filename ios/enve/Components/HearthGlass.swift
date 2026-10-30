import SwiftUI

enum HearthChromeShape {
    case capsule
    case circle
    case rounded(CGFloat)
}

struct HearthChromeBackground: View {
    var shape: HearthChromeShape
    var fill: Color
    var stroke: Color?
    var tint: Color?
    var interactive = true
    var shadow = false

    @Environment(\.hearth) private var hearth
    @Environment(\.shellNavigationStyle) private var shellNavigationStyle

    var body: some View {
        if shellNavigationStyle == .liquidGlass {
            liquidSurface
        } else {
            classicSurface
        }
    }

    @ViewBuilder
    private var classicSurface: some View {
        switch shape {
        case .capsule:
            Capsule().fill(fill).hearthOutlined(Capsule(), stroke: stroke, raised: shadow)
        case .circle:
            Circle().fill(fill).hearthOutlined(Circle(), stroke: stroke, raised: shadow)
        case .rounded(let radius):
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
                .hearthOutlined(RoundedRectangle(cornerRadius: radius, style: .continuous), stroke: stroke, raised: shadow)
        }
    }

    @ViewBuilder
    private var liquidSurface: some View {
        if #available(iOS 26.0, *) {
            switch shape {
            case .capsule:
                Capsule()
                    .fill(fill.opacity(liquidFillOpacity))
                    .overlay(Capsule().strokeBorder((stroke ?? hearth.hairline).opacity(0.65), lineWidth: 1))
                    .glassEffect(glass, in: .capsule)
                    .hearthChromeShadow(shadow, isInk: hearth.isInk)
            case .circle:
                Circle()
                    .fill(fill.opacity(liquidFillOpacity))
                    .overlay(Circle().strokeBorder((stroke ?? hearth.hairline).opacity(0.65), lineWidth: 1))
                    .glassEffect(glass, in: .circle)
                    .hearthChromeShadow(shadow, isInk: hearth.isInk)
            case .rounded(let radius):
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill.opacity(liquidFillOpacity))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder((stroke ?? hearth.hairline).opacity(0.65), lineWidth: 1)
                    }
                    .glassEffect(glass, in: .rect(cornerRadius: radius))
                    .hearthChromeShadow(shadow, isInk: hearth.isInk)
            }
        } else {
            fallbackLiquidSurface
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        let base = Glass.regular.tint((tint ?? fill).opacity(liquidTintOpacity))
        return interactive ? base.interactive() : base
    }

    private var liquidFillOpacity: Double {
        hearth.isInk ? 0.22 : 0.16
    }

    private var liquidTintOpacity: Double {
        hearth.isInk ? 0.38 : 0.22
    }

    @ViewBuilder
    private var fallbackLiquidSurface: some View {
        switch shape {
        case .capsule:
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(fill.opacity(0.12)))
                .overlay(Capsule().strokeBorder((stroke ?? hearth.hairline).opacity(0.75), lineWidth: 1))
                .hearthChromeShadow(shadow, isInk: hearth.isInk)
        case .circle:
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(fill.opacity(0.12)))
                .overlay(Circle().strokeBorder((stroke ?? hearth.hairline).opacity(0.75), lineWidth: 1))
                .hearthChromeShadow(shadow, isInk: hearth.isInk)
        case .rounded(let radius):
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(fill.opacity(0.12))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder((stroke ?? hearth.hairline).opacity(0.75), lineWidth: 1)
                }
                .hearthChromeShadow(shadow, isInk: hearth.isInk)
        }
    }
}

private struct HearthChromeShadow: ViewModifier {
    let enabled: Bool
    let isInk: Bool

    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(enabled ? (isInk ? 0.34 : 0.14) : 0), radius: enabled ? 14 : 0, y: enabled ? 5 : 0)
    }
}

private extension View {
    func hearthChromeShadow(_ enabled: Bool, isInk: Bool) -> some View {
        modifier(HearthChromeShadow(enabled: enabled, isInk: isInk))
    }
}

private struct HearthOutline<S: InsettableShape>: ViewModifier {
    let shape: S
    let stroke: Color?
    let raised: Bool

    @Environment(\.hearth) private var hearth

    @ViewBuilder
    func body(content: Content) -> some View {
        if hearth.decorated {
            content
                .overlay(shape.strokeBorder(inkStroke, lineWidth: 1.5))
                .background {
                    if raised {
                        shape.fill(hearth.wood)
                            .overlay(shape.strokeBorder(hearth.outline, lineWidth: 1.5))
                            .offset(y: 3)
                    }
                }
        } else {
            content
                .overlay(shape.strokeBorder(stroke ?? .clear, lineWidth: stroke == nil ? 0 : 1))
                .hearthChromeShadow(raised, isInk: hearth.isInk)
        }
    }

    // Neutral hairline strokes become the ink outline; state-driven accent strokes are kept.
    private var inkStroke: Color {
        guard let stroke, stroke != hearth.hairline else { return hearth.outline }
        return stroke
    }
}

extension View {
    func hearthOutlined<S: InsettableShape>(_ shape: S, stroke: Color? = nil, raised: Bool = false) -> some View {
        modifier(HearthOutline(shape: shape, stroke: stroke, raised: raised))
    }
}

private struct ShellNavigationStyleKey: EnvironmentKey {
    static let defaultValue: UserPreferences.ShellNavigationStyle = .classic
}

extension EnvironmentValues {
    var shellNavigationStyle: UserPreferences.ShellNavigationStyle {
        get { self[ShellNavigationStyleKey.self] }
        set { self[ShellNavigationStyleKey.self] = newValue }
    }
}

private struct HearthPresentationBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.presentationBackground {
            HearthPresentationBackground()
        }
    }
}

private struct HearthPresentationBackground: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.shellNavigationStyle) private var shellNavigationStyle

    var body: some View {
        if shellNavigationStyle == .liquidGlass {
            liquid
        } else {
            hearth.bgElevated
        }
    }

    @ViewBuilder
    private var liquid: some View {
        if #available(iOS 26.0, *) {
            Rectangle()
                .fill(hearth.bgElevated.opacity(0.24))
                .glassEffect(.regular.tint(hearth.bgElevated.opacity(0.32)), in: .rect(cornerRadius: 0))
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(hearth.bgElevated.opacity(0.18))
        }
    }
}

extension View {
    func hearthPresentationBackground() -> some View {
        modifier(HearthPresentationBackgroundModifier())
    }
}
