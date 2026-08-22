import SwiftUI

struct AdminABSScreen: View {
    let connection: ServerConnection
    @State private var model: AdminABSModel

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    init(connection: ServerConnection) {
        self.connection = connection
        _model = State(initialValue: AdminABSModel(connection: connection))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AdminHubHeader(connection: connection)

                if model.isLoading && !model.hasLoaded {
                    AdminLoadingRow("Asking the server for its ledger…")
                } else if model.currentUser == nil && model.hasLoaded {
                    adminGate
                } else if model.hasLoaded {
                    personalCard
                    personalDoorsCard
                    if model.isAuthorized {
                        overviewCard
                        adminDoorsCard
                    } else {
                        adminGate
                    }
                    QuietButton(title: "Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refreshAll() }
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
        .refreshable { await model.refreshAll() }
        .task {
            if !model.hasLoaded { await model.refreshAll() }
        }
        .adminMessageAlert(
            error: Binding(get: { model.error }, set: { model.error = $0 }),
            success: Binding(get: { model.successMessage }, set: { model.successMessage = $0 })
        )
    }

    private var adminGate: some View {
        SourcesCard {
            HStack(spacing: 10) {
                Image(systemName: "lock")
                    .foregroundStyle(hearth.statusWarn)
                Text(
                    model.currentUser == nil
                        ? "The server would not say who you are."
                        : "Only root or admin accounts may tend this server."
                )
                .font(.hearthBody)
                .foregroundStyle(hearth.text)
            }
            if let error = model.error {
                Text(error)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusError)
            }
        }
    }

    private var personalCard: some View {
        SourcesCard {
            Overline("Your listening")
            HStack(alignment: .top) {
                AdminStat(value: AdminFormat.hours(model.stats?.totalTime ?? 0), label: "All time")
                AdminStat(value: AdminFormat.hours(model.stats?.today ?? 0), label: "Today")
                AdminStat(value: "\(model.stats?.recentSessions?.count ?? 0)", label: "Recent sessions")
            }
            if let user = model.currentUser {
                Text("Signed in as \(user.username), a \(user.type) account.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
        }
    }

    private var personalDoorsCard: some View {
        SourcesCard {
            AdminLinkRow(
                systemImage: "chart.bar",
                title: "Your listening",
                caption: model.stats.map { AdminFormat.hours($0.totalTime ?? 0) + " on this server" }
                    ?? "Hours, days, and recent sessions"
            ) {
                AdminABSStatsScreen(model: model)
            }
        }
    }

    private var overviewCard: some View {
        SourcesCard {
            Overline("The household")
            HStack(alignment: .top) {
                AdminStat(value: "\(model.users.count)", label: "Users")
                AdminStat(value: "\(model.onlineUsers.count)", label: "Online")
                AdminStat(value: "\(model.activeSessions.count)", label: "Listening")
            }
            HStack(alignment: .top) {
                AdminStat(value: "\(model.libraries.count)", label: "Libraries")
                AdminStat(value: "\(model.backups.count)", label: "Backups")
                AdminStat(
                    value: AdminFormat.hours(model.stats?.totalTime ?? 0),
                    label: "All time"
                )
            }
        }
    }

    private var adminDoorsCard: some View {
        SourcesCard {
            AdminLinkRow(
                systemImage: "person.2",
                title: "Users & sessions",
                caption: "\(model.users.count) users · \(model.activeSessions.count) listening now"
            ) {
                AdminABSUsersScreen(model: model)
            }
            AdminLinkRow(
                systemImage: "books.vertical",
                title: "Libraries",
                caption: model.libraries.isEmpty
                    ? "None yet"
                    : model.libraries.map(\.name).prefix(3).joined(separator: ", ")
            ) {
                AdminABSLibrariesScreen(model: model)
            }
            AdminLinkRow(
                systemImage: "externaldrive",
                title: "Server & backups",
                caption: model.backups.isEmpty ? "No backups yet" : "\(model.backups.count) backups kept"
            ) {
                AdminABSServerScreen(model: model)
            }
        }
    }
}

struct AdminABSStatsScreen: View {
    let model: AdminABSModel

    @Environment(\.hearth) private var hearth

    var body: some View {
        AdminSubScreen(overline: model.connection.name, title: "Your listening") {
            if let stats = model.stats {
                SourcesCard {
                    HStack(alignment: .top) {
                        AdminStat(value: AdminFormat.hours(stats.totalTime ?? 0), label: "All time")
                        AdminStat(value: AdminFormat.hours(stats.today ?? 0), label: "Today")
                    }
                }

                let entries = Array(stats.dailyStatsArray.suffix(14))
                if !entries.isEmpty {
                    SourcesCard {
                        Overline("The last fortnight")
                        AdminBars(values: entries.map(\.minutes))
                        HStack {
                            Text(adminShortDate(entries.first?.date))
                            Spacer()
                            Text(adminShortDate(entries.last?.date))
                        }
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                    }
                }

                if let sessions = stats.recentSessions, !sessions.isEmpty {
                    SourcesCard {
                        Overline("Recent sessions")
                        ForEach(Array(sessions.prefix(8).enumerated()), id: \.offset) { _, session in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.displayTitle ?? "Untitled")
                                        .font(.hearthUI(14, weight: .medium))
                                        .foregroundStyle(hearth.text)
                                        .lineLimit(1)
                                    Text(session.displayAuthor ?? "Unknown author")
                                        .font(.hearthCaption)
                                        .foregroundStyle(hearth.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(AdminFormat.hours(session.timeListening ?? 0))
                                        .font(.hearthUI(13, weight: .medium))
                                        .foregroundStyle(hearth.ember)
                                    if let date = session.date {
                                        Text(date)
                                            .font(.hearthUI(11))
                                            .foregroundStyle(hearth.textTertiary)
                                    }
                                }
                            }
                            .frame(minHeight: 36)
                        }
                    }
                }
            } else if model.isLoading {
                AdminLoadingRow("Tallying the hours…")
            } else {
                AdminEmptyText("This account has no listening to report yet.")
            }
        }
    }

    private func adminShortDate(_ raw: String?) -> String {
        guard let raw else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: raw) else { return raw }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
