import SwiftUI

struct CoverImage: View {
    let colorName: String
    var cornerRadius: CGFloat = 8

    @ObservedObject private var themeManager = ThemeManager.shared

    private var color: Color {
        switch colorName.lowercased() {
        case "green": return .green
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "teal": return .teal
        case "indigo": return .indigo
        case "pink": return .pink
        default: return themeManager.themeColor
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [color, color.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "book.fill")
                .font(.largeTitle)
                .foregroundColor(.white.opacity(0.8))
        }
        .cornerRadius(cornerRadius)
    }
}

#Preview("Cover Images") {
    HStack(spacing: 16) {
        CoverImage(colorName: "blue")
            .frame(width: 100, height: 100)
        CoverImage(colorName: "green")
            .frame(width: 100, height: 100)
        CoverImage(colorName: "purple")
            .frame(width: 100, height: 100)
    }
    .padding()
}
