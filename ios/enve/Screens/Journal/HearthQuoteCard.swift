import SwiftUI
import UIKit

struct HearthQuoteCard: View {
    let quote: String
    let title: String
    let author: String?
    let attribution: String?
    let tint: Color

    static let size = CGSize(width: 360, height: 450)

    private let ink = Color(hexValue: 0x0C0A09)
    private let cream = Color(hexValue: 0xF0E9DC)
    private let dim = Color(hexValue: 0xA99F92)

    private var trimmed: String {
        let t = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 320 ? String(t.prefix(319)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" : t
    }

    private var quoteFontSize: CGFloat {
        switch trimmed.count {
        case ..<90: 24
        case ..<170: 20
        case ..<250: 17
        default: 15
        }
    }

    var body: some View {
        ZStack {
            ink

            RadialGradient(
                colors: [tint.opacity(0.42), tint.opacity(0.10), .clear],
                center: UnitPoint(x: 0.5, y: 0.86),
                startRadius: 6,
                endRadius: 300
            )
            LinearGradient(
                colors: [tint.opacity(0.10), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )

            VStack(alignment: .leading, spacing: 0) {
                Text("\u{201C}")
                    .font(.system(size: 96, weight: .bold, design: .serif))
                    .foregroundStyle(tint)
                    .frame(height: 58, alignment: .top)
                    .offset(x: -4)

                Spacer(minLength: 14)

                Text(trimmed)
                    .font(.system(size: quoteFontSize, weight: .medium, design: .serif))
                    .foregroundStyle(cream)
                    .lineSpacing(quoteFontSize * 0.32)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 18)

                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(tint)
                    .frame(width: 34, height: 2)
                    .padding(.bottom, 14)

                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(cream)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let line = secondaryLine {
                    Text(line)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(dim)
                        .lineLimit(1)
                        .padding(.top, 2)
                }

                Spacer(minLength: 22)

                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                    Text("Enve")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(cream.opacity(0.9))
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 38)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var secondaryLine: String? {

        switch (author, attribution) {
        case let (a?, c?) where !a.isEmpty && !c.isEmpty && c != title:
            return "\(a) · \(c)"
        case let (a?, _) where !a.isEmpty:
            return a
        case let (_, c?) where !c.isEmpty && c != title:
            return c
        default:
            return nil
        }
    }
}

struct QuoteCardSheet: View {
    let quote: String
    let book: Book
    let attribution: String?

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var tint: Color = Hearth.accent
    @State private var shareImage: ShareableImage?
    @State private var rendering = false

    var body: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(hearth.hairline)
                .frame(width: 36, height: 5)
                .padding(.top, 10)

            Spacer(minLength: 0)

            GeometryReader { geo in
                let scale = min(
                    geo.size.width / HearthQuoteCard.size.width,
                    geo.size.height / HearthQuoteCard.size.height
                )
                card
                    .scaleEffect(scale)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(maxHeight: 470)

            Spacer(minLength: 0)

            EmberButton(title: rendering ? "Preparing…" : "Share this card", systemImage: "square.and.arrow.up") {
                shareCard()
            }
            .disabled(rendering)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(hearth.bg)
        .hearthPresentationBackground()
        .task { tint = await AmbientColorStore.shared.resolve(for: book) }
        .sheet(item: $shareImage) { payload in
            ActivityShareSheet(items: [payload.image])
                .presentationDetents([.medium, .large])
        }
    }

    private var card: HearthQuoteCard {
        HearthQuoteCard(
            quote: quote,
            title: book.title,
            author: book.author,
            attribution: attribution,
            tint: tint
        )
    }

    @MainActor
    private func shareCard() {
        rendering = true
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        if let image = renderer.uiImage {
            shareImage = ShareableImage(image: image)
        }
        rendering = false
    }
}

struct QuoteCardRequest: Identifiable {
    let text: String
    let book: Book
    let attribution: String?
    var id: String { text + book.stableId }
}

private struct ShareableImage: Identifiable {
    let image: UIImage
    let id = UUID()
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
