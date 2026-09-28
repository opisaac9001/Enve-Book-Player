#if !os(tvOS)
import SwiftUI

struct ReaderProgressConflictSheet: View {
    let book: Book
    let conflict: EbookSyncConflict
    let onKeepLocal: () -> Void
    let onUseRemote: () -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var localPassage: ProgressConflictPassage?
    @State private var remotePassage: ProgressConflictPassage?
    @State private var isResolvingPassages = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Overline("Two reading positions")

                Text("This device and \(conflict.remoteSource) remember different places in \(conflict.bookTitle). Pick where to continue.")
                    .font(.hearthUI(15))
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                choice(
                    title: "This device",
                    progress: conflict.localProgress,
                    updatedAt: book.lastUpdate,
                    passage: localPassage,
                    isPrimary: false,
                    action: onKeepLocal
                )

                choice(
                    title: conflict.remoteSource,
                    progress: conflict.serverProgress,
                    updatedAt: conflict.serverDate,
                    passage: remotePassage,
                    isPrimary: true,
                    action: onUseRemote
                )

                Button("Decide later") { dismiss() }
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 26)
        }
        .background(hearth.bg)
        .hearthPresentationBackground()
        .task {
            let resolved = await ProgressConflictPassageService.passages(
                for: book,
                localLocator: book.epubLocator,
                localProgress: conflict.localProgress,
                remoteLocator: conflict.serverLocator,
                remoteProgress: conflict.serverProgress
            )
            localPassage = resolved.local
            remotePassage = resolved.remote
            isResolvingPassages = false
        }
    }

    @ViewBuilder
    private func choice(
        title: String,
        progress: Double,
        updatedAt: Date,
        passage: ProgressConflictPassage?,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.hearthUI(16, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.hearthUI(16, weight: .semibold))
                        .foregroundStyle(isPrimary ? hearth.ember : hearth.text)
                }

                if let relative = relativeTime(updatedAt) {
                    Text(relative)
                        .font(.hearthUI(13))
                        .foregroundStyle(hearth.textTertiary)
                }

                if let passage, !passage.text.isEmpty {
                    if let section = passage.sectionTitle {
                        Text(section)
                            .font(.hearthUI(13, weight: .medium))
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                    Text(passage.text)
                        .font(.hearthDisplay(15, weight: .regular))
                        .italic()
                        .foregroundStyle(hearth.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(isPrimary ? hearth.ember : hearth.hairline)
                                .frame(width: 2)
                        }
                    Text(passage.accuracy.label)
                        .font(.hearthUI(12, weight: .medium))
                        .foregroundStyle(hearth.textTertiary)
                } else {
                    Text(isResolvingPassages ? "Finding the passage…" : "Preview unavailable — showing progress only")
                        .font(.hearthUI(13))
                        .foregroundStyle(hearth.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                            .strokeBorder(isPrimary ? hearth.ember.opacity(0.55) : hearth.hairline, lineWidth: 1)
                    }
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Continue from \(title), \(Int((progress * 100).rounded())) percent")
        .accessibilityValue(accessibilityValue(updatedAt: updatedAt, passage: passage))
    }

    private func accessibilityValue(updatedAt: Date, passage: ProgressConflictPassage?) -> String {
        var parts: [String] = []
        if let relative = relativeTime(updatedAt) { parts.append(relative) }
        if let passage, !passage.text.isEmpty {
            parts.append(passage.accuracy.label)
            parts.append(passage.text)
        } else if !isResolvingPassages {
            parts.append("Preview unavailable")
        }
        return parts.joined(separator: ". ")
    }

    private func relativeTime(_ date: Date) -> String? {
        guard date > .distantPast, date.timeIntervalSinceNow < 60 else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Saved \(formatter.localizedString(for: date, relativeTo: .now))"
    }
}

#endif
