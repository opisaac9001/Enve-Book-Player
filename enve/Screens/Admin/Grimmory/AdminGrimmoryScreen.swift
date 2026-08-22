import SwiftUI

struct AdminGrimmoryScreen: View {
    let connection: ServerConnection
    @State private var model: AdminGrimmoryModel

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @State private var showingAddUser = false

    init(connection: ServerConnection) {
        self.connection = connection
        _model = State(initialValue: AdminGrimmoryModel(connection: connection))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AdminHubHeader(connection: connection)

                if model.isLoading && !model.hasLoaded {
                    AdminLoadingRow("Asking the server for its ledger…")
                } else if !model.isAuthorized && model.hasLoaded {
                    adminGate
                } else if model.hasLoaded {
                    if let user = model.currentUser { adminUserCard(user) }
                    adminOverviewCard
                    personalDoorsCard
                    if model.currentUser?.isAdmin == true { adminDoorsCard }
                    if !model.shelves.isEmpty { adminShelvesCard }
                    if !model.magicShelves.isEmpty { adminMagicShelvesCard }
                    if !model.readingSessions.isEmpty { adminSessionsCard }
                    if !model.recentBooks.isEmpty { adminRecentBooksCard }
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
        .sheet(isPresented: $showingAddUser) {
            AdminGrimmoryUserSheet(model: model, editing: nil)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .adminMessageAlert(
            error: Binding(get: { model.error }, set: { model.error = $0 }),
            success: Binding(get: { model.successMessage }, set: { model.successMessage = $0 })
        )
    }

    private var adminGate: some View {
        SourcesCard {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(hearth.statusWarn)
                Text("The server would not let us in.")
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

    private func adminUserCard(_ user: GrimmoryUser) -> some View {
        SourcesCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(hearth.emberSoft)
                        .frame(width: 48, height: 48)
                    Text(String(user.displayName.prefix(1)).uppercased())
                        .font(.hearthDisplay(20))
                        .foregroundStyle(hearth.ember)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.displayName)
                        .font(.hearthUI(16, weight: .semibold))
                        .foregroundStyle(hearth.text)
                    HStack(spacing: 6) {
                        if user.isAdmin { AdminTag(text: "Admin", color: hearth.ember) }
                        if let email = user.email, !email.isEmpty {
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

    private var adminOverviewCard: some View {
        SourcesCard {
            Overline("At a glance")
            HStack(alignment: .top) {
                AdminStat(value: "\(model.libraries.count)", label: "Libraries")
                AdminStat(value: "\(model.shelves.count)", label: "Shelves")
                AdminStat(value: "\(model.magicShelves.count)", label: "Magic")
                AdminStat(value: "\(model.readingSessions.count)", label: "Sessions")
            }
        }
    }

    private var personalDoorsCard: some View {
        SourcesCard {
            AdminLinkRow(
                systemImage: "chart.bar",
                title: "Your reading",
                caption: "Trends, hours, favorites"
            ) {
                AdminGrimmoryStatsScreen(connection: connection)
            }
            AdminLinkRow(
                systemImage: "tray.full",
                title: "Shelves & magic shelves",
                caption: "Build, rename, and dispel"
            ) {
                AdminGrimmoryShelvesScreen(model: model)
            }
        }
    }

    private var adminDoorsCard: some View {
        SourcesCard {
            AdminLinkRow(
                systemImage: "person.2",
                title: "Users",
                caption: model.users.isEmpty ? "Manage the accounts" : "\(model.users.count) accounts on this server"
            ) {
                AdminGrimmoryUsersScreen(model: model)
            }
            Button {
                showingAddUser = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.plus")
                        .font(.hearthUI(14, weight: .medium))
                    Text("Create an account")
                        .font(.hearthUI(15, weight: .medium))
                }
                .foregroundStyle(hearth.ember)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
    }

    private var adminShelvesCard: some View {
        SourcesCard {
            Overline("Shelves")
            ForEach(model.shelves.prefix(8)) { shelf in
                HStack(spacing: 12) {
                    Image(systemName: "books.vertical")
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.ember)
                        .frame(width: 24)
                    Text(shelf.name)
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.text)
                    if shelf.publicShelf == true {
                        AdminTag(text: "Public", color: hearth.statusOK)
                    }
                    Spacer()
                    if let count = shelf.bookCount {
                        Text("\(count) books")
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                    }
                }
                .frame(minHeight: 36)
            }
            if model.shelves.count > 8 {
                Text("and \(model.shelves.count - 8) more on the shelves screen")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
        }
    }

    private var adminMagicShelvesCard: some View {
        SourcesCard {
            Overline("Magic shelves")
            ForEach(model.magicShelves.prefix(5)) { shelf in
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.ember)
                        .frame(width: 24)
                    Text(shelf.name)
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.text)
                    if shelf.isPublic == true {
                        AdminTag(text: "Public", color: hearth.statusOK)
                    }
                    Spacer()
                }
                .frame(minHeight: 36)
            }
        }
    }

    private var adminSessionsCard: some View {
        SourcesCard {
            Overline("Recent reading")
            ForEach(model.readingSessions.prefix(5)) { session in
                HStack(spacing: 12) {
                    Image(systemName: session.bookType?.uppercased() == "AUDIOBOOK" ? "headphones" : "book")
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.ember)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.bookTitle ?? "Book #\(session.bookId)")
                            .font(.hearthUI(14, weight: .medium))
                            .foregroundStyle(hearth.text)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if let duration = session.durationFormatted {
                                Text(duration)
                                    .foregroundStyle(hearth.textSecondary)
                            }
                            if let delta = session.progressDelta, delta > 0 {
                                Text("+\(String(format: "%.1f", delta))%")
                                    .foregroundStyle(hearth.statusOK)
                            }
                        }
                        .font(.hearthUI(11))
                    }
                    Spacer()
                    if let endProgress = session.endProgress {
                        Text("\(Int(endProgress))%")
                            .font(.hearthUI(12, weight: .medium))
                            .foregroundStyle(hearth.ember)
                    }
                }
                .frame(minHeight: 40)
            }
        }
    }

    private var adminRecentBooksCard: some View {
        SourcesCard {
            Overline("Recent books")
            ForEach(model.recentBooks.prefix(6)) { book in
                HStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.ember)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title)
                            .font(.hearthUI(14, weight: .medium))
                            .foregroundStyle(hearth.text)
                            .lineLimit(1)
                        if let author = book.author {
                            Text(author)
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let progress = book.readProgress {
                            Text("\(Int(progress))%")
                                .font(.hearthUI(12, weight: .medium))
                                .foregroundStyle(progress >= 99 ? hearth.statusOK : hearth.ember)
                        }
                        if let status = book.readStatus {
                            Text(status.replacingOccurrences(of: "_", with: " ").lowercased())
                                .font(.hearthUI(11))
                                .foregroundStyle(hearth.textTertiary)
                        }
                    }
                }
                .frame(minHeight: 40)
            }
        }
    }
}
