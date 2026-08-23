import SwiftUI

struct BookOrbitAchievementsScreen: View {
    let connectionId: UUID?

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var state: BookOrbitLoadState = .loading
    @State private var catalogue: BookOrbitProvider.AchievementCatalogue?
    @State private var earnedOnly = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                JournalScreenHeader(overline: "Kept by your server", title: "Honors")

                switch state {
                case .loading:
                    JournalLoadingNote(text: "Opening the case…")
                case .unavailable:
                    BookOrbitUnavailableCard(
                        line: "This BookOrbit server doesn't keep an achievement catalogue. Update the server to see it here."
                    )
                case .failed(let message):
                    BookOrbitErrorCard(message: message) {
                        Task { await load() }
                    }
                case .ready:
                    if let catalogue {
                        summaryCard(catalogue)
                        filterChips
                        ForEach(catalogue.categories, id: \.key) { category in
                            categoryCard(category)
                        }
                    }
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
        .refreshable { await load() }
        .task { await load() }
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            HearthChip(title: "All", isSelected: !earnedOnly) { earnedOnly = false }
            HearthChip(title: "Earned", isSelected: earnedOnly) { earnedOnly = true }
        }
    }

    private func summaryCard(_ catalogue: BookOrbitProvider.AchievementCatalogue) -> some View {
        JournalCard("The case") {
            HStack(spacing: 18) {
                JournalGoalRing(
                    fraction: catalogue.totalAvailable > 0
                        ? Double(catalogue.totalEarned) / Double(catalogue.totalAvailable) : 0,
                    centerValue: "\(catalogue.totalEarned)",
                    centerUnit: "earned"
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(catalogue.totalEarned) of \(catalogue.totalAvailable)")
                        .font(.hearthDisplay(20, weight: .semibold))
                        .foregroundStyle(hearth.text)
                    Text(
                        catalogue.totalEarned >= catalogue.totalAvailable && catalogue.totalAvailable > 0
                            ? "Every honor claimed."
                            : "\(catalogue.totalAvailable - catalogue.totalEarned) still waiting"
                    )
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
            }
            if let next = nextUp(catalogue) {
                Rectangle().fill(hearth.hairline).frame(height: 1)
                JournalMeterRow(
                    label: next.name,
                    detail: "\(Int((next.currentProgress ?? 0).rounded())) of \(Int((next.threshold ?? 0).rounded()))",
                    fraction: fraction(next)
                )
            }
        }
    }

    private func categoryCard(_ category: BookOrbitProvider.AchievementCategory) -> some View {
        let items = earnedOnly ? category.achievements.filter(\.earned) : category.achievements
        return Group {
            if !items.isEmpty {
                JournalCard("\(category.label) · \(category.earnedCount)/\(category.totalCount)") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 18) {
                        ForEach(items, id: \.key) { achievement in
                            badge(achievement)
                        }
                    }
                }
            }
        }
    }

    private func badge(_ achievement: BookOrbitProvider.Achievement) -> some View {
        VStack(spacing: 7) {
            Image(systemName: BookOrbitAchievementIcon.symbol(achievement.iconName))
                .font(.hearthUI(17, weight: .medium))
                .foregroundStyle(achievement.earned ? hearth.ember : hearth.textTertiary)
                .frame(width: 46, height: 46)
                .background(Circle().fill(achievement.earned ? hearth.emberSoft : hearth.hairline))
            Text(achievement.name)
                .font(.hearthUI(11, weight: .medium))
                .foregroundStyle(achievement.earned ? hearth.text : hearth.textTertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Overline(achievement.rarity, color: hearth.textTertiary)
            if !achievement.earned, fraction(achievement) > 0 {
                Ribbon(progress: fraction(achievement), tint: hearth.ember, height: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(achievement.name), \(achievement.earned ? "earned" : "not yet earned")")
        .accessibilityHint(achievement.description)
    }

    private func nextUp(_ catalogue: BookOrbitProvider.AchievementCatalogue) -> BookOrbitProvider.Achievement? {
        catalogue.categories
            .flatMap(\.achievements)
            .filter { !$0.earned && !$0.hidden && fraction($0) > 0 }
            .max { fraction($0) < fraction($1) }
    }

    private func fraction(_ achievement: BookOrbitProvider.Achievement) -> Double {
        guard let threshold = achievement.threshold, threshold > 0, let progress = achievement.currentProgress else {
            return 0
        }
        return min(max(progress / threshold, 0), 1)
    }

    private func load() async {
        guard let connectionId, let provider = BookOrbitAccess.provider(connectionId) else {
            state = .unavailable
            return
        }
        do {
            catalogue = try await provider.fetchAchievementCatalogue()
            state = .ready
        } catch BookOrbitProvider.FeatureError.unavailable {
            state = .unavailable
        } catch {
            state = .failed(BookOrbitAccess.message(for: error))
        }
    }
}

enum BookOrbitAchievementIcon {
    static func symbol(_ name: String) -> String {
        switch name {
        case "activity": "waveform.path.ecg"
        case "arrow-left-right": "arrow.left.arrow.right"
        case "arrow-up-down": "arrow.up.arrow.down"
        case "award": "rosette"
        case "book-heart": "heart.text.square.fill"
        case "book-marked": "bookmark.square.fill"
        case "book-open": "book.fill"
        case "book-x": "book.closed.fill"
        case "bookmark-check": "bookmark.fill"
        case "calendar": "calendar"
        case "calendar-check": "calendar.badge.checkmark"
        case "calendar-range": "calendar.badge.clock"
        case "clock": "clock.fill"
        case "coffee": "cup.and.saucer.fill"
        case "compass": "safari.fill"
        case "corner-up-right": "arrowshape.turn.up.right.fill"
        case "fast-forward": "forward.fill"
        case "feather": "pencil.and.outline"
        case "file-text": "doc.text.fill"
        case "files": "doc.on.doc.fill"
        case "flame": "flame.fill"
        case "folder-open": "folder.fill"
        case "gauge": "gauge.medium"
        case "gavel": "hammer.fill"
        case "globe": "globe"
        case "heart": "heart.fill"
        case "highlighter": "highlighter"
        case "hourglass": "hourglass"
        case "library": "books.vertical.fill"
        case "list-ordered": "list.number"
        case "medal": "rosette"
        case "minimize-2": "arrow.down.right.and.arrow.up.left"
        case "moon": "moon.fill"
        case "mountain": "triangle.fill"
        case "orbit": "circle.dashed"
        case "palette": "paintpalette.fill"
        case "party-popper": "sparkles"
        case "pen-line": "pencil"
        case "pen-tool": "pencil.tip"
        case "play": "play.fill"
        case "rabbit": "hare.fill"
        case "repeat": "repeat"
        case "scroll": "scroll.fill"
        case "scroll-text": "doc.plaintext.fill"
        case "smartphone": "iphone"
        case "sparkles": "sparkles"
        case "sprout": "leaf.fill"
        case "star": "star.fill"
        case "star-half": "star.leadinghalf.filled"
        case "sun": "sun.max.fill"
        case "sunrise": "sunrise.fill"
        case "swords": "shield.lefthalf.filled"
        case "thumbs-down": "hand.thumbsdown.fill"
        case "timer": "timer"
        case "trophy": "trophy.fill"
        case "zap": "bolt.fill"
        default: "questionmark.circle"
        }
    }
}
