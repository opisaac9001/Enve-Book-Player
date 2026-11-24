#if os(iOS)
import SwiftUI

// The export uses a fixed canvas and type size; covers are not loaded during rendering.
struct JournalRecapCard: View {
    let title: String
    let context: String?
    let activity: JournalPeriodActivity
    let tint: Color

    static let size = CGSize(width: 360, height: 480)

    private let palette = Hearth.palette(for: .dark)

    var body: some View {
        ZStack {
            palette.bg

            RadialGradient(
                colors: [tint.opacity(0.36), tint.opacity(0.08), .clear],
                center: UnitPoint(x: 0.2, y: 0.0),
                startRadius: 6,
                endRadius: 340
            )

            VStack(alignment: .leading, spacing: 0) {
                Text("READING RECAP")
                    .font(.hearthUI(11, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(palette.textSecondary)

                Text(title)
                    .font(.hearthDisplay(30, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 6)

                if let context {
                    Text(context)
                        .font(.hearthUI(12))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .padding(.top, 4)
                }

                Text(HearthFormat.duration(activity.totalSeconds))
                    .font(.hearthDisplay(50, weight: .regular))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 24)
                Text("reading & listening")
                    .font(.hearthUI(13, weight: .medium))
                    .foregroundStyle(palette.textSecondary)

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                    GridRow {
                        figure(HearthFormat.duration(activity.listeningSeconds), "Listening")
                        figure(HearthFormat.duration(activity.readingSeconds), "Reading")
                    }
                    GridRow {
                        figure(activity.activeDays.formatted(), "Active days")
                        figure(activity.sessions.formatted(), "Sessions")
                    }
                }
                .padding(.top, 22)

                Spacer(minLength: 16)

                VStack(alignment: .leading, spacing: 8) {
                    if let book = activity.topBook?.book {
                        leader("Top title", book.title)
                    }
                    if let author = activity.topAuthor {
                        leader("Top author", author.name)
                    }
                    if let narrator = activity.topNarrator {
                        leader("Top narrator", narrator.name)
                    }
                }

                Spacer(minLength: 16)

                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.hearthUI(13, weight: .semibold))
                        .foregroundStyle(tint)
                    Text("Enve")
                        .font(.hearthDisplay(15, weight: .semibold))
                        .foregroundStyle(palette.text.opacity(0.9))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 34)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.dynamicTypeSize, .large)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.hearthDisplay(20, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(.hearthUI(10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(palette.textSecondary)
        }
    }

    private func leader(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.uppercased())
                .font(.hearthUI(10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(palette.textSecondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.hearthDisplay(14, weight: .medium))
                .foregroundStyle(palette.text)
                .lineLimit(1)
        }
    }
}
#endif
