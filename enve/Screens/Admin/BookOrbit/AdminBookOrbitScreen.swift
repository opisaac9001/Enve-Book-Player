import SwiftUI

struct AdminBookOrbitScreen: View {
    let connection: ServerConnection

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var state: BookOrbitLoadState = .loading
    @State private var summary: BookOrbitProvider.StatisticsSummary?
    @State private var overview: BookOrbitProvider.LibraryOverviewWidget?
    @State private var streak: BookOrbitProvider.ReadingStreakWidget?
    @State private var achievements: BookOrbitProvider.AchievementCatalogue?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AdminHubHeader(connection: connection)

                switch state {
                case .loading:
                    AdminLoadingRow("Asking BookOrbit what it keeps…")
                case .unavailable:
                    unavailableCard
                    doorsCard
                case .failed(let message):
                    failureCard(message)
                    doorsCard
                case .ready:
                    if let summary { readingCard(summary) }
                    if let overview { collectionCard(overview) }
                    doorsCard
                    QuietButton(title: "Refresh", systemImage: "arrow.clockwise") {
                        Task { await load() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .hearthBackBar()
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task { await load() }
    }

    private var unavailableCard: some View {
        SourcesCard {
            Text("This BookOrbit server doesn't publish reading statistics. Update the server to see them here.")
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failureCard(_ message: String) -> some View {
        SourcesCard {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(hearth.statusWarn)
                Text(message)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
            }
            QuietButton(title: "Try again", systemImage: "arrow.clockwise") {
                Task { await load() }
            }
        }
    }

    private func readingCard(_ summary: BookOrbitProvider.StatisticsSummary) -> some View {
        SourcesCard {
            Overline("Your reading")
            HStack(alignment: .top) {
                AdminStat(value: "\(summary.completedBooks)", label: "Finished")
                AdminStat(value: "\(summary.inProgressBooks)", label: "In progress")
                AdminStat(value: "\(summary.trackedBooks)", label: "Tracked")
            }
            if let streak {
                HStack(alignment: .top) {
                    AdminStat(value: "\(streak.currentStreak)", label: "Day streak")
                    AdminStat(value: "\(streak.longestStreak)", label: "Best streak")
                    AdminStat(value: "\(Int(summary.meanProgressPercent.rounded()))%", label: "Mean progress")
                }
            }
        }
    }

    private func collectionCard(_ overview: BookOrbitProvider.LibraryOverviewWidget) -> some View {
        SourcesCard {
            Overline("The collection")
            HStack(alignment: .top) {
                AdminStat(value: overview.totalBooks.formatted(), label: "Books")
                AdminStat(value: overview.totalAuthors.formatted(), label: "Authors")
                AdminStat(value: overview.totalSeries.formatted(), label: "Series")
            }
            AdminInfoRow(label: "Added this year", value: overview.booksAddedThisYear.formatted())
            AdminInfoRow(label: "Storage", value: AdminFormat.bytes(Int(overview.totalStorageBytes)))
        }
    }

    private var doorsCard: some View {
        SourcesCard {
            AdminLinkRow(
                systemImage: "chart.xyaxis.line",
                title: "Insights",
                caption: "Rhythm, pace, genres, and the year so far"
            ) {
                BookOrbitInsightsScreen(connectionId: connection.id)
            }
            AdminLinkRow(
                systemImage: "rosette",
                title: "Achievements",
                caption: achievements.map { "\($0.totalEarned) of \($0.totalAvailable) earned" }
                    ?? "The catalogue this server keeps"
            ) {
                BookOrbitAchievementsScreen(connectionId: connection.id)
            }
            AdminLinkRow(
                systemImage: "highlighter",
                title: "Highlights",
                caption: "Every note and highlight on the account"
            ) {
                BookOrbitMarginaliaScreen(connectionId: connection.id)
            }
        }
    }

    private func load() async {
        guard let provider = BookOrbitAccess.provider(connection.id) else {
            state = .unavailable
            return
        }
        do {
            summary = try await provider.fetchStatisticsSummary()
            state = .ready
        } catch BookOrbitProvider.FeatureError.unavailable {
            state = .unavailable
            return
        } catch {
            state = .failed(BookOrbitAccess.message(for: error))
            return
        }

        async let overviewTask = provider.fetchLibraryOverviewWidget()
        async let streakTask = provider.fetchReadingStreakWidget()
        async let achievementsTask = provider.fetchAchievementCatalogue()
        overview = try? await overviewTask
        streak = try? await streakTask
        achievements = try? await achievementsTask
    }
}
