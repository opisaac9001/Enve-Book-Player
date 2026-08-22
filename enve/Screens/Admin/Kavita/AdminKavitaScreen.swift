import SwiftUI

struct AdminKavitaScreen: View {
    let connection: ServerConnection
    @State private var model: AdminKavitaModel

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    init(connection: ServerConnection) {
        self.connection = connection
        _model = State(initialValue: AdminKavitaModel(connection: connection))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AdminHubHeader(connection: connection)

                if model.isLoading && !model.hasLoaded {
                    AdminLoadingRow("Asking Kavita what you have read…")
                } else if let error = model.error {
                    errorCard(error)
                } else if model.statsUnavailable {
                    unavailableCard
                } else if model.hasLoaded {
                    if let account = model.account { accountCard(account) }
                    rangeChips
                    overviewCard
                    paceCard
                    rhythmCard
                    if !model.genres.isEmpty { genresCard }
                    if !model.authors.isEmpty { authorsCard }
                    doorsCard
                    QuietButton(title: "Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
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
        .refreshable { await model.refresh() }
        .task {
            if !model.hasLoaded { await model.refresh() }
        }
    }

    private func errorCard(_ message: String) -> some View {
        SourcesCard {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(hearth.statusWarn)
                Text(message)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
            }
            QuietButton(title: "Try again", systemImage: "arrow.clockwise") {
                Task { await model.refresh() }
            }
        }
    }

    private var unavailableCard: some View {
        SourcesCard {
            Text("This Kavita server doesn't publish reading statistics. Update the server to see them here.")
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func accountCard(_ account: KavitaProvider.Account) -> some View {
        SourcesCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(hearth.emberSoft)
                        .frame(width: 48, height: 48)
                    Text(String(account.displayName.prefix(1)).uppercased())
                        .font(.hearthDisplay(20))
                        .foregroundStyle(hearth.ember)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.displayName)
                        .font(.hearthUI(16, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if account.isAdmin { AdminTag(text: "Admin", color: hearth.ember) }
                        if let email = account.email, !email.isEmpty, email != account.username {
                            Text(email)
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
            }
        }
    }

    private var rangeChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(AdminKavitaRange.allCases) { range in
                    HearthChip(title: range.rawValue, isSelected: range == model.range) {
                        model.select(range: range)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var overviewCard: some View {
        SourcesCard {
            Overline("Your reading")
            HStack(alignment: .top) {
                AdminStat(value: "\(model.profileBar?.booksRead ?? 0)", label: "Books")
                AdminStat(value: "\(model.profileBar?.comicsRead ?? 0)", label: "Comics")
                AdminStat(value: (model.profileBar?.pagesRead ?? 0).formatted(), label: "Pages")
            }
            HStack(alignment: .top) {
                AdminStat(value: "\(model.totals?.timeSpentReading ?? 0)h", label: "All time")
                AdminStat(value: "\(model.totalReads ?? 0)", label: "Chapters read")
                AdminStat(value: "\(model.profileBar?.authorsRead ?? 0)", label: "Authors")
            }
            if let totals = model.totals, totals.avgHoursPerWeekSpentReading > 0 {
                Text("About \(String(format: "%.1f", totals.avgHoursPerWeekSpentReading)) hours a week, on average.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
        }
    }

    private var paceCard: some View {
        SourcesCard {
            Overline("Pace over \(model.range.rawValue.lowercased())")
            HStack(alignment: .top) {
                AdminStat(value: "\(model.pace?.hoursRead ?? 0)h", label: "Read")
                AdminStat(value: (model.pace?.wordsRead ?? 0).formatted(), label: "Words")
                AdminStat(value: "\(model.pace?.daysInRange ?? 0)", label: "Days counted")
            }
        }
    }

    private var rhythmCard: some View {
        SourcesCard {
            Overline("Your rhythm")
            HStack(alignment: .top) {
                AdminStat(value: "\(model.streak)", label: "Day streak")
                AdminStat(value: "\(model.activeDays)", label: "Active days")
                AdminStat(value: model.peakHour ?? "—", label: "Peak hour")
            }
            if let weekday = model.favoriteWeekday {
                AdminInfoRow(label: "Favourite day", value: weekday)
            }
            if !model.hours.isEmpty {
                AdminBars(values: hourValues, height: 72)
                HStack {
                    Text("12 AM")
                    Spacer()
                    Text("11 PM")
                }
                .font(.hearthUI(11))
                .foregroundStyle(hearth.textTertiary)
            }
        }
    }

    private var hourValues: [Double] {
        var buckets = [Double](repeating: 0, count: 24)
        for entry in model.hours where (0..<24).contains(entry.value) {
            buckets[entry.value] = Double(entry.count)
        }
        return buckets
    }

    private var genresCard: some View {
        SourcesCard {
            Overline("What you reach for")
            let peak = Double(model.genres.first?.count ?? 1)
            ForEach(Array(model.genres.prefix(8).enumerated()), id: \.offset) { index, genre in
                AdminGenreRow(
                    rank: index + 1,
                    label: genre.value ?? "Unknown",
                    detail: "\(genre.count)",
                    fraction: peak > 0 ? Double(genre.count) / peak : 0
                )
            }
        }
    }

    private var authorsCard: some View {
        SourcesCard {
            Overline("Authors you return to")
            ForEach(model.authors.prefix(8)) { author in
                AdminInfoRow(
                    label: author.authorName ?? "Unknown author",
                    value: "\(author.totalChaptersRead) chapters"
                )
            }
        }
    }

    private var doorsCard: some View {
        SourcesCard {
            AdminLinkRow(
                systemImage: "clock.arrow.circlepath",
                title: "Reading history",
                caption: model.recentHistory.isEmpty
                    ? "Every session Kavita has kept"
                    : "\(model.recentHistory.count) recent sessions"
            ) {
                AdminKavitaHistoryScreen(model: model)
            }
            AdminLinkRow(
                systemImage: "highlighter",
                title: "Highlights & notes",
                caption: "Browse and export your annotations"
            ) {
                AdminKavitaAnnotationsScreen(model: model)
            }
        }
    }
}

struct AdminGenreRow: View {
    let rank: Int
    let label: String
    let detail: String
    let fraction: Double

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(rank). \(label)")
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                Spacer()
                Text(detail)
                    .font(.hearthUI(13, weight: .semibold))
                    .foregroundStyle(hearth.textSecondary)
            }
            AdminProgressLine(fraction: fraction)
        }
        .padding(.vertical, 4)
    }
}
