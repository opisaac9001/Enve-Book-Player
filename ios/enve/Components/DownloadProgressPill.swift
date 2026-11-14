#if os(iOS)
import SwiftUI

struct DownloadProgressPill: View {
    let tasks: [BookDownloadTask]
    var onOpen: () -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var ringSize: CGFloat = 22

    var body: some View {
        if !tasks.isEmpty {
            let transferring = tasks.contains { $0.status == .downloading }
            let fraction = Self.fraction(of: tasks)
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    ring(fraction: fraction, transferring: transferring)
                    Text(label(count: tasks.count, transferring: transferring))
                        .font(.hearthUI(13, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    if transferring {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.hearthCaption.monospacedDigit())
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .background {
                    HearthChromeBackground(shape: .capsule, fill: hearth.bgElevated, stroke: hearth.hairline, tint: hearth.ember, shadow: true)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Downloads")
            .accessibilityValue(accessibilityValue(count: tasks.count, transferring: transferring, fraction: fraction))
            .accessibilityHint("Opens Downloads")
            .accessibilityIdentifier("download-progress-pill")
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func ring(fraction: Double, transferring: Bool) -> some View {
        ZStack {
            Circle().stroke(hearth.hairline, lineWidth: 2.5)
            if transferring {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(hearth.ember, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
            } else {
                Image(systemName: "clock")
                    .font(.hearthUI(11, weight: .semibold))
                    .foregroundStyle(hearth.textSecondary)
            }
        }
        .frame(width: ringSize, height: ringSize)
    }

    private func label(count: Int, transferring: Bool) -> String {
        if transferring { return count == 1 ? "Downloading" : "Downloading \(count)" }
        return "\(count) queued"
    }

    private func accessibilityValue(count: Int, transferring: Bool, fraction: Double) -> String {
        let items = count == 1 ? "1 item" : "\(count) items"
        guard transferring else { return "\(items) queued" }
        return "\(items), \(Int((fraction * 100).rounded())) percent"
    }

    private static func fraction(of tasks: [BookDownloadTask]) -> Double {
        let totalBytes = tasks.reduce(Int64(0)) { $0 + $1.totalBytes }
        let value: Double
        if tasks.allSatisfy({ $0.totalBytes > 0 }) {
            value = Double(tasks.reduce(Int64(0)) { $0 + $1.bytesDownloaded }) / Double(totalBytes)
        } else {
            value = tasks.reduce(0) { $0 + $1.progress } / Double(tasks.count)
        }
        return min(max(value, 0), 1)
    }
}
#endif
