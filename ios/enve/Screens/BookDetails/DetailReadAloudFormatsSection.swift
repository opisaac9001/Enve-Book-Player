import SwiftUI

struct DetailReadAloudFormatsSection: View {
    let book: Book
    let linkedAudiobook: Book?
    let tint: Color

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    @State private var sourceEbook: Book?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Formats")
            VStack(spacing: 2) {
                if let ebook = sourceEbook {
                    row(
                        glyph: "book",
                        label: "Ebook",
                        subtitle: sourceName(ebook),
                        progress: ebook.canonicalEbookProgress
                    )
                }
                if let audiobook = linkedAudiobook {
                    row(
                        glyph: "headphones",
                        label: "Audiobook",
                        subtitle: sourceName(audiobook),
                        progress: audioFraction(audiobook)
                    )
                }
                row(
                    glyph: "waveform",
                    label: "Read aloud",
                    subtitle: "StoryAlign",
                    progress: book.canonicalEbookProgress,
                    isCurrent: true
                )
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    )
            }
            .padding(.horizontal, 24)
        }
        .task(id: book.readAloudSourceStableId) {
            guard let stableId = book.readAloudSourceStableId else {
                sourceEbook = nil
                return
            }
            sourceEbook = await engine.library.readAloudSourceBook(stableId: stableId)
        }
    }

    private func sourceName(_ book: Book) -> String {
        book.backendName ?? book.source.rawValue.capitalized
    }

    private func audioFraction(_ book: Book) -> Double {
        guard let duration = book.duration, duration > 0 else { return 0 }
        return min(max(book.currentTime / duration, 0), 1)
    }

    private func row(glyph: String, label: String, subtitle: String, progress: Double, isCurrent: Bool = false) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isCurrent ? tint.opacity(0.16) : hearth.emberSoft)
                    .frame(width: 34, height: 34)
                Image(systemName: glyph)
                    .font(.hearthUI(14, weight: .semibold))
                    .foregroundStyle(isCurrent ? tint : hearth.textSecondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(label)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                    if isCurrent {
                        Text("Current")
                            .font(.hearthUI(10, weight: .semibold))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.14), in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.hearthUI(12))
                    .foregroundStyle(hearth.textTertiary)
            }

            Spacer(minLength: 8)

            if progress > 0.001 {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.hearthUI(13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isCurrent ? tint : hearth.textSecondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }
}
