import SwiftUI

struct HearthWidgetPalette {
    let background: Color
    let elevated: Color
    let text: Color
    let secondary: Color
    let ember: Color
    let onEmber: Color
    let hairline: Color

    static func resolve(_ scheme: ColorScheme) -> HearthWidgetPalette {
        if scheme == .light {
            return HearthWidgetPalette(
                background: Color(hex: 0xF7F2E9),
                elevated: .white,
                text: Color(hex: 0x241C15),
                secondary: Color(hex: 0x71675C),
                ember: Color(hex: 0xF5921A),
                onEmber: Color(hex: 0x1A120A),
                hairline: .black.opacity(0.08)
            )
        }
        return HearthWidgetPalette(
            background: Color(hex: 0x0C0A09),
            elevated: Color(hex: 0x191512),
            text: Color(hex: 0xF0E9DC),
            secondary: Color(hex: 0xA99F92),
            ember: Color(hex: 0xF5921A),
            onEmber: Color(hex: 0x1A120A),
            hairline: .white.opacity(0.08)
        )
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
