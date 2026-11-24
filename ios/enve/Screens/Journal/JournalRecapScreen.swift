#if os(iOS)
import SwiftUI
import UIKit

struct JournalRecapScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var model: JournalRecapModel
    @State private var shareImage: UIImage?
    @State private var shareImageText: String?
    @Environment(\.scenePhase) private var scenePhase

    init(profileSession: ProfileSession) {
        _model = State(initialValue: JournalRecapModel(profileSession: profileSession))
    }

    var body: some View {
        let title = model.title(for: model.period)
        let shareText = model.shareText()
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                JournalScreenHeader(overline: "Looking back", title: "Recaps")

                scopePicker
                periodNavigator(title: title)

                if !model.isLoaded {
                    JournalLoadingNote(text: "Gathering the pages…")
                } else if model.recap.isEmpty {
                    JournalCard {
                        JournalQuietNote(
                            text: model.recap.isInProgress
                                ? "Nothing recorded yet in \(title)."
                                : "No listening or reading was recorded in \(title)."
                        )
                    }
                } else {
                    totalsCard
                    if hasLeaders {
                        leadersCard
                    }
                    shareCard(title: title, text: shareText)
                }

                if model.isLoaded {
                    Text("Based on this profile’s saved sessions, grouped by the day they ended. Listening includes podcasts. Older history may be incomplete. Completion counts aren’t available because finish dates weren’t recorded.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
        .task(id: shareText) {
            shareImage = model.isLoaded && !model.recap.isEmpty ? renderShareImage(title: title) : nil
            shareImageText = shareText
        }
    }

    private var scopePicker: some View {
        HStack(spacing: 8) {
            ForEach(JournalRecapScope.allCases) { scope in
                HearthChip(title: scope.title, isSelected: model.scope == scope) {
                    model.scope = scope
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recap length")
    }

    private func periodNavigator(title: String) -> some View {
        let unit = model.scope.title.lowercased()
        return HStack(spacing: 12) {
            GlyphButton(systemImage: "chevron.left", label: "Previous \(unit)") {
                model.showPrevious()
            }
            .disabled(!model.canShowPrevious)
            .opacity(model.canShowPrevious ? 1 : 0.35)

            VStack(spacing: 4) {
                Text(title)
                    .font(.hearthDisplay(24, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let context = model.dateContext() {
                    Text(context)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)

            GlyphButton(systemImage: "chevron.right", label: "Next \(unit)") {
                model.showNext()
            }
            .disabled(!model.canShowNext)
            .opacity(model.canShowNext ? 1 : 0.35)
        }
    }

    private var totalsCard: some View {
        let activity = model.recap.activity
        return JournalCard("Reading & listening") {
            JournalAllTimeFigure(seconds: activity.totalSeconds)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Total time, \(HearthFormat.duration(activity.totalSeconds))")

            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                JournalStatTile(value: HearthFormat.duration(activity.listeningSeconds), label: "Listening")
                JournalStatTile(value: HearthFormat.duration(activity.readingSeconds), label: "Reading")
                JournalStatTile(value: activity.activeDays.formatted(), label: "Active days")
                JournalStatTile(value: activity.sessions.formatted(), label: "Sessions")
                if activity.pagesRead > 0 {
                    JournalStatTile(value: activity.pagesRead.formatted(), label: "Pages turned")
                }
            }

            if let day = model.recap.busiestDay {
                HStack(alignment: .firstTextBaseline) {
                    Text("Busiest day")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                    Spacer()
                    Text("\(day.date.formatted(.dateTime.month(.wide).day())) · \(HearthFormat.duration(day.seconds))")
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var hasLeaders: Bool {
        let activity = model.recap.activity
        return activity.topBook != nil || activity.topAuthor != nil || activity.topNarrator != nil
    }

    private var leadersCard: some View {
        let activity = model.recap.activity
        return JournalCard("Most time with") {
            if let entry = activity.topBook {
                NavigationLink {
                    BookDetailScreen(book: entry.book)
                } label: {
                    HStack(spacing: 12) {
                        CoverTile(book: entry.book, width: 44)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Overline("Top title", color: hearth.textTertiary)
                            Text(entry.book.title)
                                .font(.hearthUI(16, weight: .medium))
                                .foregroundStyle(hearth.text)
                                .lineLimit(2)
                            if let author = entry.book.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
                                Text(author)
                                    .font(.hearthCaption)
                                    .foregroundStyle(hearth.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(HearthFormat.duration(entry.seconds))
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityElement(children: .combine)
            }
            if let author = activity.topAuthor {
                leader(label: "Top author", entry: author)
            }
            if let narrator = activity.topNarrator {
                leader(label: "Top narrator", entry: narrator)
            }
        }
    }

    private func shareCard(title: String, text: String) -> some View {
        JournalCard("Share") {
            Text(text)
                .font(.hearthUI(14))
                .foregroundStyle(hearth.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(hearth.bgSunken)
                }
                .textSelection(.enabled)

            Text("Share this summary or an image of its totals and leading titles.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { shareButtons(title: title, text: text) }
                VStack(alignment: .leading, spacing: 12) { shareButtons(title: title, text: text) }
            }
        }
    }

    @ViewBuilder
    private func shareButtons(title: String, text: String) -> some View {
        ShareLink(
            item: text,
            subject: Text("\(title) reading recap"),
            preview: SharePreview("\(title) reading recap (text)")
        ) {
            Label("Share summary", systemImage: "square.and.arrow.up")
                .font(.hearthUI(16, weight: .semibold))
                .foregroundStyle(HearthPalette.readableForeground(on: hearth.ember, dark: hearth.onEmber))
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .frame(minHeight: 52)
                .background {
                    HearthChromeBackground(shape: .capsule, fill: hearth.ember, tint: hearth.ember)
                }
        }
        .buttonStyle(PressableStyle())

        if let shareImage, shareImageText == text {
            let image = Image(uiImage: shareImage)
            ShareLink(
                item: image,
                preview: SharePreview("\(title) reading recap (image)", image: image)
            ) {
                Label("Share image", systemImage: "photo")
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(minHeight: 48)
                    .background {
                        HearthChromeBackground(shape: .capsule, fill: hearth.bgElevated, stroke: hearth.hairline, tint: hearth.bgElevated)
                    }
            }
            .buttonStyle(PressableStyle())
        }
    }

    private func leader(label: String, entry: JournalInsightNamedEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Overline(label, color: hearth.textTertiary)
                Text(entry.name)
                    .font(.hearthUI(16, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
            }
            Spacer()
            Text(HearthFormat.duration(entry.seconds))
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 14, alignment: .leading),
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
        )
    }

    private func renderShareImage(title: String) -> UIImage? {
        let renderer = ImageRenderer(
            content: JournalRecapCard(
                title: title,
                context: model.dateContext(),
                activity: model.recap.activity,
                tint: Hearth.accent
            )
        )
        renderer.scale = 3
        return renderer.uiImage
    }
}
#endif
