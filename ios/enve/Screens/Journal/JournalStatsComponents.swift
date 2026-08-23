import SwiftUI

struct JournalCard<Content: View>: View {
    private let title: String?
    private let content: Content

    @Environment(\.hearth) private var hearth

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Overline(title)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                )
        }
    }
}

struct JournalScreenHeader: View {
    let overline: String
    let title: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Overline(overline)
            Text(title)
                .font(.hearthScreenTitle)
                .foregroundStyle(hearth.text)
        }
    }
}

struct JournalLinkRow: View {
    let glyph: String
    let title: String
    let subtitle: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: glyph)
                .font(.hearthUI(16, weight: .medium))
                .foregroundStyle(hearth.ember)
                .frame(width: 44, height: 44)
                .background {
                    Circle()
                        .fill(hearth.bgElevated)
                        .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.hearthUI(16, weight: .medium))
                    .foregroundStyle(hearth.text)
                Text(subtitle)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.hearthUI(12, weight: .semibold))
                .foregroundStyle(hearth.textTertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct JournalQuietNote: View {
    let text: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        Text(text)
            .font(.hearthBody)
            .foregroundStyle(hearth.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct JournalLoadingNote: View {
    let text: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(hearth.ember)
            Text(text)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
    }
}

struct JournalStatTile: View {
    let value: String
    let label: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.hearthDisplay(22, weight: .semibold))
                .foregroundStyle(hearth.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Overline(label, color: hearth.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct JournalAllTimeFigure: View {
    let seconds: TimeInterval

    @Environment(\.hearth) private var hearth

    var body: some View {
        let months = Int(seconds / (86400 * 30))
        let days = Int((seconds / 86400).truncatingRemainder(dividingBy: 30))
        let hours = Int((seconds / 3600).truncatingRemainder(dividingBy: 24))
        let minutes = Int((seconds / 60).truncatingRemainder(dividingBy: 60))
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if months > 0 {
                journalPart(months, "mo")
            }
            if months > 0 || days > 0 {
                journalPart(days, "d")
            }
            if months > 0 || days > 0 || hours > 0 {
                journalPart(hours, "h")
            } else {
                journalPart(minutes, "m")
            }
        }
    }

    private func journalPart(_ value: Int, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(value)")
                .font(.hearthDisplay(40))
                .foregroundStyle(hearth.text)
            Text(unit)
                .font(.hearthUI(15, weight: .semibold))
                .foregroundStyle(hearth.textSecondary)
        }
    }
}

struct JournalLevelCard: View {
    let level: Int
    let rank: String
    let totalXP: Int
    let xpIntoLevel: Int
    let xpForNextLevel: Int
    let progress: Double

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Level \(level)")
                    .font(.hearthDisplay(22, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Text(rank)
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.ember)
                Spacer()
                Text("\(totalXP) XP")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
            Ribbon(progress: progress, tint: hearth.ember, height: 5)
            Text("\(xpIntoLevel) of \(xpForNextLevel) toward level \(level + 1)")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
        }
    }
}

struct JournalGoalRing: View {
    let fraction: Double
    let centerValue: String
    let centerUnit: String
    var size: CGFloat = 92

    @Environment(\.hearth) private var hearth

    var body: some View {
        ZStack {
            Circle()
                .stroke(journalTrack, lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(
                    fraction >= 1 ? hearth.statusOK : hearth.ember,
                    style: StrokeStyle(lineWidth: 9, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(centerValue)
                    .font(.hearthDisplay(22, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Text(centerUnit)
                    .font(.hearthUI(11))
                    .foregroundStyle(hearth.textSecondary)
            }
        }
        .frame(width: size, height: size)
    }

    private var journalTrack: Color {
        hearth.isInk ? .white.opacity(0.14) : .black.opacity(0.10)
    }
}

struct JournalMeterRow: View {
    var rank: Int? = nil
    let label: String
    let detail: String
    let fraction: Double
    var tint: Color? = nil

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let rank {
                Text("\(rank)")
                    .font(.hearthDisplay(15, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
                    .frame(width: 22, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    Spacer()
                    Text(detail)
                        .font(.hearthUI(13, weight: .semibold))
                        .foregroundStyle(tint ?? hearth.textSecondary)
                }
                Ribbon(progress: fraction, tint: tint ?? hearth.ember, height: 4)
            }
        }
    }
}

struct JournalColumns: View {
    let columns: [(label: String, value: Double)]
    var height: CGFloat = 110

    @Environment(\.hearth) private var hearth

    var body: some View {
        let peak = max(columns.map(\.value).max() ?? 0, 0.001)
        let spacing: CGFloat = columns.count > 14 ? 2 : 4
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    Capsule(style: .continuous)
                        .fill(column.value > 0 ? hearth.ember : hearth.emberSoft)
                        .frame(height: max(3, height * column.value / peak))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack(spacing: spacing) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    Text(column.label)
                        .font(.hearthUI(10))
                        .foregroundStyle(hearth.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct JournalSparkColumns: View {
    let values: [Double]
    var height: CGFloat = 56

    @Environment(\.hearth) private var hearth

    var body: some View {
        let ember = hearth.ember
        Canvas { context, size in
            let peak = max(values.max() ?? 0, 0.001)
            let slot = size.width / CGFloat(max(values.count, 1))
            let barWidth = max(slot * 0.66, 0.75)
            for (index, value) in values.enumerated() where value > 0 {
                let barHeight = max(size.height * value / peak, 1.5)
                let rect = CGRect(
                    x: CGFloat(index) * slot,
                    y: size.height - barHeight,
                    width: barWidth,
                    height: barHeight
                )
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 3), with: .color(ember))
            }
        }
        .frame(height: height)
    }
}

struct JournalBadgeChip: View {
    let badge: JournalBadge

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: badge.systemImage)
                .font(.hearthUI(12))
                .foregroundStyle(hearth.ember)
            Text(badge.title)
                .font(.hearthUI(12, weight: .medium))
                .foregroundStyle(hearth.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(hearth.emberSoft))
    }
}

struct JournalSessionRow: View {
    let session: HistorySession
    var title: String? = nil

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.mediaType == "ebook" ? "book" : "headphones")
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(hearth.ember)
                .frame(width: 36, height: 36)
                .background(Circle().fill(hearth.emberSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? journalSourceName)
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                Text(journalCaption)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if let delta = session.formattedProgressDelta {
                Text(delta)
                    .font(.hearthUI(13, weight: .semibold))
                    .foregroundStyle(hearth.statusOK)
            }
        }
    }

    private var journalSourceName: String {
        switch session.source {
        case .local: "This device"
        case .audiobookshelf: "Audiobookshelf"
        case .grimmory: "Grimmory"
        case .plex: "Plex"
        case .jellyfin: "Jellyfin"
        case .hardcover: "Hardcover"
        case .bookOrbit: "BookOrbit"
        }
    }

    private var journalCaption: String {
        var parts = [session.formattedDuration, JournalStatsFormat.relative(session.startTime)]
        if title != nil, session.source != .local {
            parts.append(journalSourceName)
        }
        return parts.joined(separator: " · ")
    }
}

enum JournalStatsFormat {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt
    }()

    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    static func hours(_ hours: Double) -> String {
        String(format: "%.1f h", hours)
    }
}
