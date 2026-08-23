import SwiftUI

struct DetailSyncStatusRow: View {
    let book: Book

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    @State private var phase: BookSyncStatusPhase = .idle
    @State private var lastEvent = ""

    var body: some View {
        if let provider = engine.sync.providerSummary(for: book) {
            HStack(spacing: 12) {
                badge
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    Text(lastEvent.isEmpty ? "Progress stays in step with this source" : lastEvent)
                        .font(.hearthUI(12))
                        .foregroundStyle(hearth.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                GlyphButton(systemImage: "arrow.triangle.2.circlepath", size: 36, glyphSize: 14, label: "Sync now") {
                    PlatformHaptics.impact(.light)
                    Task { await engine.sync.pushProgress(for: book) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    )
            }
            .task(id: book.stableId) {
                for await update in engine.sync.statusUpdates(for: book) {
                    phase = update.phase
                    lastEvent = update.message
                }
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch phase {
        case .idle:
            Circle()
                .fill(hearth.statusOK)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Sync up to date")
        case .syncing:
            ProgressView()
                .controlSize(.mini)
                .tint(hearth.ember)
                .accessibilityLabel("Syncing")
        case .error(let message):
            Image(systemName: "exclamationmark.circle.fill")
                .font(.hearthUI(13))
                .foregroundStyle(hearth.statusError)
                .accessibilityLabel("Sync error: \(message)")
        }
    }
}
