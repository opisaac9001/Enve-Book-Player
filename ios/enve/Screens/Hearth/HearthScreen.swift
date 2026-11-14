import SwiftUI

struct HearthScreen: View {

    var isActive: Bool = true
    let profileSession: ProfileSession

    init(isActive: Bool = true, profileSession: ProfileSession) {
        self.isActive = isActive
        self.profileSession = profileSession
        _sectionOrder = State(initialValue: profileSession.preferences.loadPreferences().visibleHomeSections)
    }

    @Environment(EnveEngine.self) private var engine
    @Environment(AppState.self) private var appState
    @Environment(ProfileSwitchCoordinator.self) private var profiles
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.facingPageBookId) private var facingPageBookId
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var reading: [Book] = []
    @State private var listening: [Book] = []
    @State private var fresh: [Book] = []
    @State private var downloaded: [Book] = []
    @State private var rediscover: [RediscoverPick] = []
    @State private var rediscoverRefreshDate: Date?
    @State private var rediscoverLibraryCount: Int?
    @State private var heroTint: Color = Hearth.accent
    @State private var loaded = false
    @State private var seeAll: HearthSeeAll?
    @State private var lastOpenedBook: Book?
    @State private var pendingUnread: Book?
    @State private var sectionOrder: [UserPreferences.HomeSection]

    private var lastOpened: LastOpenedBookStore { profileSession.lastOpened }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header

                    if !engine.downloads.isNetworkAvailable {
                        offlineBanner
                            .padding(.horizontal, 24)
                    }

                    if loaded {
                        quote
                            .padding(.horizontal, 24)
                    } else {
                        loadingLibrary
                            .padding(.horizontal, 24)
                    }

                    if let hero {
                        if hero.stableId != facingPageBookId {
                            HearthBookCard(book: hero, sourceLabel: sourceLabel(for: hero), prominent: true)
                                .contextMenu { markUnreadButton(for: hero) }
                                .padding(.horizontal, 24)
                        }
                        HearthPulse(
                            activeCount: activeBookCount,
                            downloadedCount: downloaded.count,
                            freshCount: fresh.count,
                            progress: progressFraction(for: hero),
                            tint: heroTint
                        )
                        .padding(.horizontal, 24)
                    } else if loaded {
                        emptyHearth
                            .padding(.horizontal, 24)
                    }

                    ForEach(sectionOrder) { section in
                        homeSection(section)
                    }
                }
                .hearthReadableFrame(width: geo.size.width, maximum: HearthAdaptive.wideReadableWidth)
                .padding(.top, 8)
                .padding(.bottom, mantelInset + 16)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await engine.sync.manualSync()
                await engine.sources.refreshHearthCatalog()
                rediscoverRefreshDate = nil
                await load()
            }
        }
        .accessibilityIdentifier("hearth-screen")
        .navigationDestination(item: $seeAll) { destination in
            HearthSeeAllScreen(destination: destination)
        }
        .background(HearthBackground())
        .task(id: "\(isActive):\(lastOpened.openedAt?.timeIntervalSince1970 ?? 0)") {
            guard isActive else { return }
            // Subscribe before the first load so imports finishing during it still trigger a reload.
            let changes = engine.library.libraryChanges()
            rediscoverRefreshDate = nil
            await load()
            guard !Task.isCancelled else { return }
            var pendingReload: Task<Void, Never>?
            defer { pendingReload?.cancel() }
            for await _ in changes {
                pendingReload?.cancel()
                pendingReload = Task {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    await load()
                }
            }
        }
        .task(id: isActive) {
            guard isActive else { return }
            for await _ in AppRefreshEvents.stream(names: [.bookProgressDidChange], debounce: .milliseconds(500)) {
                await load(rediscovering: false)
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .preferencesDidChange) {
                sectionOrder =
                    profileSession.preferences
                    .loadPreferences()
                    .visibleHomeSections
                rediscoverRefreshDate = nil
                await load()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog(
            "Mark as unread?",
            isPresented: Binding(
                get: { pendingUnread != nil },
                set: { if !$0 { pendingUnread = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingUnread
        ) { book in
            Button("Mark as Unread", role: .destructive) { markUnread(book) }
            Button("Cancel", role: .cancel) {}
        } message: { book in
            Text("Your place in \"\(book.title)\" goes back to the beginning wherever it syncs. Bookmarks, highlights, and downloads stay.")
        }
    }

    @ViewBuilder
    private func homeSection(_ section: UserPreferences.HomeSection) -> some View {
        switch section {
        case .continueReading:
            if !shelfReading.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ShelfHeader(title: "Continue Reading", actionTitle: "See all") {
                        seeAll = HearthSeeAll(title: "Continue Reading", kind: .reading)
                    }
                    HearthContinueCarousel(books: shelfReading, sourceLabel: sourceLabel) { book in
                        shelfMenu(for: book, dismissable: true)
                    }
                }
            }
        case .continueListening:
            if !shelfListening.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ShelfHeader(title: "Continue Listening", actionTitle: "See all") {
                        seeAll = HearthSeeAll(title: "Continue Listening", kind: .listening)
                    }
                    HearthContinueCarousel(books: shelfListening, sourceLabel: sourceLabel) { book in
                        shelfMenu(for: book, dismissable: true)
                    }
                }
            }
        case .recentlyAdded:
            if !shelfFresh.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ShelfHeader(title: "Recently Added", actionTitle: "See all") {
                        seeAll = HearthSeeAll(title: "Recently Added", kind: .fresh)
                    }
                    shelf(books: shelfFresh)
                }
            }
        case .rediscover:
            if !rediscover.isEmpty {
                HearthRediscoverShelf(picks: rediscover) { book in
                    shelfMenu(for: book, dismissable: true)
                }
            }
        case .downloaded:
            if !downloaded.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ShelfHeader(title: "On this device")
                    shelf(books: downloaded)
                }
            }
        case .doorways:
            if loaded, hero != nil {
                doorways
            }
        }
    }

    private var header: some View {
        TabHeader(overline: HearthFormat.greeting(), title: "Hearth") {
            if let synced = engine.sync.lastSyncDate {
                Text("Progress synced \(synced.formatted(.relative(presentation: .named)))")
                    .font(.hearthUI(11))
                    .foregroundStyle(hearth.textTertiary)
            }
            if engine.sources.recentCatalogRefreshFailed {
                Text("Couldn't check for new books. Pull to retry.")
                    .font(.hearthUI(11))
                    .foregroundStyle(hearth.textSecondary)
                    .accessibilityIdentifier("hearth-catalog-refresh-failure")
            }
        } trailing: {
            if profiles.isEnabled {
                NavigationLink {
                    ProfilesScreen()
                } label: {
                    Image(systemName: profileSession.profile.role == .child ? "figure.child.circle" : "person.crop.circle")
                        .font(.hearthUI(22, weight: .medium))
                        .foregroundStyle(hearth.ember)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Profiles, \(profiles.activeProfile.name)")
                .accessibilityIdentifier("home-profiles")
            }
            NavigationLink {
                SettingsScreen(profileSession: profileSession)
            } label: {
                Image(systemName: "gearshape")
                    .font(.hearthUI(17, weight: .medium))
                    .foregroundStyle(hearth.textSecondary)
                    .frame(width: 40, height: 40)
                    .background {
                        Circle()
                            .fill(hearth.bgElevated)
                            .hearthOutlined(Circle())
                    }
            }
            .accessibilityLabel("Settings")
        }
    }

    private var hero: Book? {
        [lastOpenedBook, engine.playback.currentBook, reading.first, listening.first, fresh.first]
            .compactMap { $0 }
            .first(where: profileSession.preferences.includesLibraryBook)
    }

    private var shelfReading: [Book] {
        guard let hero else { return reading }
        return reading.filter { $0.stableId != hero.stableId }
    }

    private var shelfListening: [Book] {
        guard let hero else { return listening }
        return listening.filter { $0.stableId != hero.stableId }
    }

    private var shelfFresh: [Book] {
        guard let hero else { return fresh }
        return fresh.filter { $0.stableId != hero.stableId }
    }

    private var activeBookCount: Int {
        Set((reading + listening).map(\.stableId)).count
    }

    private func progressFraction(for book: Book) -> Double {
        engine.playback.progressFraction(for: book)
    }

    private func shelf(books: [Book]) -> some View {
        let shelfRatio = books.map(\.hearthCoverRatio).max() ?? 1
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(books, id: \.stableId) { book in
                    NavigationLink {
                        BookDetailScreen(book: book)
                    } label: {
                        VStack(alignment: .center, spacing: 16) {
                            ShelfCoverCell(book: book, width: 96, cellRatio: shelfRatio, showsProgress: false)
                            VStack(alignment: .center, spacing: 2) {
                                Text(book.title)
                                    .font(.hearthDisplay(13, weight: .medium))
                                    .foregroundStyle(hearth.text)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                if let byline = shelfByline(for: book) {
                                    Text(byline)
                                        .font(.hearthUI(11))
                                        .foregroundStyle(hearth.textSecondary)
                                        .lineLimit(1)
                                        .multilineTextAlignment(.center)
                                }
                                HearthSourceBadge(text: sourceLabel(for: book))
                            }
                            .frame(width: 96, alignment: .center)
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .contextMenu {
                        shelfMenu(for: book, dismissable: false)
                    }
                }
            }
            // The ledge sits in front of the covers so their bindings tuck behind the shelf lip.
            .overlay(alignment: .top) {
                ShelfLedge()
                    .padding(.top, 96 * shelfRatio - 1)
                    .padding(.horizontal, -10)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func shelfMenu(for book: Book, dismissable: Bool) -> some View {
        if dismissable {
            Button("Hide from Hearth", systemImage: "minus.circle") {
                dismissFromShelf(book)
            }
        }
        Button(
            book.isFinished ? "Mark Unfinished" : "Mark Finished",
            systemImage: book.isFinished ? "circle" : "checkmark.circle"
        ) {
            toggleFinished(book)
        }
        if hasProgress(book) {
            Button("Reset Progress", systemImage: "arrow.counterclockwise") {
                resetProgress(book)
            }
        }
        markUnreadButton(for: book)
        Button(book.mediaType == .ebook ? "Read" : "Listen", systemImage: book.mediaType == .ebook ? "book" : "play") {
            engine.playback.play(book)
        }
    }

    @ViewBuilder
    private func markUnreadButton(for book: Book) -> some View {
        if engine.library.canMarkUnread(book) {
            Button("Mark as Unread", systemImage: "book.closed") {
                if engine.library.markUnreadNeedsConfirmation(book) {
                    pendingUnread = book
                } else {
                    markUnread(book)
                }
            }
        }
    }

    private func shelfByline(for book: Book) -> String? {
        if book.isPodcastEpisode {
            return book.podcastName ?? PodcastsFormat.displayAuthor(book.author)
        }
        return book.author
    }

    private var doorways: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Doorways")
            VStack(spacing: 1) {
                HearthDoorway(glyph: "sparkles", title: "Discover", line: "Trending, bestsellers, and fresh releases") {
                    DiscoverScreen()
                }
                if hasPodcasts {
                    HearthDoorway(glyph: "dot.radiowaves.left.and.right", title: "Podcasts", line: "Your shows and new episodes") {
                        PodcastsHomeScreen()
                    }
                }
                if profileSession.isOwner && SettingsManager.shared.hardcoverApiKey != nil {
                    HearthDoorway(glyph: "person.2", title: "Hardcover", line: "Your reading circle") {
                        HardcoverHubScreen()
                    }
                }
            }
            .background(hearth.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous))
            .hearthOutlined(RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous), raised: true)
            .padding(.horizontal, 24)
        }
    }

    private func sourceLabel(for book: Book) -> String {
        if let connection = engine.library.sourceConnection(for: book), !connection.name.isEmpty {
            return connection.name
        }
        return book.source.hearthDisplayName
    }

    private func hasProgress(_ book: Book) -> Bool {
        book.isFinished || book.currentTime > 0 || book.canonicalEbookProgress > 0.001
    }

    private var hasPodcasts: Bool {
        !profileSession.podcastSubscriptions.feeds.isEmpty
            || engine.sources.hasActiveConnection(type: .audiobookshelf)
    }

    private var quote: some View {
        let q = HearthQuotes.daily
        return VStack(alignment: .leading, spacing: 8) {
            Text("\u{201C}\(q.text)\u{201D}")
                .font(.hearthDisplay(16, weight: .regular))
                .italic()
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Overline(q.author, color: hearth.textTertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hearth-quote")
    }

    private var loadingLibrary: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(hearth.ember)
            Text("Loading your library…")
                .font(.hearthUI(13, weight: .medium))
                .foregroundStyle(hearth.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hearth-loading")
    }

    private var offlineBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.hearthUI(13, weight: .medium))
                .foregroundStyle(hearth.statusWarn)
            Text("Offline. Your downloads are still here.")
                .font(.hearthUI(13, weight: .medium))
                .foregroundStyle(hearth.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Capsule()
                .fill(hearth.bgElevated)
                .hearthOutlined(Capsule())
        }
    }

    private func dismissFromShelf(_ book: Book) {
        profileSession.dismissedShelves.insert(stableId: book.stableId)
        withAnimation(reduceMotion ? nil : .snappy) {
            reading.removeAll { $0.stableId == book.stableId }
            listening.removeAll { $0.stableId == book.stableId }
            rediscover.removeAll { $0.id == book.stableId }
        }
        PlatformHaptics.impact(.light)
    }

    private func toggleFinished(_ book: Book) {
        let updated = engine.library.toggleFinished(book)
        replaceShelfBook(updated)
        PlatformHaptics.impact(book.isFinished ? .light : .medium)
        Task { await load() }
    }

    private func resetProgress(_ book: Book) {
        engine.library.resetProgressToBeginning(for: book)
        dismissFromShelf(book)
        Task { await load() }
    }

    private func markUnread(_ book: Book) {
        reading.removeAll { $0.stableId == book.stableId }
        listening.removeAll { $0.stableId == book.stableId }
        if lastOpenedBook?.stableId == book.stableId {
            lastOpenedBook = nil
        }
        PlatformHaptics.impact(.light)
        Task {
            await engine.library.markUnread(book)
            await load()
        }
    }

    private func replaceShelfBook(_ book: Book) {
        if let index = reading.firstIndex(where: { $0.stableId == book.stableId }) {
            reading[index] = book
        }
        if let index = listening.firstIndex(where: { $0.stableId == book.stableId }) {
            listening[index] = book
        }
    }

    private var emptyHearth: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                EmberGlow(tint: Hearth.accent, isBreathing: true, intensity: 0.8)
                    .frame(height: 180)
                    .mask(EllipticalGradient(colors: [.black, .clear], center: .center, startRadiusFraction: 0.15, endRadiusFraction: 0.5))
                VStack(spacing: 0) {
                    Image(systemName: "books.vertical.fill")
                        .font(.hearthUI(44))
                        .foregroundStyle(hearth.ember)
                    ShelfLedge()
                        .frame(width: 120)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)

            Text("Light the fire.")
                .font(.hearthDisplay(26))
                .foregroundStyle(hearth.text)
            Text("Connect a server or import your books, and your reading life gathers here.")
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            NavigationLink {
                SourcesQuickConnectScreen()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.hearthUI(15, weight: .semibold))
                    Text("Add a source")
                        .font(.hearthUI(16, weight: .semibold))
                }
                .foregroundStyle(hearth.readableOnEmber)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background {
                    HearthChromeBackground(shape: .capsule, fill: hearth.ember, tint: hearth.ember)
                }
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.vertical, 12)
    }

    private func load(rediscovering: Bool = true) async {
        if let stableId = lastOpened.stableId {
            let book = await engine.library.book(stableId: stableId)
            // A retired profile's task must not clear the persisted last-opened book.
            guard !Task.isCancelled else { return }
            lastOpenedBook = book
            if book == nil {
                lastOpened.clear()
                if appState.currentBook?.stableId == stableId {
                    appState.currentBook = nil
                }
            }
        } else {
            lastOpenedBook = nil
        }
        let feed = await engine.library.hearthFeed(
            dismissedStableIds: profileSession.dismissedShelves.stableIds,
            currentStableId: hero?.stableId
        )
        guard !Task.isCancelled else { return }
        listening = feed.listening
        reading = profileSession.preferences.readingEnabled ? feed.reading : []
        fresh = feed.fresh.filter(profileSession.preferences.includesLibraryBook)
        downloaded = feed.downloaded.filter(profileSession.preferences.includesLibraryBook)
        loaded = true

        var shown = Set((listening + reading).map(\.stableId))
        if let hero { shown.insert(hero.stableId) }
        var indexedCount: Int?
        var refreshPicks = false
        if rediscovering, sectionOrder.contains(.rediscover) {
            indexedCount = await appState.bookStore.bookCount()
            let expired = rediscoverRefreshDate.map { Date().timeIntervalSince($0) >= 15 * 60 } ?? true
            refreshPicks = expired || indexedCount != rediscoverLibraryCount
        }
        guard !Task.isCancelled else { return }
        if refreshPicks {
            let picks = await rediscoverPicks(excluding: shown)
            guard !Task.isCancelled else { return }
            rediscover = picks
            rediscoverRefreshDate = Date()
            rediscoverLibraryCount = indexedCount
        } else {
            let currentBooks = await appState.bookStore.booksByStableIds(Set(rediscover.map(\.id)))
            var remaining: [RediscoverPick] = []
            for pick in rediscover where !shown.contains(pick.id) {
                guard let current = currentBooks[pick.id],
                    !RediscoverPolicy.isCompleted(current)
                else { continue }
                guard !Task.isCancelled else { return }
                if pick.reason != .waiting && pick.reason != .nextInSeries || !RediscoverPolicy.isStarted(current) {
                    remaining.append(RediscoverPick(book: current, reason: pick.reason))
                }
            }
            guard !Task.isCancelled else { return }
            rediscover = remaining
        }

        if let hero {
            heroTint = await profileSession.ambientColors.resolve(for: hero)
        }
    }

    // Progress writes also notify library changes, so unchanged book counts reuse picks for 15 minutes.
    private func rediscoverPicks(excluding shown: Set<String>) async -> [RediscoverPick] {
        guard sectionOrder.contains(.rediscover) else { return [] }
        let library = profileSession.preferences
        let preferences = library.loadPreferences()
        let indexed = await appState.bookStore.allBooks()
        guard !Task.isCancelled else { return [] }
        let books = indexed.filter(library.includesLibraryBook)
        let exclusions = RediscoverPolicy.Exclusions(
            stableIds: shown
                .union(profileSession.dismissedShelves.stableIds)
                .union(preferences.hiddenBookIds)
                .union(profileSession.deletedBooks.allDeleted),
            libraryKeys: preferences.excludedLibraryIds
        )
        let now = Date()
        return await Task.detached(priority: .utility) {
            RediscoverPolicy.picks(from: books, now: now, calendar: .current, exclusions: exclusions)
        }.value
    }
}

