import SwiftUI

struct DetailHistorySection: View {
    let book: Book
    let tint: Color

    @Environment(\.hearth) private var hearth
    @State private var record: DetailHistoryRecord?

    var body: some View {
        Group {
            if let record {
                VStack(alignment: .leading, spacing: 14) {
                    ShelfHeader(title: "History")
                    card(record)
                        .padding(.horizontal, 24)
                }
            }
        }
        .task(id: book.stableId) { await load() }
    }

    private func card(_ record: DetailHistoryRecord) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 0) {
                column(
                    value: HearthFormat.duration(record.totalSeconds),
                    caption: record.isListening ? "Listened" : "Read"
                )
                hairlineColumnDivider
                column(
                    value: "\(record.sessionCount)",
                    caption: record.sessionCount == 1 ? "Session" : "Sessions"
                )
                if record.isCompleted {
                    hairlineColumnDivider
                    finishedColumn
                }
            }

            if let last = record.lastOpened {
                Rectangle().fill(hearth.hairline).frame(height: 1)
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.hearthUI(12))
                        .foregroundStyle(hearth.textTertiary)
                    Text(record.isListening ? "Last played" : "Last read")
                        .font(.hearthUI(13))
                        .foregroundStyle(hearth.textSecondary)
                    Spacer(minLength: 8)
                    Text(last, format: .relative(presentation: .named))
                        .font(.hearthUI(13, weight: .medium))
                        .foregroundStyle(hearth.text)
                }
            }

            if let fraction = record.positionFraction {
                VStack(spacing: 7) {
                    Ribbon(progress: fraction, tint: tint)
                    HStack {
                        Text(record.positionLeading)
                            .font(.hearthUI(12).monospacedDigit())
                        Spacer()
                        Text(record.positionTrailing)
                            .font(.hearthUI(12).monospacedDigit())
                    }
                    .foregroundStyle(hearth.textTertiary)
                }
            }
        }
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

    private func column(value: String, caption: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.hearthDisplay(19, weight: .semibold))
                .foregroundStyle(hearth.text)
            Overline(caption, color: hearth.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var finishedColumn: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill")
                .font(.hearthUI(17))
                .foregroundStyle(hearth.statusOK)
            Overline("Finished", color: hearth.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var hairlineColumnDivider: some View {
        Rectangle()
            .fill(hearth.hairline)
            .frame(width: 1, height: 36)
    }

    private func load() async {
        if book.mediaType == .ebook {
            let snapshot = await ReadingStatsTracker.shared.currentSnapshot()
            guard let stat = snapshot.perBook[book.stableId] ?? snapshot.perBook[book.id],
                stat.totalSecondsRead > 0 || stat.sessionCount > 0
            else {
                record = nil
                return
            }
            let progression = stat.lastPositionProgression
            record = DetailHistoryRecord(
                isListening: false,
                totalSeconds: stat.totalSecondsRead,
                sessionCount: stat.sessionCount,
                lastOpened: stat.lastRead,
                positionFraction: progression,
                positionLeading: progression.map { "\(Int(($0 * 100).rounded()))% read" } ?? "",
                positionTrailing: "",
                isCompleted: stat.isCompleted
            )
        } else {
            let snapshot = await ListeningStatsTracker.shared.currentSnapshot()
            guard let stat = snapshot.perBook[book.stableId] ?? snapshot.perBook[book.id],
                stat.totalSeconds > 0 || stat.sessionCount > 0
            else {
                record = nil
                return
            }
            var fraction: Double?
            var leading = ""
            var trailing = ""
            if let position = stat.lastPosition, let duration = stat.duration, duration > 0 {
                fraction = min(position / duration, 1)
                leading = HearthFormat.duration(position)
                trailing = HearthFormat.duration(duration)
            }
            record = DetailHistoryRecord(
                isListening: true,
                totalSeconds: stat.totalSeconds,
                sessionCount: stat.sessionCount,
                lastOpened: stat.lastPlayed,
                positionFraction: fraction,
                positionLeading: leading,
                positionTrailing: trailing,
                isCompleted: stat.isCompleted
            )
        }
    }
}

private struct DetailHistoryRecord {
    let isListening: Bool
    let totalSeconds: TimeInterval
    let sessionCount: Int
    let lastOpened: Date?
    let positionFraction: Double?
    let positionLeading: String
    let positionTrailing: String
    let isCompleted: Bool
}
