import SwiftUI

struct AdminSiloScreen: View {
    let connection: ServerConnection
    @State private var model: AdminSiloModel

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    init(connection: ServerConnection) {
        self.connection = connection
        _model = State(initialValue: AdminSiloModel(connection: connection))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AdminHubHeader(connection: connection)

                if model.isLoading && !model.hasLoaded {
                    AdminLoadingRow("Asking the server for its ledger…")
                } else if model.me == nil && !model.isAuthorized && model.hasLoaded {
                    adminGate
                } else if model.hasLoaded {
                    if let me = model.me { adminAccountCard(me) }
                    personalReadingCard
                    personalDoorsCard
                    if model.isAuthorized {
                        adminServerCard
                        adminOverviewCard
                        if !model.readingLibraries.isEmpty { adminReadingCard }
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
                Text("Only a server owner or admin may tend this Silo.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
            }
            if let me = model.me {
                Text("You are signed in as \(me.displayName)\(me.role.map { ", a \($0) account" } ?? "").")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
            if let error = model.error {
                Text(error)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusError)
            }
        }
    }

    private func adminAccountCard(_ me: SiloMeUser) -> some View {
        SourcesCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(hearth.emberSoft)
                        .frame(width: 48, height: 48)
                    Text(String(me.displayName.prefix(1)).uppercased())
                        .font(.hearthDisplay(20))
                        .foregroundStyle(hearth.ember)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(me.displayName)
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if me.isAdmin { AdminTag(text: "Admin", color: hearth.ember) }
                        if let role = me.role, !me.isAdmin { AdminTag(text: role.capitalized) }
                        if me.enabled == false { AdminTag(text: "Disabled", color: hearth.statusError) }
                    }
                }
                Spacer()
            }
        }
    }

    private var personalReadingCard: some View {
        SourcesCard {
            Overline("Your reading")
            HStack(alignment: .top) {
                AdminStat(value: "\(model.personalFinished)", label: "Finished")
                AdminStat(value: "\(model.personalInProgress.count)", label: "Underway")
                AdminStat(value: AdminFormat.hours(model.personalSeconds), label: "Position")
            }
            if model.personalProgress.isEmpty {
                AdminEmptyText("Silo has no reading of yours to report yet.")
            }
        }
    }

    private var personalDoorsCard: some View {
        SourcesCard {
            AdminLinkRow(
                systemImage: "book",
                title: "Your books",
                caption: model.personalProgress.isEmpty
                    ? "What this profile has started and finished"
                    : "\(model.personalProgress.count) tracked on this profile"
            ) {
                AdminSiloReadingScreen(model: model)
            }
        }
    }

    private var adminServerCard: some View {
        SourcesCard {
            Overline("The server")
            AdminInfoRow(label: "Host", value: URL(string: connection.url)?.host ?? connection.url)
            AdminInfoRow(label: "Libraries", value: "\(model.libraries.count)")
            AdminInfoRow(label: "Storage", value: AdminFormat.bytes(Int(model.stats?.totalStorageBytes ?? 0)))
        }
    }

    private var adminOverviewCard: some View {
        SourcesCard {
            Overline("At a glance")
            HStack(alignment: .top) {
                AdminStat(value: "\(model.stats?.totalUsers ?? model.users.count)", label: "Users")
                AdminStat(value: "\(model.libraries.count)", label: "Libraries")
                AdminStat(value: "\(model.stats?.activeStreams ?? 0)", label: "Streaming")
            }
            HStack(alignment: .top) {
                AdminStat(value: "\(model.stats?.totalItems ?? 0)", label: "Items")
                AdminStat(value: "\(model.stats?.totalFiles ?? 0)", label: "Files")
                AdminStat(value: AdminFormat.bytes(Int(model.stats?.totalStorageBytes ?? 0)), label: "Storage")
            }
            if (model.stats?.totalMovies ?? 0) > 0 || (model.stats?.totalShows ?? 0) > 0 {
                HStack(alignment: .top) {
                    AdminStat(value: "\(model.stats?.totalMovies ?? 0)", label: "Movies")
                    AdminStat(value: "\(model.stats?.totalShows ?? 0)", label: "Shows")
                    Spacer().frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var adminReadingCard: some View {
        SourcesCard {
            Overline("On the shelves")
            HStack(alignment: .top) {
                AdminStat(value: "\(model.totalAudiobooks)", label: "Audiobooks")
                AdminStat(value: "\(model.totalEbooks)", label: "Ebooks")
                AdminStat(value: "\(model.readingLibraries.count)", label: "Book libraries")
            }
        }
    }

    private var adminDoorsCard: some View {
        SourcesCard {
            AdminLinkRow(
                systemImage: "person.2",
                title: "Users",
                caption: "\(model.users.count) accounts on this server"
            ) {
                AdminSiloUsersScreen(model: model)
            }
            AdminLinkRow(
                systemImage: "books.vertical",
                title: "Libraries & scans",
                caption: model.libraries.isEmpty
                    ? "None yet"
                    : model.libraries.map(\.name).prefix(3).joined(separator: ", ")
            ) {
                AdminSiloLibrariesScreen(model: model)
            }
            AdminLinkRow(
                systemImage: "chart.bar",
                title: "Reading & listening",
                caption: model.playbackHistory.isEmpty
                    ? "What the household has played"
                    : "\(AdminFormat.hours(model.historyTotalSeconds)) across recent sessions"
            ) {
                AdminSiloStatsScreen(model: model)
            }
        }
    }
}

struct AdminSiloReadingScreen: View {
    let model: AdminSiloModel

    @Environment(\.hearth) private var hearth

    var body: some View {
        AdminSubScreen(overline: model.connection.name, title: "Your books") {
            if model.personalProgress.isEmpty {
                AdminEmptyText(model.isLoading ? "Tallying the hours…" : "Silo has no reading of yours to report yet.")
            } else {
                SourcesCard {
                    Overline("At a glance")
                    HStack(alignment: .top) {
                        AdminStat(value: "\(model.personalProgress.count)", label: "Tracked")
                        AdminStat(value: "\(model.personalFinished)", label: "Finished")
                        AdminStat(value: "\(model.personalInProgress.count)", label: "Underway")
                    }
                }
                if !model.personalInProgress.isEmpty {
                    SourcesCard {
                        Overline("Underway")
                        ForEach(model.personalInProgress.prefix(25), id: \.uniqueId) { entry in
                            progressRow(entry)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func progressRow(_ entry: UserMediaProgress) -> some View {
        let book = model.personalBooks[entry.uniqueId]
        let row = VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(book?.title ?? "Item \(entry.libraryItemId)")
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                Spacer()
                Text("\(entry.progressPercent)%")
                    .font(.hearthUI(13, weight: .semibold))
                    .foregroundStyle(hearth.ember)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(book?.author ?? entry.lastUpdate.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(1)
                Spacer()
                Text(AdminFormat.hours(entry.currentTime))
                    .font(.hearthUI(11))
                    .foregroundStyle(hearth.textTertiary)
            }
            AdminProgressLine(fraction: entry.progress)
        }
        .padding(.vertical, 4)

        if let book {
            NavigationLink {
                BookDetailScreen(book: book)
            } label: {
                row.contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        } else {
            row
        }
    }
}

struct AdminSiloUsersScreen: View {
    let model: AdminSiloModel

    @Environment(\.hearth) private var hearth

    var body: some View {
        AdminSubScreen(overline: model.connection.name, title: "Users") {
            SourcesCard {
                Overline("Accounts")
                if model.users.isEmpty {
                    AdminEmptyText(model.isLoading ? "Fetching the accounts…" : "No accounts to show.")
                } else {
                    ForEach(model.users) { user in
                        adminUserRow(user)
                    }
                }
            }
        }
    }

    private func adminUserRow(_ user: SiloAdminUser) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.displayName)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    if let email = user.email, email != user.username {
                        Text(email)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if user.isAdmin {
                    AdminTag(text: "Admin", color: hearth.ember)
                } else if let role = user.role {
                    AdminTag(text: role.capitalized)
                }
                if user.enabled == false {
                    AdminTag(text: "Disabled", color: hearth.statusError)
                }
            }
            HStack(spacing: 6) {
                if let streams = user.maxStreams { AdminTag(text: "\(streams) streams") }
                if let quality = user.maxPlaybackQuality, !quality.isEmpty { AdminTag(text: quality) }
                if user.downloadAllowed == true { AdminTag(text: "Downloads") }
                if let libs = user.libraryIDs, !libs.isEmpty { AdminTag(text: "\(libs.count) libraries") }
            }
        }
        .padding(.vertical, 4)
    }
}

struct AdminSiloLibrariesScreen: View {
    let model: AdminSiloModel

    @Environment(\.hearth) private var hearth

    var body: some View {
        AdminSubScreen(overline: model.connection.name, title: "Libraries & scans") {
            SourcesCard {
                Overline("Libraries")
                if model.libraries.isEmpty {
                    AdminEmptyText(model.isLoading ? "Fetching the libraries…" : "No libraries to show.")
                } else {
                    ForEach(model.libraries) { library in
                        adminLibraryRow(library)
                    }
                }
            }

            if !model.scans.isEmpty {
                SourcesCard {
                    Overline("Recent scans")
                    ForEach(Array(model.scans.prefix(12).enumerated()), id: \.offset) { _, scan in
                        adminScanRow(scan)
                    }
                }
            }
        }
    }

    private func adminLibraryRow(_ library: SiloAdminLibrary) -> some View {
        let counts = model.libraryCounts[library.id]
        let scanning = model.isLibraryScanning(library)
        return HStack(spacing: 12) {
            Image(systemName: library.enabled == false ? "exclamationmark.triangle" : "books.vertical")
                .font(.hearthUI(15, weight: .medium))
                .foregroundStyle(library.enabled == false ? hearth.statusWarn : hearth.ember)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(library.name)
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
                if let counts, library.isReadingLibrary {
                    Text(adminCountsCaption(counts))
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                } else {
                    Text(library.type.capitalized)
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                }
            }
            Spacer()
            if scanning {
                ProgressView()
                    .tint(hearth.ember)
                    .scaleEffect(0.8)
                    .frame(width: 44, height: 44)
            } else {
                GlyphButton(systemImage: "arrow.clockwise", size: 40, glyphSize: 15, label: "Scan \(library.name)") {
                    Task { await model.scanLibrary(library) }
                }
            }
        }
        .frame(minHeight: 44)
    }

    private func adminCountsCaption(_ counts: AdminSiloModel.LibraryCounts) -> String {
        var parts: [String] = []
        if counts.audiobooks > 0 { parts.append("\(counts.audiobooks) audiobooks") }
        if counts.ebooks > 0 { parts.append("\(counts.ebooks) ebooks") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }

    private func adminScanRow(_ scan: SiloScan) -> some View {
        let library = scan.libraryID.flatMap { id in model.libraries.first { $0.id == id } }
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(library?.name ?? scan.path ?? "Scan")
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let mode = scan.mode { Text(mode.capitalized) }
                    if let trigger = scan.trigger { Text("· \(trigger)") }
                }
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let status = scan.status {
                    AdminTag(text: status.capitalized, color: adminScanColor(status))
                }
                if let date = scan.completedAt ?? scan.startedAt ?? scan.requestedAt {
                    Text(date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                }
            }
        }
        .frame(minHeight: 36)
    }

    private func adminScanColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "completed", "complete", "success", "done": return hearth.statusOK
        case "failed", "error": return hearth.statusError
        case "running", "in_progress", "scanning", "queued", "pending": return hearth.statusWarn
        default: return hearth.textSecondary
        }
    }
}

struct AdminSiloStatsScreen: View {
    let model: AdminSiloModel

    @Environment(\.hearth) private var hearth

    var body: some View {
        AdminSubScreen(overline: model.connection.name, title: "Reading & listening") {
            if model.playbackHistory.isEmpty {
                if model.isLoading {
                    AdminLoadingRow("Tallying the hours…")
                } else {
                    AdminEmptyText("The server has no playback to report yet.")
                }
            } else {
                SourcesCard {
                    Overline("Recent activity")
                    HStack(alignment: .top) {
                        AdminStat(value: AdminFormat.hours(model.historyTotalSeconds), label: "Played")
                        AdminStat(value: "\(model.historyCompleted)", label: "Completed")
                        AdminStat(value: "\(model.historyInProgress)", label: "In progress")
                    }
                    HStack(alignment: .top) {
                        AdminStat(value: "\(model.playbackHistory.count)", label: "Sessions")
                        AdminStat(value: "\(model.historyListeners)", label: "Listeners")
                        AdminStat(value: "\(model.totalAudiobooks + model.totalEbooks)", label: "On the shelves")
                    }
                }

                SourcesCard {
                    Overline("Recent sessions")
                    ForEach(Array(model.playbackHistory.prefix(20).enumerated()), id: \.offset) { _, entry in
                        adminSessionRow(entry)
                    }
                }
            }
        }
    }

    private func adminSessionRow(_ entry: SiloPlaybackEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.mediaTitle ?? "Untitled")
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                Spacer()
                Text(AdminFormat.hours(entry.watchedSeconds ?? 0))
                    .font(.hearthUI(13, weight: .medium))
                    .foregroundStyle(hearth.ember)
            }
            HStack(alignment: .firstTextBaseline) {
                Text([entry.username, entry.profileName].compactMap { $0 }.first ?? "Someone")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(1)
                Spacer()
                if entry.completed == true {
                    AdminTag(text: "Completed", color: hearth.statusOK)
                } else if let date = entry.startedAt {
                    Text(date.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                }
            }
            if let watched = entry.watchedSeconds, let duration = entry.durationSeconds, duration > 0 {
                AdminProgressLine(fraction: watched / duration)
            }
        }
        .padding(.vertical, 4)
    }
}