private struct HearthRediscoverShelf<MenuItems: View>: View {
    let picks: [RediscoverPick]
    @ViewBuilder let menu: (Book) -> MenuItems

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var scaledCoverWidth: CGFloat = 104

    private var coverWidth: CGFloat { min(scaledCoverWidth, dynamicTypeSize.isAccessibilitySize ? 220 : 150) }

    private var shelfRatio: CGFloat {
        picks.map(\.book.hearthCoverRatio).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Rediscover")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(picks) { pick in
                        cell(pick)
                    }
                }
                .overlay(alignment: .top) {
                    ShelfLedge()
                        .padding(.top, coverWidth * shelfRatio - 1)
                        .padding(.horizontal, -10)
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hearth-rediscover")
    }

    private func cell(_ pick: RediscoverPick) -> some View {
        let book = pick.book
        return NavigationLink {
            BookDetailScreen(book: book)
        } label: {
            VStack(alignment: .center, spacing: 14) {
                ShelfCoverCell(book: book, width: coverWidth, cellRatio: shelfRatio, showsProgress: pick.reason != .waiting)
                VStack(alignment: .center, spacing: 6) {
                    reasonLabel(pick.reason)
                    Text(book.title)
                        .font(.hearthDisplay(13, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                        .multilineTextAlignment(.center)
                    if let author = book.author, !author.isEmpty {
                        Text(author)
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: coverWidth)
            }
        }
        .buttonStyle(PressableStyle())
        .contextMenu { menu(book) }
        .accessibilityLabel(accessibilityLabel(for: pick))
        .accessibilityHint("Opens book details")
        .accessibilityAction(named: book.mediaType == .ebook ? "Read" : "Listen") {
            engine.playback.play(book)
        }
        .accessibilityIdentifier("hearth-rediscover-\(book.stableId)")
    }

    private func reasonLabel(_ reason: RediscoverPick.Reason) -> some View {
        HStack(spacing: 4) {
            Image(systemName: reason.glyph)
                .foregroundStyle(hearth.ember)
                .accessibilityHidden(true)
            Text(reason.label)
                .foregroundStyle(hearth.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.hearthUI(10, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(hearth.emberSoft)
                .overlay(Capsule().strokeBorder(hearth.hairline.opacity(0.75), lineWidth: 1))
        }
    }

    private func accessibilityLabel(for pick: RediscoverPick) -> String {
        var parts = [pick.book.title]
        if let author = pick.book.author, !author.isEmpty { parts.append(author) }
        parts.append(pick.reason.label)
        return parts.joined(separator: ", ")
    }
}

private extension Book.BookSource {
    var hearthDisplayName: String {
        switch self {
        case .audiobookshelf: "Audiobookshelf"
        case .plex: "Plex"
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        case .local: "On Device"
        case .smb: "SMB"
        case .webdav: "WebDAV"
        case .booklore: "Grimmory"
        case .realdebrid: "RealDebrid"
        case .torbox: "TorBox"
        case .komga: "Komga"
        case .kavita: "Kavita"
        case .opds: "OPDS"
        case .storyteller: "Storyteller"
        case .bookOrbit: "BookOrbit"
        case .silo: "Silo"
        case .oneDrive: "OneDrive"
        }
    }
}

private struct HearthSourceBadge: View {
    let text: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        Text(text)
            .font(.hearthUI(10, weight: .semibold))
            .foregroundStyle(hearth.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(hearth.bg.opacity(0.62))
                    .overlay(Capsule().strokeBorder(hearth.hairline.opacity(0.75), lineWidth: 1))
            }
    }
}

struct HearthPulse: View {
    let activeCount: Int
    let downloadedCount: Int
    let freshCount: Int
    let progress: Double
    let tint: Color

    @Environment(\.hearth) private var hearth

    private let columns = Array(repeating: GridItem(.flexible(minimum: 58), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Overline("Today's stack", color: hearth.textTertiary)
                Spacer(minLength: 8)
                Text("\(progressPercent)% current")
                    .font(.hearthUI(11, weight: .semibold))
                    .foregroundStyle(tint)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                HearthPulseStat(icon: "flame", value: capped(activeCount, at: 32), label: "Continue", tint: tint)
                HearthPulseStat(icon: "arrow.down.circle", value: capped(downloadedCount, at: 16), label: "Saved", tint: hearth.statusOK)
                HearthPulseStat(icon: "sparkles", value: capped(freshCount, at: 12), label: "Added", tint: hearth.ember)
                HearthPulseStat(
                    icon: progress >= 0.98 ? "checkmark.seal.fill" : "chart.line.uptrend.xyaxis",
                    value: "\(progressPercent)%",
                    label: "Current",
                    tint: tint
                )
            }
        }
        .padding(15)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .fill(hearth.bgElevated.opacity(0.82))
                .hearthOutlined(RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous), raised: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var progressPercent: Int {
        Int((min(max(progress, 0), 1) * 100).rounded())
    }

    private func capped(_ value: Int, at cap: Int) -> String {
        value >= cap ? "\(cap)+" : "\(value)"
    }
}

private struct HearthPulseStat: View {
    let icon: String
    let value: String
    let label: String
    let tint: Color

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.hearthUI(13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(height: 14)
            Text(value)
                .font(.hearthDisplay(19, weight: .semibold))
                .foregroundStyle(hearth.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.hearthUI(10, weight: .medium))
                .foregroundStyle(hearth.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 82)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hearth.bg.opacity(0.42))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(hearth.hairline.opacity(0.75), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }
}
