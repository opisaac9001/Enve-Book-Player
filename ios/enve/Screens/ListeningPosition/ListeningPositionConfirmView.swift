#if os(iOS)
import SwiftUI

struct ListeningPositionConfirmView: View {
    let model: ListeningPositionScanModel
    let candidate: ListeningPositionCandidate
    let onFinish: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Overline("Move your copy")
                    .padding(.top, 12)

                HStack(alignment: .top, spacing: 14) {
                    CoverTile(book: candidate.book, width: 72, badges: false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.book.title)
                            .font(.hearthDisplay(20))
                            .foregroundStyle(hearth.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(ListeningPositionText.byline(for: candidate.book))
                            .font(.hearthUI(13))
                            .foregroundStyle(hearth.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let narrator = candidate.book.narrator, !narrator.isEmpty {
                            Text("Narrated by \(narrator)")
                                .font(.hearthUI(12))
                                .foregroundStyle(hearth.textTertiary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)

                positions

                if !candidate.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(candidate.warnings.enumerated()), id: \.offset) { _, warning in
                            Label(ListeningPositionText.text(for: warning), systemImage: "exclamationmark.triangle")
                                .font(.hearthUI(13))
                                .foregroundStyle(hearth.statusWarn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text("This changes where this copy resumes, on this device and on its server if it has one. It won't open the reader or start playback.")
                    .font(.hearthUI(13))
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                action
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(hearth.bg)
    }

    private var positions: some View {
        let current = model.payload?.readingLocation != nil
            ? ListeningPositionPayload(book: candidate.book).map { ListeningPositionText.position($0) } ?? "0%"
            : HearthFormat.clock(model.currentPosition(of: candidate.book))
        let target = model.payload.map { ListeningPositionText.position($0) } ?? ""
        return HStack(spacing: 14) {
            positionColumn("Now", current, tint: hearth.textSecondary)
            Image(systemName: "arrow.right")
                .font(.hearthUI(15, weight: .semibold))
                .foregroundStyle(hearth.textTertiary)
                .accessibilityHidden(true)
            positionColumn("Shared", target, tint: hearth.ember)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                .fill(hearth.bgElevated)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now at \(current). Shared position \(target).")
    }

    private func positionColumn(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Overline(label)
            Text(value)
                .font(.hearthUI(20, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch model.status {
        case .idle:
            if candidate.canApply, let payload = model.payload {
                EmberButton(title: "Move to \(ListeningPositionText.position(payload))", systemImage: "arrow.uturn.right") {
                    Task { await model.apply(candidate) }
                }
            }
        case .applying:
            HStack(spacing: 10) {
                ProgressView()
                Text("Saving…")
                    .font(.hearthUI(14))
                    .foregroundStyle(hearth.textSecondary)
            }
            .accessibilityElement(children: .combine)
        case .done(let result):
            VStack(alignment: .leading, spacing: 14) {
                Label(message(for: result), systemImage: icon(for: result.server))
                    .font(.hearthUI(14))
                    .foregroundStyle(tint(for: result.server))
                    .fixedSize(horizontal: false, vertical: true)
                EmberButton(title: "Done", action: onFinish)
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .font(.hearthUI(14))
                .foregroundStyle(hearth.statusError)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func message(for result: ListeningPositionApplyResult) -> String {
        let position = result.book.mediaType == .ebook
            ? ListeningPositionPayload(book: result.book).map { ListeningPositionText.position($0) } ?? "the shared position"
            : HearthFormat.clock(result.position)
        let moved = "Moved to \(position) on this device."
        let server = result.book.backendName ?? "the server"
        switch result.server {
        case .saved:
            return "\(moved) \(server) has saved it too."
        case .queued:
            return "\(moved) \(server) hasn't confirmed it yet; Enve will keep retrying when it can reach it."
        case .rejected(let reason):
            return "\(moved) \(server) rejected the update: \(reason)"
        case .noServer:
            return "\(moved) This copy isn't connected to a server."
        case .syncDisabled:
            return "\(moved) Server sync is off, so no server was updated."
        }
    }

    private func icon(for status: ListeningPositionServerStatus) -> String {
        switch status {
        case .saved, .noServer, .syncDisabled: "checkmark.circle"
        case .queued: "clock.arrow.circlepath"
        case .rejected: "exclamationmark.triangle"
        }
    }

    private func tint(for status: ListeningPositionServerStatus) -> Color {
        switch status {
        case .saved, .noServer, .syncDisabled: hearth.statusOK
        case .queued, .rejected: hearth.statusWarn
        }
    }
}
#endif
