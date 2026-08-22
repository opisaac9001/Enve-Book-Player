import SwiftUI

struct AdminKomgaScreen: View {
    let connection: ServerConnection
    @State private var model: AdminKomgaModel

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @State private var showingCreateReadList = false
    @State private var showingCreateCollection = false

    init(connection: ServerConnection) {
        self.connection = connection
        _model = State(initialValue: AdminKomgaModel(connection: connection))
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
                    adminServerCard
                    adminOverviewCard
                    if !model.libraries.isEmpty { adminLibrariesCard }
                    adminSeriesRail(title: "Newly shelved series", series: model.recentlyAddedSeries)
                    adminSeriesRail(title: "Recently updated", series: model.recentlyUpdatedSeries)
                    adminBooksRail(title: "On deck", books: model.onDeck)
                    adminBooksRail(title: "Latest books", books: model.latestBooks)
                    adminReadListsCard
                    adminCollectionsCard
                    if !model.announcements.isEmpty { adminAnnouncementsCard }
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
        .sheet(isPresented: $showingCreateReadList) {
            AdminKomgaCreateReadListSheet(model: model)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .sheet(isPresented: $showingCreateCollection) {
            AdminKomgaCreateCollectionSheet(model: model)
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

    private func adminUserCard(_ user: KomgaUser) -> some View {
        SourcesCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(hearth.emberSoft)
                        .frame(width: 48, height: 48)
                    Text(String(user.email.prefix(1)).uppercased())
                        .font(.hearthDisplay(20))
                        .foregroundStyle(hearth.ember)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.email)
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if user.isAdmin { AdminTag(text: "Admin", color: hearth.ember) }
                        if user.isPageStreaming { AdminTag(text: "Page streaming") }
                        if user.isFileDownload { AdminTag(text: "Downloads") }
                    }
                }
                Spacer()
            }
        }
    }

    private var adminServerCard: some View {
        SourcesCard {
            HStack {
                Overline("The server")
                Spacer()
                if let claim = model.claim {
                    AdminTag(
                        text: claim.isClaimed ? "Claimed" : "Unclaimed",
                        color: claim.isClaimed ? hearth.statusOK : hearth.statusWarn
                    )
                }
            }
            AdminInfoRow(label: "Version", value: model.serverInfo?.version ?? "-")
            AdminInfoRow(label: "Java", value: model.serverInfo?.javaVersion ?? "-")
            AdminInfoRow(label: "Host", value: URL(string: connection.url)?.host ?? connection.url)
        }
    }

    private var adminOverviewCard: some View {
        SourcesCard {
            Overline("At a glance")
            HStack(alignment: .top) {
                AdminStat(value: "\(model.libraries.count)", label: "Libraries")
                AdminStat(value: "\(model.totalSeriesCount)", label: "Series")
                AdminStat(value: "\(model.totalBookCount)", label: "Books")
            }
            HStack(alignment: .top) {
                AdminStat(value: "\(model.readLists.count)", label: "Read lists")
                AdminStat(value: "\(model.collections.count)", label: "Collections")
                Spacer().frame(maxWidth: .infinity)
            }
        }
    }

    private var adminLibrariesCard: some View {
        SourcesCard {
            Overline("Libraries")
            ForEach(model.libraries) { library in
                adminLibraryRow(library)
            }
        }
    }

    private func adminLibraryRow(_ library: KomgaLibraryDetail) -> some View {
        let stats = model.libraryStats[library.id]
        let busy = model.isLibraryBusy(library)
        return HStack(spacing: 12) {
            Image(systemName: library.unavailable == true ? "exclamationmark.triangle" : "books.vertical")
                .font(.hearthUI(15, weight: .medium))
                .foregroundStyle(library.unavailable == true ? hearth.statusWarn : hearth.ember)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(library.name)
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
                if let root = library.root {
                    Text(root)
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let stats {
                Text("\(stats.seriesCount) series · \(stats.bookCount) books")
                    .font(.hearthUI(11))
                    .foregroundStyle(hearth.textSecondary)
            }
            Menu {
                Button {
                    Task { await model.scanLibrary(library, deep: false) }
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                Button {
                    Task { await model.scanLibrary(library, deep: true) }
                } label: {
                    Label("Deep scan", systemImage: "scope")
                }
                Button {
                    Task { await model.analyzeLibrary(library) }
                } label: {
                    Label("Analyze files", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    Task { await model.refreshLibraryMetadata(library) }
                } label: {
                    Label("Refresh metadata", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    Task { await model.emptyLibraryTrash(library) }
                } label: {
                    Label("Empty trash", systemImage: "trash")
                }
            } label: {
                Group {
                    if busy {
                        ProgressView()
                            .tint(hearth.ember)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.hearthUI(14, weight: .semibold))
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .disabled(busy)
            .accessibilityLabel("Actions for \(library.name)")
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func adminSeriesRail(title: String, series: [KomgaSeriesSummary]) -> some View {
        if !series.isEmpty {
            SourcesCard {
                Overline(title)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(series) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                AdminRemoteThumb(url: model.seriesThumbURL(item.id), headers: model.imageHeaders)
                                Text(item.displayTitle)
                                    .font(.hearthUI(12, weight: .medium))
                                    .foregroundStyle(hearth.text)
                                    .lineLimit(2)
                                if let total = item.booksCount {
                                    let unread = item.booksUnreadCount ?? 0
                                    Text(unread > 0 ? "\(total) books · \(unread) unread" : "\(total) books")
                                        .font(.hearthUI(11))
                                        .foregroundStyle(hearth.textTertiary)
                                }
                            }
                            .frame(width: 88)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private func adminBooksRail(title: String, books: [KomgaBookSummary]) -> some View {
        if !books.isEmpty {
            SourcesCard {
                Overline(title)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(books) { book in
                            VStack(alignment: .leading, spacing: 6) {
                                AdminRemoteThumb(url: model.bookThumbURL(book.id), headers: model.imageHeaders)
                                Text(book.displayTitle)
                                    .font(.hearthUI(12, weight: .medium))
                                    .foregroundStyle(hearth.text)
                                    .lineLimit(2)
                                if let series = book.seriesTitle {
                                    Text(series)
                                        .font(.hearthUI(11))
                                        .foregroundStyle(hearth.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: 88)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var adminReadListsCard: some View {
        SourcesCard {
            HStack {
                Overline("Read lists")
                Spacer()
                GlyphButton(systemImage: "plus", size: 40, glyphSize: 15, label: "New read list") {
                    showingCreateReadList = true
                }
                .disabled(model.currentUser == nil)
            }
            if model.readLists.isEmpty {
                AdminEmptyText("No read lists yet. They gather books in any order you like.")
            } else {
                AdminLinkRow(
                    systemImage: "list.bullet.rectangle",
                    title: "\(model.readLists.count) read lists",
                    caption: model.readLists.prefix(3).map(\.name).joined(separator: ", ")
                ) {
                    AdminKomgaReadListsScreen(model: model)
                }
            }
        }
    }

    private var adminCollectionsCard: some View {
        SourcesCard {
            HStack {
                Overline("Collections")
                Spacer()
                GlyphButton(systemImage: "plus", size: 40, glyphSize: 15, label: "New collection") {
                    showingCreateCollection = true
                }
                .disabled(model.currentUser == nil)
            }
            if model.collections.isEmpty {
                AdminEmptyText("No collections yet. They gather whole series together.")
            } else {
                AdminLinkRow(
                    systemImage: "square.stack.3d.down.right",
                    title: "\(model.collections.count) collections",
                    caption: model.collections.prefix(3).map(\.name).joined(separator: ", ")
                ) {
                    AdminKomgaCollectionsScreen(model: model)
                }
            }
        }
    }

    private var adminAnnouncementsCard: some View {
        SourcesCard {
            Overline("From the developers")
            ForEach(model.announcements.prefix(3)) { announcement in
                VStack(alignment: .leading, spacing: 3) {
                    Text(announcement.title ?? "Announcement")
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.text)
                    if let content = announcement.content {
                        Text(content)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}
