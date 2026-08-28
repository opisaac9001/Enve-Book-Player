import SwiftUI

struct HearthScreen: View {

    var isActive: Bool = true

    @Environment(EnveEngine.self) private var engine
    @Environment(AppState.self) private var appState
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var reading: [Book] = []
    @State private var listening: [Book] = []
    @State private var fresh: [Book] = []
    @State private var downloaded: [Book] = []
    @State private var heroTint: Color = Hearth.accent
    @State private var loaded = false
    @State private var seeAll: HearthSeeAll?
    @State private var lastOpenedBook: Book?
    @State private var sectionOrder = LibraryDisplayPreferencesStore.shared
        .loadPreferences()
        .normalizedHomeSectionOrder

    private let lastOpened = LastOpenedBookStore.shared

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
                    }

                    if let hero {
                        HearthHero(book: hero, tint: heroTint)
                            .padding(.horizontal, 24)
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
        }
        .accessibilityIdentifier("hearth-screen")
        .navigationDestination(item: $seeAll) { destination in
            HearthSeeAllScreen(destination: destination)
        }
        .background(HearthBackground())
        .refreshable {
            await engine.sync.manualSync()
            await load()
        }
        .task(id: "\(isActive):\(lastOpened.openedAt?.timeIntervalSince1970 ?? 0)") {
            guard isActive else { return }
            await load()
            loaded = true
            var pendingReload: Task<Void, Never>?
            defer { pendingReload?.cancel() }
            for await _ in engine.library.libraryChanges() {
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
                await load()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .preferencesDidChange) {
                sectionOrder =
                    LibraryDisplayPreferencesStore.shared
                    .loadPreferences()
                    .normalizedHomeSectionOrder
            }
        }
        .toolbar(.hidden, for: .navigationBar)
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
                    shelf(books: shelfReading, width: 108, showsProgress: true, dismissable: true)
                }
            }
        case .continueListening:
            if !shelfListening.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ShelfHeader(title: "Continue Listening", actionTitle: "See all") {
                        seeAll = HearthSeeAll(title: "Continue Listening", kind: .listening)
                    }
                    shelf(books: shelfListening, width: 108, showsProgress: true, dismissable: true)
                }
            }
        case .recentlyAdded:
            if !shelfFresh.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ShelfHeader(title: "Recently Added", actionTitle: "See all") {
                        seeAll = HearthSeeAll(title: "Recently Added", kind: .fresh)
                    }
                    shelf(books: shelfFresh, width: 96, showsProgress: false, dismissable: false)
                }
            }
        case .downloaded:
            if !downloaded.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ShelfHeader(title: "On this device")
                    shelf(books: downloaded, width: 96, showsProgress: false, dismissable: false)
                }
            }
        case .doorways:
            if loaded, hero != nil {
                doorways
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Overline(HearthFormat.greeting())
                Text("Hearth")
                    .font(.hearthScreenTitle)
                    .foregroundStyle(hearth.text)
                if let synced = engine.sync.lastSyncDate {
                    Text("Synced \(synced.formatted(.relative(presentation: .named)))")
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                }
            }
            Spacer()
            NavigationLink {
                SettingsScreen()
            } label: {
                Image(systemName: "gearshape")
                    .font(.hearthUI(17, weight: .medium))
                    .foregroundStyle(hearth.textSecondary)
                    .frame(width: 40, height: 40)
                    .background {
                        Circle()
                            .fill(hearth.bgElevated)
                            .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
                    }
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 24)
    }

    private var hero: Book? {
        lastOpenedBook ?? engine.playback.currentBook ?? reading.first ?? listening.first ?? fresh.first
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

    private func shelf(books: [Book], width: CGFloat, showsProgress: Bool, dismissable: Bool) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(books, id: \.stableId) { book in
                    NavigationLink {
                        BookDetailScreen(book: book)
                    } label: {
                        VStack(alignment: .center, spacing: 8) {
                            ShelfCoverCell(book: book, width: width, showsProgress: showsProgress)
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
                            .frame(width: width, alignment: .center)
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .contextMenu {
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
                        Button(book.mediaType == .ebook ? "Read" : "Listen", systemImage: book.mediaType == .ebook ? "book" : "play") {
                            engine.playback.play(book)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
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
                if SettingsManager.shared.hardcoverApiKey != nil {
                    HearthDoorway(glyph: "person.2", title: "Hardcover", line: "Your reading circle") {
                        HardcoverHubScreen()
                    }
                }
            }
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous))
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
        !PodcastSubscriptionStore.shared.feeds.isEmpty
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
                .overlay(Capsule().strokeBorder(hearth.hairline, lineWidth: 1))
        }
    }

    private func dismissFromShelf(_ book: Book) {
        HearthDismissedShelfStore.shared.insert(stableId: book.stableId)
        reading.removeAll { $0.stableId == book.stableId }
        listening.removeAll { $0.stableId == book.stableId }
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
                Image(systemName: "flame")
                    .font(.hearthUI(44))
                    .foregroundStyle(hearth.ember)
                    .accessibilityHidden(true)
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
                .background(hearth.ember, in: Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.vertical, 12)
    }

    private func load() async {
        if let stableId = lastOpened.stableId {
            lastOpenedBook = await engine.library.book(stableId: stableId)
            if lastOpenedBook == nil {
                lastOpened.clear()
                if appState.currentBook?.stableId == stableId {
                    appState.currentBook = nil
                }
            }
        } else {
            lastOpenedBook = nil
        }
        let feed = await engine.library.hearthFeed(
            dismissedStableIds: HearthDismissedShelfStore.shared.stableIds,
            currentStableId: hero?.stableId
        )
        listening = feed.listening
        reading = feed.reading
        fresh = feed.fresh
        downloaded = feed.downloaded

        if let hero {
            heroTint = await AmbientColorStore.shared.resolve(for: hero)
        }
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
                .overlay {
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
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

struct HearthHero: View {
    let book: Book
    let tint: Color

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    private var player: PlayerViewModel { PlayerViewModel.shared }

    private var byline: String? {
        if book.isPodcastEpisode {
            return book.podcastName ?? PodcastsFormat.displayAuthor(book.author)
        }
        return book.author
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                NavigationLink {
                    BookDetailScreen(book: book)
                } label: {
                    CoverTile(book: book, width: 132)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Open \(book.title)")

                VStack(alignment: .leading, spacing: 8) {
                    Overline(statusOverline, color: tint)
                    Text(book.title)
                        .font(.hearthDisplay(24, weight: .bold))
                        .foregroundStyle(hearth.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let byline {
                        Text(byline)
                            .font(.hearthUI(14, weight: .semibold))
                            .foregroundStyle(hearth.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HearthSourceBadge(text: sourceName)
                    Spacer(minLength: 4)
                    if remainingText != nil || progressFraction > 0 {
                        VStack(alignment: .leading, spacing: 7) {
                            Ribbon(progress: progressFraction, tint: tint, ticks: chapterTicks)
                            if let remainingText {
                                Text(remainingText)
                                    .font(.hearthUI(12, weight: .medium))
                                    .foregroundStyle(hearth.textTertiary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            EmberButton(title: continueTitle, systemImage: continueGlyph, tint: tint) {
                engine.playback.play(book)
            }
        }
        .padding(22)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .fill(hearth.bgElevated)
                EmberGlow(tint: tint, isBreathing: player.isPlaying, intensity: 0.55)
                    .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .strokeBorder(hearth.hairline, lineWidth: 1)
            }
        }
    }

    private var isEbook: Bool { book.mediaType == .ebook }
    private var isPodcast: Bool { book.isPodcastEpisode || book.mediaType == .podcast }

    private var isLive: Bool {
        engine.playback.isLive(book)
    }

    private var position: TimeInterval {
        engine.playback.position(for: book)
    }

    private var totalDuration: TimeInterval? {
        engine.playback.duration(for: book)
    }

    private var continueTitle: String {
        if progressFraction > 0.001 { return "Continue" }
        if isEbook { return "Start reading" }
        if isPodcast { return "Play episode" }
        return "Start listening"
    }

    private var continueGlyph: String {
        isEbook ? "book" : "play.fill"
    }

    private var progressFraction: Double {
        if isEbook { return book.canonicalEbookProgress }
        guard let duration = totalDuration, duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    private var chapterTicks: [Double] {
        guard !isEbook, let chapters = book.chapters, chapters.count > 1,
            let duration = totalDuration, duration > 0
        else { return [] }
        return chapters.dropFirst().map { $0.start / duration }
    }

    private var statusOverline: String {
        if isEbook {
            let pct = Int((book.canonicalEbookProgress * 100).rounded())
            return pct > 0 ? "\(pct)% read" : "Unread"
        }
        if isPodcast {
            return "Podcast"
        }
        if isLive, let chapter = engine.playback.currentChapter, !chapter.title.isEmpty {
            return chapter.title
        }
        if let chapters = book.chapters, !chapters.isEmpty {
            let index = chapters.lastIndex(where: { $0.start <= position }) ?? 0
            return "Chapter \(index + 1) of \(chapters.count)"
        }
        return "Audiobook"
    }

    private var remainingText: String? {
        guard !isEbook, let duration = totalDuration, duration > 0 else { return nil }
        let remaining = duration - position
        guard remaining > 0 else { return nil }
        return HearthFormat.remaining(remaining)
    }

    private var sourceName: String {
        if let connection = engine.library.sourceConnection(for: book), !connection.name.isEmpty {
            return connection.name
        }
        return book.source.hearthDisplayName
    }
}
