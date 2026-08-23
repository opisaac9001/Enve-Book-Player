import SwiftUI

func dedupCardBackground(_ hearth: HearthPalette) -> some View {
    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
        .fill(hearth.bgElevated)
        .overlay {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .strokeBorder(hearth.hairline, lineWidth: 1)
        }
}
