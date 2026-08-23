import SwiftUI

struct HardcoverCard<Content: View>: View {
    let content: Content
    @Environment(\.hearth) private var hearth

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
            }
    }
}

struct HardcoverCoverThumb: View {
    var urlString: String?
    var width: CGFloat = 46

    @Environment(\.hearth) private var hearth

    var body: some View {
        CachedAsyncCoverImage(url: urlString.flatMap { URL(string: $0) }, fallbackColor: "Blue")
            .aspectRatio(2 / 3, contentMode: .fill)
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(hearth.hairline, lineWidth: 1)
            }
    }
}

struct HardcoverAvatar: View {
    var urlString: String?
    let name: String
    var size: CGFloat = 42

    @Environment(\.hearth) private var hearth

    var body: some View {
        Group {
            if let url = urlString.flatMap({ URL(string: $0) }) {
                CachedAsyncCoverImage(url: url, fallbackColor: "Blue")
                    .aspectRatio(1, contentMode: .fill)
            } else {
                hearth.emberSoft
                    .overlay {
                        Text(String(name.prefix(1)).uppercased())
                            .font(.hearthDisplay(size * 0.42, weight: .semibold))
                            .foregroundStyle(hearth.ember)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
    }
}

struct HardcoverStars: View {
    let rating: Double
    var size: CGFloat = 11

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: glyph(for: i))
                    .font(.hearthUI(size))
                    .foregroundStyle(hearth.ember)
            }
        }
        .accessibilityLabel("Rated \(String(format: "%.1f", rating)) of five")
    }

    private func glyph(for position: Int) -> String {
        if Double(position) <= rating { return "star.fill" }
        if Double(position) - 0.5 <= rating { return "star.leadinghalf.filled" }
        return "star"
    }
}

struct HardcoverStatusChip: View {
    let status: HardcoverReadingStatus

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.iconName)
                .font(.hearthUI(10, weight: .semibold))
            Text(status.displayName)
                .font(.hearthUI(11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(tint.opacity(0.12))
                .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1))
        }
    }

    private var tint: Color {
        switch status {
        case .currentlyReading: hearth.ember
        case .finished: hearth.statusOK
        case .wantToRead: hearth.statusWarn
        case .didNotFinish: hearth.textTertiary
        }
    }
}

struct HardcoverSearchField: View {
    @Binding var text: String
    let placeholder: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.hearthUI(15, weight: .medium))
                .foregroundStyle(hearth.textTertiary)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.hearthDisplay(17, weight: .regular))
                        .italic()
                        .foregroundStyle(hearth.textTertiary)
                }
                TextField("", text: $text)
                    .font(.hearthDisplay(17, weight: .regular))
                    .foregroundStyle(hearth.text)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.hearthUI(15))
                        .foregroundStyle(hearth.textTertiary)
                        .contentShape(Rectangle().inset(by: -14))
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
        }
    }
}

struct HardcoverLoading: View {
    var line = "A moment."

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(hearth.ember)
            Text(line)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }
}

struct HardcoverEmpty: View {
    let glyph: String
    let title: String
    var line: String?

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: glyph)
                .font(.hearthUI(30))
                .foregroundStyle(hearth.textTertiary)
            Text(title)
                .font(.hearthDisplay(18, weight: .semibold))
                .foregroundStyle(hearth.text)
                .multilineTextAlignment(.center)
            if let line {
                Text(line)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 32)
    }
}

struct HardcoverScreenHeader: View {
    let overline: String
    let title: String
    var line: String?

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") { dismiss() }
            VStack(alignment: .leading, spacing: 6) {
                Overline(overline)
                Text(title)
                    .font(.hearthScreenTitle)
                    .foregroundStyle(hearth.text)
                if let line {
                    Text(line)
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }
}
