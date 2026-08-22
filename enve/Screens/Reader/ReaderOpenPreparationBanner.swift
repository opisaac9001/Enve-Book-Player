import SwiftUI

struct ReaderOpenPreparationBanner: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    var body: some View {
        if let activity = engine.readerOpen.activity {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    statusGlyph(for: activity)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(activity.book.title)
                            .font(.hearthUI(15, weight: .semibold))
                            .foregroundStyle(hearth.text)
                            .lineLimit(1)
                        Text(statusText(for: activity))
                            .font(.hearthCaption)
                            .foregroundStyle(statusColor(for: activity))
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)
                    controls(for: activity)
                }

                if case .downloading = activity.phase, let progress = progress(for: activity) {
                    ProgressView(value: progress)
                        .tint(hearth.ember)
                        .accessibilityLabel("Download progress")
                        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: 520)
            .background {
                HearthChromeBackground(
                    shape: .rounded(Hearth.radiusCard),
                    fill: hearth.bgElevated,
                    stroke: hearth.hairline,
                    tint: hearth.ember
                )
            }
            .shadow(color: hearth.bgSunken.opacity(0.35), radius: 18, y: 8)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func statusGlyph(for activity: ReaderOpenCoordinator.Activity) -> some View {
        switch activity.phase {
        case .downloading:
            if let progress = progress(for: activity) {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .tint(hearth.ember)
                    .frame(width: 24, height: 24)
            } else {
                ProgressView()
                    .tint(hearth.ember)
                    .frame(width: 24, height: 24)
            }
        case .preparing:
            ProgressView()
                .tint(hearth.ember)
                .frame(width: 24, height: 24)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.hearthUI(22))
                .foregroundStyle(hearth.statusError)
                .frame(width: 24, height: 24)
        }
    }

    @ViewBuilder
    private func controls(for activity: ReaderOpenCoordinator.Activity) -> some View {
        switch activity.phase {
        case .downloading:
            Button("Cancel") {
                engine.readerOpen.cancel()
            }
            .font(.hearthUI(13, weight: .semibold))
            .foregroundStyle(hearth.textSecondary)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
        case .preparing:
            EmptyView()
        case .failed:
            HStack(spacing: 4) {
                Button("Retry") {
                    engine.readerOpen.retry()
                }
                .font(.hearthUI(13, weight: .semibold))
                .foregroundStyle(hearth.ember)
                .buttonStyle(.plain)
                .frame(minHeight: 44)

                Button {
                    engine.readerOpen.dismissFailure()
                } label: {
                    Image(systemName: "xmark")
                        .font(.hearthUI(12, weight: .semibold))
                        .foregroundStyle(hearth.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
    }

    private func statusText(for activity: ReaderOpenCoordinator.Activity) -> String {
        switch activity.phase {
        case .downloading:
            guard let progress = progress(for: activity) else { return "Downloading…" }
            return "Downloading \(Int((progress * 100).rounded()))%"
        case .preparing:
            return "Preparing book…"
        case .failed(let message):
            return message
        }
    }

    private func statusColor(for activity: ReaderOpenCoordinator.Activity) -> Color {
        if case .failed = activity.phase {
            return hearth.statusError
        }
        return hearth.textSecondary
    }

    private func progress(for activity: ReaderOpenCoordinator.Activity) -> Double? {
        if let direct = activity.directProgress, direct > 0 {
            return min(max(direct, 0), 1)
        }
        guard let task = engine.downloads.mostRelevantTask(for: activity.book),
            task.status == .downloading,
            task.totalBytes > 0 || task.progress > 0
        else {
            return nil
        }
        return min(max(task.progress, 0), 1)
    }
}
