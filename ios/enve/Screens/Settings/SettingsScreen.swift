import SwiftUI

struct SettingsScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dismiss) private var dismiss

    @State private var showTour = false
    @State private var bookCounts: [UUID: Int] = [:]
    @State private var smbSources: [SMBLibrarySource] = []
    @State private var showArchived = false
    @State private var koReaderDetail: String?
    @State private var hardcoverDetail: String?
    @State private var syncDetail: String?
    @State private var metadataKeysDetailText: String?
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                if !isSearchPresented || searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    connectedServicesGroup
                    settingsHub
                } else {
                    searchResults
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            searchDock
                .padding(.horizontal, 24)
                .padding(.bottom, isSearchFocused ? 8 : mantelInset)
        }
        .onChange(of: isSearchPresented) { _, presented in
            if presented {
                isSearchFocused = true
            }
        }
        .fullScreenCover(isPresented: $showTour) {
            HearthTour().enveEnvironment()
        }
        .onAppear(perform: refreshDetailChips)
        .task {
            refreshDetailChips()
            await loadBookCounts()
        }
        .task {
            smbSources = await SMBLibraryService.shared.getSources()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") { dismiss() }
            VStack(alignment: .leading, spacing: 6) {
                Overline("Sources & settings")
                Text("Settings")
                    .font(.hearthScreenTitle)
                    .foregroundStyle(hearth.text)
            }
            Spacer(minLength: 0)
        }
    }

    private var sourcesSnapshot: SettingsSourcesSnapshot {
        engine.sources.settingsSnapshot
    }

    private var activeConnections: [ServerConnection] {
        sourcesSnapshot.activeConnections
    }

    private var archivedConnections: [ServerConnection] {
        sourcesSnapshot.archivedConnections
    }

    private var settingsHub: some View {
        VStack(alignment: .leading, spacing: 12) {
            Overline("Browse")
            SourcesCard {
                settingsNav(
                    settingsCategory(
                        title: "Imports & companion apps",
                        subtitle: "Bring in OPDS catalogs and find the Enve video app"
                    ) { sourceUtilitiesGroup }
                ) {
                    SettingsLinkRow(
                        title: "Imports & companion apps",
                        subtitle: "OPDS catalogs and the Enve video app",
                        systemImage: "square.and.arrow.down.on.square.fill"
                    )
                }
                settingsNav(
                    settingsCategory(
                        title: "Library & content",
                        subtitle: "How books are organized, matched, and connected"
                    ) { libraryGroup }
                ) {
                    SettingsLinkRow(
                        title: "Library & content",
                        subtitle: "Display, metadata, collections, and reading tools",
                        systemImage: "books.vertical.fill"
                    )
                }
                settingsNav(
                    settingsCategory(
                        title: "Playback & experience",
                        subtitle: "Tune how Enve looks, sounds, and behaves"
                    ) { experienceGroup }
                ) {
                    SettingsLinkRow(
                        title: "Playback & experience",
                        subtitle: "Home, playback, appearance, and accessibility",
                        systemImage: "play.circle.fill"
                    )
                }
                settingsNav(
                    settingsCategory(
                        title: "Downloads & sync",
                        subtitle: "Offline files, storage, backups, and devices"
                    ) { storageGroup }
                ) {
                    SettingsLinkRow(
                        title: "Downloads & sync",
                        subtitle: "Downloads, storage, data, and iCloud",
                        detail: activeDownloadDetail,
                        systemImage: "icloud.fill"
                    )
                }
                settingsNav(
                    settingsCategory(
                        title: "Stats & history",
                        subtitle: "Milestones and listening history from other apps"
                    ) { statsGroup }
                ) {
                    SettingsLinkRow(
                        title: "Stats & history",
                        subtitle: "Achievements and imported listening history",
                        systemImage: "chart.bar.fill"
                    )
                }
                settingsNav(
                    settingsCategory(
                        title: "Advanced",
                        subtitle: "Server administration, API keys, and recovery tools"
                    ) { adminGroup }
                ) {
                    SettingsLinkRow(
                        title: "Advanced",
                        subtitle: "Server tools, API keys, and diagnostics",
                        systemImage: "gearshape.2.fill"
                    )
                }
                settingsNav(
                    settingsCategory(
                        title: "About Enve",
                        subtitle: "Version, news, support, and the welcome tour"
                    ) { aboutGroup }
                ) {
                    SettingsLinkRow(
                        title: "About Enve",
                        subtitle: "Version \(Self.versionString), news, and support",
                        systemImage: "info.circle.fill"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var searchDock: some View {
        if isSearchPresented {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.textTertiary)
                    TextField("Search settings", text: $searchText)
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($isSearchFocused)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.hearthUI(16))
                                .foregroundStyle(hearth.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 15)
                .frame(minHeight: 50)
                .background {
                    Capsule()
                        .fill(hearth.bgElevated)
                        .overlay(Capsule().strokeBorder(hearth.hairline, lineWidth: 1))
                        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
                }

                Button("Done") {
                    dismissSearch()
                }
                .font(.hearthUI(14, weight: .semibold))
                .foregroundStyle(hearth.ember)
                .buttonStyle(.plain)
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            HStack {
                Spacer()
                Button {
                    withAnimation(.snappy) {
                        isSearchPresented = true
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.hearthUI(18, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .frame(width: 52, height: 52)
                        .background {
                            Circle()
                                .fill(hearth.bgElevated)
                                .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
                                .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
                        }
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Search settings")
            }
            .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
        }
    }

    private func dismissSearch() {
        isSearchFocused = false
        searchText = ""
        withAnimation(.snappy) {
            isSearchPresented = false
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = filteredSearchItems
        if results.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No settings found")
                    .font(.hearthDisplay(20, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Text("Try a feature, service, or setting name.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
            }
            .padding(.vertical, 12)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Overline(results.count == 1 ? "1 result" : "\(results.count) results")
                SourcesCard {
                    ForEach(results) { item in
                        if item.destination == .tour {
                            Button {
                                showTour = true
                            } label: {
                                SettingsLinkRow(
                                    title: item.title,
                                    subtitle: item.subtitle,
                                    systemImage: item.systemImage
                                )
                            }
                            .buttonStyle(PressableStyle())
                        } else {
                            settingsNav(searchDestination(item.destination)) {
                                SettingsLinkRow(
                                    title: item.title,
                                    subtitle: item.subtitle,
                                    systemImage: item.systemImage
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var filteredSearchItems: [SettingsSearchItem] {
        let words = searchText
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        return SettingsSearchItem.all.filter { item in
            let haystack = item.searchableText.folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: .current
            )
            return words.allSatisfy { haystack.localizedStandardContains(String($0)) }
        }
    }

    @ViewBuilder
    private func searchDestination(_ destination: SettingsSearchDestination) -> some View {
        switch destination {
        case .sources:
            settingsCategory(title: "Sources & servers", subtitle: "Connections, imports, and server libraries") { sourcesGroup }
        case .opds: SourcesOPDSBulkScreen()
        case .video: VideoPromoScreen()
        case .libraryDisplay: LibraryDisplayScreen()
        case .metadataMatching: MetadataBatchScreen()
        case .pendingMatches: PendingMatchesScreen()
        case .collections: CollectionsScreen()
        case .duplicates: WorkSuggestionsScreen()
        case .bookSync: BookSyncScreen()
        case .storyAlign: StoryAlignScreen()
        case .koReader: KOReaderScreen()
        case .hardcover: HardcoverHubScreen()
        case .vocabulary: VocabularyHubScreen()
        case .dictionaries: DictionariesScreen()
        case .obsidian: ObsidianScreen()
        case .dragAndDrop: DragAndDropScreen()
        case .hiddenBooks: HiddenBooksScreen()
        case .recentlyDeleted: RecentlyDeletedScreen()
        case .home: HomePreferencesScreen()
        case .comicReader: ComicReaderSettingsScreen()
        case .playback: PlaybackScreen()
        case .appearance: AppearanceScreen()
        case .accessibility: AccessibilityScreen()
        case .downloads: DownloadsScreen()
        case .storage: StorageScreen()
        case .dataManagement: DataManagementScreen()
        case .sync: SyncScreen()
        case .achievements: AchievementsScreen()
        case .statsImport: StatsImportScreen()
        case .advanced:
            settingsCategory(title: "Advanced", subtitle: "Server administration, API keys, and recovery tools") { adminGroup }
        case .metadataKeys: MetadataKeysScreen()
        case .orphanedBooks: OrphanedBookMatcherScreen()
        case .news: NewsScreen()
        case .tipJar: TipJarScreen()
        case .reportIssue: ReportIssueScreen()
        case .tour:
            EmptyView()
        }
    }

    private var connectedServicesGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Overline("Connected services")
            connectionsCard
        }
    }

    private var sourcesGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            connectionsCard
            sourceUtilitiesGroup
        }
    }

    private var sourceUtilitiesGroup: some View {
        SourcesCard {
            settingsNav(SourcesOPDSBulkScreen()) {
                SettingsLinkRow(
                    title: "OPDS import",
                    subtitle: "Download a feed into a collection",
                    systemImage: "tray.and.arrow.down.fill"
                )
            }
            settingsNav(VideoPromoScreen()) {
                SettingsLinkRow(title: "Video player", subtitle: "Now its own free app", systemImage: "play.tv.fill")
            }
        }
    }

    private var connectionsCard: some View {
        SourcesCard {
            if let progress = sourcesSnapshot.importProgress, !progress.isComplete {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(hearth.ember)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(progress.headerText)
                            .font(.hearthCaption.weight(.medium))
                            .foregroundStyle(hearth.text)
                        Text(progress.displayText)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
            }

            if activeConnections.isEmpty && smbSources.isEmpty {
                Text("Nothing connected yet.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
            }

            ForEach(activeConnections) { connection in
                NavigationLink {
                    SourceDetailScreen(connectionId: connection.id)
                } label: {
                    SettingsSourceRow(
                        connection: connection,
                        needsReauth: sourcesSnapshot.reauthConnectionIds.contains(connection.id),
                        bookCount: bookCounts[connection.id]
                    )
                }
                .buttonStyle(PressableStyle())
            }

            ForEach(smbSources) { source in
                SettingsSMBRow(source: source) {
                    Task {
                        await SMBLibraryService.shared.deleteSource(id: source.id)
                        smbSources = await SMBLibraryService.shared.getSources()
                    }
                }
            }

            if !archivedConnections.isEmpty {
                Button {
                    withAnimation(.snappy) { showArchived.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.hearthUI(11, weight: .semibold))
                            .rotationEffect(.degrees(showArchived ? 90 : 0))
                        Text("\(archivedConnections.count) archived")
                            .font(.hearthCaption)
                    }
                    .foregroundStyle(hearth.textTertiary)
                }
                if showArchived {
                    ForEach(archivedConnections) { connection in
                        NavigationLink {
                            SourceDetailScreen(connectionId: connection.id)
                        } label: {
                            SettingsSourceRow(connection: connection, needsReauth: false, bookCount: nil)
                                .opacity(0.55)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }

            NavigationLink {
                SourcesQuickConnectScreen()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.hearthUI(15, weight: .semibold))
                    Text("Add a source")
                        .font(.hearthUI(16, weight: .semibold))
                }
                .foregroundStyle(hearth.onEmber)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(hearth.ember, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .padding(.top, 4)
        }
    }

    private var libraryGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourcesCard {
                settingsNav(LibraryDisplayScreen()) {
                    SettingsLinkRow(title: "Library display", subtitle: "Cards, titles, grouping", systemImage: "text.book.closed.fill")
                }
                settingsNav(MetadataBatchScreen()) {
                    SettingsLinkRow(
                        title: "Bulk metadata matching",
                        subtitle: "Match an entire library at once",
                        systemImage: "wand.and.stars"
                    )
                }
                settingsNav(PendingMatchesScreen()) {
                    SettingsLinkRow(title: "Pending matches", subtitle: "Review uncertain metadata matches", systemImage: "checklist")
                }
                settingsNav(CollectionsScreen()) {
                    SettingsLinkRow(title: "Collections", subtitle: "Smart and handmade shelves", systemImage: "rectangle.stack.fill")
                }
                settingsNav(WorkSuggestionsScreen()) {
                    SettingsLinkRow(
                        title: "Possible duplicates",
                        subtitle: "Review copies that share an identifier",
                        systemImage: "square.on.square"
                    )
                }
                settingsNav(BookSyncScreen()) {
                    SettingsLinkRow(title: "Book sync", subtitle: "Ebook and audiobook, joined", systemImage: "arrow.left.arrow.right")
                }
                settingsNav(StoryAlignScreen()) {
                    SettingsLinkRow(title: "StoryAlign", subtitle: "Make read-aloud EPUBs", systemImage: "waveform")
                }
                settingsNav(KOReaderScreen()) {
                    SettingsLinkRow(
                        title: "KOReader",
                        subtitle: "Share positions with your e-reader",
                        detail: koReaderDetail,
                        systemImage: "book.pages"
                    )
                }
                settingsNav(HardcoverHubScreen()) {
                    SettingsLinkRow(
                        title: "Hardcover",
                        subtitle: "Profile, goals, friends, trending",
                        detail: hardcoverDetail,
                        systemImage: "book.closed.fill"
                    )
                }
            }
            SourcesCard {
                settingsNav(VocabularyHubScreen()) {
                    SettingsLinkRow(title: "Vocabulary", subtitle: "Saved words and flashcards", systemImage: "character.book.closed.fill")
                }
                settingsNav(DictionariesScreen()) {
                    SettingsLinkRow(title: "Dictionaries", subtitle: "Offline StarDict lookups", systemImage: "character.book.closed")
                }
                settingsNav(ObsidianScreen()) {
                    SettingsLinkRow(title: "Obsidian", subtitle: "Notes as Markdown, into your vault", systemImage: "doc.text.fill")
                }
                settingsNav(DragAndDropScreen()) {
                    SettingsLinkRow(title: "Drag & drop", subtitle: "Files dropped in from a computer", systemImage: "arrow.down.doc.fill")
                }
                settingsNav(HiddenBooksScreen()) {
                    SettingsLinkRow(title: "Hidden books", systemImage: "eye.slash")
                }
                settingsNav(RecentlyDeletedScreen()) {
                    SettingsLinkRow(title: "Recently deleted", systemImage: "trash")
                }
            }
        }
    }

    private var experienceGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourcesCard {
                settingsNav(HomePreferencesScreen()) {
                    SettingsLinkRow(title: "Home & startup", subtitle: "Start tab and Hearth shelf order", systemImage: "house.fill")
                }
                settingsNav(ComicReaderSettingsScreen()) {
                    SettingsLinkRow(
                        title: "Comic reader",
                        subtitle: "Streaming, preloading, and page cache",
                        systemImage: "books.vertical.fill"
                    )
                }
                settingsNav(PlaybackScreen()) {
                    SettingsLinkRow(title: "Playback", subtitle: "Speed, skips, smart rewind, sleep timer", systemImage: "play.circle.fill")
                }
                settingsNav(AppearanceScreen()) {
                    SettingsLinkRow(title: "Appearance", subtitle: "Theme, accent, navigation", systemImage: "paintbrush.fill")
                }
                settingsNav(AccessibilityScreen()) {
                    SettingsLinkRow(title: "Accessibility", subtitle: "Vision-impaired mode, VoiceOver", systemImage: "accessibility")
                }
            }
        }
    }

    private var storageGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourcesCard {
                settingsNav(DownloadsScreen()) {
                    SettingsLinkRow(
                        title: "Downloads",
                        subtitle: "Active, failed, and finished",
                        detail: activeDownloadDetail,
                        systemImage: "arrow.down.circle.fill"
                    )
                }
                settingsNav(StorageScreen()) {
                    SettingsLinkRow(
                        title: "Storage",
                        subtitle: "What's on the phone, and the cleanup rules",
                        systemImage: "internaldrive.fill"
                    )
                }
                settingsNav(DataManagementScreen()) {
                    SettingsLinkRow(
                        title: "Data management",
                        subtitle: "Clear caches, metadata, or reset Enve",
                        systemImage: "trash.circle.fill"
                    )
                }
                settingsNav(SyncScreen()) {
                    SettingsLinkRow(
                        title: "Sync",
                        subtitle: "iCloud, across your devices",
                        detail: syncDetail,
                        systemImage: "icloud.and.arrow.up.fill"
                    )
                }
            }
        }
    }

    private var activeDownloadDetail: String? {
        let count = engine.downloads.activeTasks.count
        return count == 0 ? nil : "\(count) active"
    }

    private var statsGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourcesCard {
                settingsNav(AchievementsScreen()) {
                    SettingsLinkRow(title: "Achievements", subtitle: "Levels and milestones", systemImage: "trophy.fill")
                }
                settingsNav(StatsImportScreen()) {
                    SettingsLinkRow(
                        title: "Import listening history",
                        subtitle: "Bring stats in from elsewhere",
                        systemImage: "square.and.arrow.down"
                    )
                }
            }
        }
    }

    private static let serverHubTypes: Set<ProviderType> = [
        .audiobookshelf, .plex, .jellyfin, .emby, .komga, .booklore, .silo, .kavita, .bookOrbit,
        .storyteller,
    ]

    private var adminConnections: [ServerConnection] {
        activeConnections.filter { Self.serverHubTypes.contains($0.type) }
    }

    @ViewBuilder
    private var adminGroup: some View {
        let connections = adminConnections
        VStack(alignment: .leading, spacing: 12) {
            SourcesCard {
                if connections.isEmpty {
                    Text("Server tools appear here once a supported source is connected.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(connections) { connection in
                        settingsNav(AdminHubScreen(connection: connection)) {
                            SettingsLinkRow(title: connection.name, subtitle: "Server tools", systemImage: "server.rack")
                        }
                    }
                }

                Divider().overlay(hearth.hairline)

                settingsNav(MetadataKeysScreen()) {
                    SettingsLinkRow(
                        title: "Metadata API keys",
                        subtitle: "Google Books and ComicVine",
                        detail: metadataKeysDetailText,
                        systemImage: "key.fill"
                    )
                }
                settingsNav(OrphanedBookMatcherScreen()) {
                    SettingsLinkRow(
                        title: "Orphaned books",
                        subtitle: "Re-home progress from removed sources",
                        systemImage: "questionmark.folder"
                    )
                }
                #if DEBUG
                settingsNav(DiagnosticsScreen()) {
                    SettingsLinkRow(title: "Diagnostics", subtitle: "Synthetic library tooling", systemImage: "ladybug.fill")
                }
                #endif
            }
        }
    }

    private var aboutGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourcesCard {
                HStack {
                    Text("Enve")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                    Spacer()
                    Text(Self.versionString)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                settingsNav(NewsScreen()) {
                    SettingsLinkRow(title: "News", subtitle: "Notes from the developer", systemImage: "newspaper.fill")
                }
                settingsNav(TipJarScreen()) {
                    SettingsLinkRow(title: "Tip jar", subtitle: "Entirely optional", systemImage: "heart.circle.fill")
                }
                settingsNav(ReportIssueScreen()) {
                    SettingsLinkRow(
                        title: "Report an issue",
                        subtitle: "Logs included, secrets scrubbed",
                        systemImage: "exclamationmark.bubble.fill"
                    )
                }
                Button {
                    showTour = true
                } label: {
                    SettingsLinkRow(
                        title: "Replay the tour",
                        subtitle: "See the welcome walkthrough again",
                        systemImage: "questionmark.circle.fill"
                    )
                }
                .buttonStyle(PressableStyle())
            }
            SourcesCard {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "flame")
                        .font(.hearthUI(18))
                        .foregroundStyle(hearth.ember)
                    Text(
                        "This version of Enve is a complete rework of the iOS app, with the same feature set and a quieter Hearth interface."
                    )
                    .font(.hearthDisplay(16, weight: .regular))
                    .foregroundStyle(hearth.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build { return "\(version) (\(build))" }
        return version
    }

    private var metadataKeysDetail: String? {
        let google = !(SettingsManager.shared.googleBooksApiKey?.isEmpty ?? true)
        let comic = !(SettingsManager.shared.comicVineApiKey?.isEmpty ?? true)
        switch (google, comic) {
        case (true, true): return "2 saved"
        case (true, false), (false, true): return "1 saved"
        case (false, false): return nil
        }
    }

    private func refreshDetailChips() {
        koReaderDetail = KOReaderSyncService.shared.config.isConfigured ? "Connected" : nil
        hardcoverDetail = SettingsManager.shared.hardcoverApiKey == nil ? nil : "Connected"
        syncDetail = engine.sync.syncEnabled ? "On" : "Off"
        metadataKeysDetailText = metadataKeysDetail
    }

    private func settingsNav<Destination: View, Label: View>(
        _ destination: Destination,
        @ViewBuilder label: () -> Label
    ) -> some View {
        NavigationLink {
            AnyView(destination)
        } label: {
            label()
        }
        .buttonStyle(PressableStyle())
    }

    private func settingsCategory<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        SettingsScaffold(overline: "Settings", title: title, subtitle: subtitle) {
            content()
        }
    }

    private func loadBookCounts() async {
        bookCounts = await engine.sources.bookCountsByConnection(activeConnections)
    }
}

private enum SettingsSearchDestination: String {
    case sources, opds, video, libraryDisplay, metadataMatching, pendingMatches, collections, duplicates
    case bookSync, storyAlign, koReader, hardcover, vocabulary, dictionaries, obsidian, dragAndDrop
    case hiddenBooks, recentlyDeleted, home, comicReader, playback, appearance, accessibility
    case downloads, storage, dataManagement, sync, achievements, statsImport, advanced, metadataKeys
    case orphanedBooks, news, tipJar, reportIssue, tour
}

private struct SettingsSearchItem: Identifiable {
    let destination: SettingsSearchDestination
    let title: String
    let subtitle: String
    let systemImage: String
    let keywords: String

    var id: String { destination.rawValue }
    var searchableText: String { "\(title) \(subtitle) \(keywords)" }

    static let all: [SettingsSearchItem] = [
        item(.sources, "Sources & servers", "Connections and server libraries", "server.rack", "add source smb plex jellyfin emby audiobookshelf komga kavita booklore silo bookorbit"),
        item(.opds, "OPDS import", "Download a feed into a collection", "tray.and.arrow.down.fill", "catalog feed"),
        item(.video, "Video player", "The companion video app", "play.tv.fill", "plex movies television"),
        item(.libraryDisplay, "Library display", "Cards, titles, and grouping", "text.book.closed.fill", "covers shelves sort"),
        item(.metadataMatching, "Bulk metadata matching", "Match an entire library", "wand.and.stars", "google books comicvine isbn"),
        item(.pendingMatches, "Pending matches", "Review uncertain metadata", "checklist", "metadata review"),
        item(.collections, "Collections", "Smart and handmade shelves", "rectangle.stack.fill", "groups shelves"),
        item(.duplicates, "Possible duplicates", "Review duplicate books", "square.on.square", "copies identifiers"),
        item(.bookSync, "Book sync", "Join ebook and audiobook editions", "arrow.left.arrow.right", "readaloud progress"),
        item(.storyAlign, "StoryAlign", "Make read-aloud EPUBs", "waveform", "alignment audio text epub"),
        item(.koReader, "KOReader", "Share positions with your e-reader", "book.pages", "kosync progress"),
        item(.hardcover, "Hardcover", "Profile, goals, friends, and trending", "book.closed.fill", "social sync"),
        item(.vocabulary, "Vocabulary", "Saved words and flashcards", "character.book.closed.fill", "words study"),
        item(.dictionaries, "Dictionaries", "Offline StarDict lookups", "character.book.closed", "definition language"),
        item(.obsidian, "Obsidian", "Export notes as Markdown", "doc.text.fill", "vault highlights annotations"),
        item(.dragAndDrop, "Drag & drop", "Files dropped in from a computer", "arrow.down.doc.fill", "import files"),
        item(.hiddenBooks, "Hidden books", "Manage books hidden from the library", "eye.slash", "visibility"),
        item(.recentlyDeleted, "Recently deleted", "Recover removed books", "trash", "restore"),
        item(.home, "Home & startup", "Start tab and Hearth shelf order", "house.fill", "launch start screen"),
        item(.comicReader, "Comic reader", "Streaming, preloading, and page cache", "books.vertical.fill", "cbz manga pages"),
        item(.playback, "Playback", "Speed, skips, smart rewind, and sleep timer", "play.circle.fill", "audio shake snooze sleep health"),
        item(.appearance, "Appearance", "Theme, accent, and navigation", "paintbrush.fill", "dark light oled color"),
        item(.accessibility, "Accessibility", "Vision-impaired mode and VoiceOver", "accessibility", "text size reduce motion"),
        item(.downloads, "Downloads", "Active, failed, and finished", "arrow.down.circle.fill", "offline queue"),
        item(.storage, "Storage", "Files on this phone and cleanup rules", "internaldrive.fill", "disk cache space"),
        item(.dataManagement, "Data management", "Clear caches, metadata, or reset Enve", "trash.circle.fill", "erase reset cleanup"),
        item(.sync, "Sync", "iCloud across your devices", "icloud.and.arrow.up.fill", "cloud backup progress"),
        item(.achievements, "Achievements", "Levels and milestones", "trophy.fill", "goals awards journal"),
        item(.statsImport, "Import listening history", "Bring stats in from another app", "square.and.arrow.down", "statistics data"),
        item(.advanced, "Server tools", "Administration and recovery", "gearshape.2.fill", "advanced developer diagnostics admin"),
        item(.metadataKeys, "Metadata API keys", "Google Books and ComicVine", "key.fill", "credentials"),
        item(.orphanedBooks, "Orphaned books", "Re-home progress from removed sources", "questionmark.folder", "recovery missing"),
        item(.news, "News", "Notes from the developer", "newspaper.fill", "updates changelog"),
        item(.tipJar, "Tip jar", "Support Enve", "heart.circle.fill", "donate"),
        item(.reportIssue, "Report an issue", "Send logs with secrets scrubbed", "exclamationmark.bubble.fill", "bug support feedback"),
        item(.tour, "Replay the tour", "See the welcome walkthrough again", "questionmark.circle.fill", "help onboarding tutorial"),
    ]

    private static func item(
        _ destination: SettingsSearchDestination,
        _ title: String,
        _ subtitle: String,
        _ systemImage: String,
        _ keywords: String
    ) -> SettingsSearchItem {
        SettingsSearchItem(
            destination: destination,
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            keywords: keywords
        )
    }
}

private struct SettingsSourceRow: View {
    let connection: ServerConnection
    let needsReauth: Bool
    let bookCount: Int?

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 12) {
            SourcesProviderLogo(assetName: connection.iconAssetName, systemName: connection.iconSystemName)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                    .font(.hearthBody.weight(.medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                Text(URL(string: connection.url)?.host ?? connection.url)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if let bookCount, bookCount > 0 {
                Text("\(bookCount)")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Image(systemName: "chevron.right")
                .font(.hearthUI(12, weight: .semibold))
                .foregroundStyle(hearth.textTertiary)
        }
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        if needsReauth { return hearth.statusWarn }
        return connection.isConnected ? hearth.statusOK : hearth.textTertiary
    }
}

private struct SettingsSMBRow: View {
    let source: SMBLibrarySource
    let onDelete: () -> Void

    @Environment(\.hearth) private var hearth
    @State private var isScanning = false

    var body: some View {
        HStack(spacing: 12) {
            SourcesProviderLogo(assetName: nil, systemName: "externaldrive.connected.to.line.below")
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.hearthBody.weight(.medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                Text("\(source.hostname)/\(source.shareName)")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if isScanning {
                ProgressView().tint(hearth.ember)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                isScanning = true
                Task {
                    _ = try? await SMBLibraryService.shared.scanLibrary(source, mode: .quick)
                    NotificationCenter.default.post(name: .localLibraryUpdated, object: nil)
                    isScanning = false
                }
            } label: {
                Label("Scan again", systemImage: "arrow.triangle.2.circlepath")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}
