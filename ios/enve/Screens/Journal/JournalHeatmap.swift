import SwiftUI

struct JournalHeatmap: View {
    let daily: [String: TimeInterval]
    let width: CGFloat

    @Environment(\.hearth) private var hearth

    static let weeks = 52
    private static let gap: CGFloat = 2

    var body: some View {
        let cell = max(1, (width - CGFloat(Self.weeks - 1) * Self.gap) / CGFloat(Self.weeks))
        let height = cell * 7 + Self.gap * 6
        let grid = Self.intensityGrid(daily: daily)

        Canvas { context, _ in
            for (week, column) in grid.enumerated() {
                for (day, intensity) in column.enumerated() {
                    guard let intensity else { continue }
                    let rect = CGRect(
                        x: CGFloat(week) * (cell + Self.gap),
                        y: CGFloat(day) * (cell + Self.gap),
                        width: cell,
                        height: cell
                    )
                    let path = Path(roundedRect: rect, cornerRadius: cell * 0.28)
                    if intensity > 0 {
                        context.fill(path, with: .color(hearth.ember.opacity(0.16 + 0.84 * intensity)))
                    } else {
                        context.fill(path, with: .color(hearth.hairline))
                    }
                }
            }
        }
        .frame(width: max(1, width), height: height)
        .accessibilityHidden(true)
    }

    private static func intensityGrid(daily: [String: TimeInterval]) -> [[Double?]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        guard let gridStart = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: weekStart) else {
            return []
        }

        var seconds: [[TimeInterval?]] = []
        for week in 0..<weeks {
            var column: [TimeInterval?] = []
            for day in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: week * 7 + day, to: gridStart),
                    date <= today
                else {
                    column.append(nil)
                    continue
                }
                column.append(daily[JournalStats.dayKey(for: date), default: 0])
            }
            seconds.append(column)
        }

        let active = seconds.flatMap { $0 }.compactMap { $0 }.filter { $0 > 0 }.sorted()
        guard !active.isEmpty else {
            return seconds.map { column in column.map { value in value.map { _ in 0.0 } } }
        }
        let cap = max(active[Int(Double(active.count - 1) * 0.9)], 60)
        return seconds.map { column in
            column.map { value in value.map { min($0 / cap, 1) } }
        }
    }
}
