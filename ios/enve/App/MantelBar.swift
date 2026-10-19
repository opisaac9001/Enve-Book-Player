import SwiftUI
import UIKit

enum HearthTab: String, CaseIterable {
    case hearth, library, podcasts, journal

    var title: String {
        switch self {
        case .hearth: "Hearth"
        case .podcasts: "Podcasts"
        case .library: "Library"
        case .journal: "Journal"
        }
    }

    var glyph: String {
        switch self {
        case .hearth: "flame"
        case .podcasts: "dot.radiowaves.left.and.right"
        case .library: "books.vertical"
        case .journal: "text.quote"
        }
    }
}

struct MantelBar: View {
    @Binding var tab: HearthTab
    var style: UserPreferences.ShellNavigationStyle = .classic
    var bottomSafeArea: CGFloat = 0
    var onSelect: (HearthTab) -> Void = { _ in }

    @Environment(\.hearth) private var hearth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppState.self) private var appState
    @Environment(EnveEngine.self) private var engine

    @Environment(PlayerViewModel.self) private var player
    @Environment(\.profileSession) private var capturedSession
    private var profileSession: ProfileSession { capturedSession ?? .owner }
    private var lastOpened: LastOpenedBookStore { profileSession.lastOpened }

    @State private var pillTint: Color = Hearth.accent
    @State private var lastOpenedBook: Book?

    static let height: CGFloat = 64
    static let phoneHeight: CGFloat = 52
    static let liquidHeight: CGFloat = 74

    static var classicHeight: CGFloat {
        UIDevice.current.userInterfaceIdiom == .phone ? phoneHeight : height
    }

    private static let liquidSink: CGFloat = 18

    // Dip into the home-indicator area like a native tab bar, keeping 24pt for the gesture zone.
    private var classicSink: CGFloat {
        min(10, max(0, bottomSafeArea - 24))
    }

    var body: some View {
        Group {
            switch style {
            case .classic:
                classicBar
            case .liquidGlass:
                liquidGlassBar
            }
        }
        .task(id: lastOpened.openedAt) {
            await refreshLastOpenedBook()
        }
        .task {
            for await _ in engine.library.libraryChanges() {
                await refreshLastOpenedBook()
            }
        }
        .highPriorityGesture(openPlayerSwipe, including: mantelBook == nil ? .subviews : .all)
    }

    // Claims every drag on the bar so a swipe can't also tap a tab; only an upward swipe acts.
    private var openPlayerSwipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                let rise = -value.translation.height
                guard let book = mantelBook,
                    rise > abs(value.translation.width),
                    rise >= 44 || (rise >= 16 && value.velocity.height <= -600)
                else { return }
                openPill(book)
            }
    }

    private var classicBar: some View {
        let book = mantelBook
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    if let book {
                        emberPill(book: book)
                            .frame(minHeight: Self.classicHeight)
                            .transition(.move(edge: .leading).combined(with: .opacity))

                        Rectangle()
                            .fill(hearth.hairline)
                            .frame(height: 1)
                    }

                    accessibleTabs
                        .padding(.vertical, 6)
                }
            } else {
                HStack(spacing: 0) {
                    if let book {
                        emberPill(book: book)
                            .transition(.move(edge: .leading).combined(with: .opacity))

                        Rectangle()
                            .fill(hearth.hairline)
                            .frame(width: 1, height: 30)

                        compactTabs
                    } else {
                        fullTabs
                    }
                }
                .frame(height: Self.classicHeight)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: book == nil ? 560 : 720)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(hearth.bgElevated)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(hearth.hairline)
                        .frame(height: 1)
                }
                .shadow(color: .black.opacity(hearth.isInk ? 0.4 : 0.12), radius: 12, y: -3)
                .ignoresSafeArea(edges: .bottom)
        }
        .padding(.bottom, -classicSink)
        .animation(.smooth(duration: 0.35), value: book?.stableId)
    }

    @ViewBuilder
    private var liquidGlassBar: some View {
        if dynamicTypeSize.isAccessibilitySize {
            accessibleLiquidGlassBar
        } else {
            standardLiquidGlassBar
        }
    }

    private var standardLiquidGlassBar: some View {
        let book = mantelBook
        return HStack(spacing: 10) {
            if let book {
                glassSurface(cornerRadius: 26) {
                    emberPill(book: book)
                        .frame(height: 54)
                }
                .frame(minWidth: 0, maxWidth: 390)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            glassSurface(cornerRadius: 30) {
                liquidTabs(hasBook: book != nil)
            }
            .frame(width: book == nil ? nil : 224)
            .frame(maxWidth: book == nil ? 540 : nil)
        }
        .frame(height: Self.liquidHeight)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .padding(.bottom, -Self.liquidSink)
        .animation(.smooth(duration: 0.35), value: book?.stableId)
    }

    private var accessibleLiquidGlassBar: some View {
        let book = mantelBook
        return VStack(spacing: 10) {
            if let book {
                glassSurface(cornerRadius: 26) {
                    emberPill(book: book)
                        .frame(minHeight: 54)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            glassSurface(cornerRadius: 30) {
                accessibleTabs
                    .padding(8)
            }
        }
        .frame(maxWidth: 540)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .padding(.bottom, -Self.liquidSink)
        .animation(.smooth(duration: 0.35), value: book?.stableId)
    }

    @ViewBuilder
    private func glassSurface<Content: View>(
        cornerRadius: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(iOS 26.0, *) {
            content()
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(hearth.bgElevated.opacity(0.28))
                }
                .glassEffect(
                    .regular.tint(hearth.bgElevated.opacity(0.36)).interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            content()
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(hearth.hairline, lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(hearth.isInk ? 0.32 : 0.12), radius: 14, y: 5)
                }
        }
    }

    private var fullTabs: some View {
        ForEach(HearthTab.allCases, id: \.self) { item in
            Button {
                onSelect(item)
                PlatformHaptics.selection()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: item.glyph)
                        .font(.hearthUI(18, weight: .medium))
                    Text(item.title)
                        .font(.hearthUI(10, weight: .semibold))
                }
                .foregroundStyle(tab == item ? hearth.ember : hearth.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(item.title)
            .accessibilityIdentifier("tab_\(item.rawValue)")
        }
    }

    private var compactTabs: some View {
        HStack(spacing: 0) {
            ForEach(HearthTab.allCases, id: \.self) { item in
                Button {
                    onSelect(item)
                    PlatformHaptics.selection()
                } label: {
                    Image(systemName: item.glyph)
                        .font(.hearthUI(17, weight: .medium))
                        .foregroundStyle(tab == item ? hearth.ember : hearth.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(item.title)
                .accessibilityIdentifier("tab_\(item.rawValue)")
            }
        }
        .padding(.trailing, 6)
    }

    private func liquidTabs(hasBook: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(HearthTab.allCases, id: \.self) { item in
                Button {
                    onSelect(item)
                    PlatformHaptics.selection()
                } label: {
                    VStack(spacing: hasBook ? 0 : 3) {
                        Image(systemName: item.glyph)
                            .font(.hearthUI(17, weight: .semibold))
                        if !hasBook {
                            Text(item.title)
                                .font(.hearthUI(9, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    .foregroundStyle(tab == item ? hearth.ember : hearth.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(item.title)
                .accessibilityIdentifier("tab_\(item.rawValue)")
            }
        }
        .padding(.horizontal, hasBook ? 6 : 8)
    }

    private var accessibleTabs: some View {
        ViewThatFits(in: .horizontal) {
            accessibleTabGrid(columns: 4)
            accessibleTabGrid(columns: 2)
            accessibleTabGrid(columns: 1)
        }
    }

    private func accessibleTabGrid(columns: Int) -> some View {
        let tabs = HearthTab.allCases
        return Grid(horizontalSpacing: 4, verticalSpacing: 0) {
            ForEach(Array(stride(from: 0, to: tabs.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(tabs[start..<min(start + columns, tabs.count)], id: \.self) { item in
                        accessibleTab(item)
                    }
                }
            }
        }
    }

    private func accessibleTab(_ item: HearthTab) -> some View {
        Button {
            onSelect(item)
            PlatformHaptics.selection()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.glyph)
                Text(item.title)
            }
            .font(.hearthUI(13, weight: .semibold))
            .foregroundStyle(tab == item ? hearth.ember : hearth.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(item.title)
        .accessibilityIdentifier("tab_\(item.rawValue)")
    }

    private func emberPill(book: Book) -> some View {
        let live = isLive(book)
        let artworkWidth = 42 / book.hearthCoverRatio
        return HStack(spacing: 8) {
            Button {
                openPill(book)
            } label: {
                HStack(spacing: 10) {
                    CachedAsyncCoverImage(
                        url: book.coverURL,
                        fallbackColor: "Blue",
                        headers: CachedAsyncCoverImage.authHeaders(for: book),
                        book: book
                    )
                    .aspectRatio(contentMode: .fill)
                    .frame(width: artworkWidth, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
                    .padding(2.5)
                    .overlay {
                        // Transpose before rotation to preserve the portrait cover contour.
                        RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                            .trim(from: 0, to: pillFraction(book))
                            .stroke(pillTint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .frame(width: 47, height: artworkWidth + 5)
                            .rotationEffect(.degrees(-90))
                            .opacity(pillFraction(book) > 0.001 ? 1 : 0)
                    }
                    .task(id: book.stableId) {
                        pillTint = await profileSession.ambientColors.resolve(for: book)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading) {
                        HearthMarqueeText(
                            text: book.title,
                            size: 13,
                            weight: .semibold,
                            serif: true,
                            color: hearth.text,
                            height: Hearth.scaled(17)
                        )
                        .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(book.title)
            .accessibilityValue(pillSubtitle(book: book))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("mantel-pill")
            .accessibilityAction(named: opensReader(book) ? "Open book" : "Open player") { openPill(book) }

            Button {
                if book.mediaType == .ebook && !book.hasEPUB3MediaOverlay {
                    engine.playback.openEbook(book)
                } else if live {
                    player.togglePlay()
                } else {
                    engine.playback.play(book, presentPlayer: false)
                }
                PlatformHaptics.impact(.light)
            } label: {
                Image(
                    systemName: book.mediaType == .ebook && !book.hasEPUB3MediaOverlay
                        ? "book.fill"
                        : (live && player.isPlaying ? "pause.fill" : "play.fill")
                )
                .font(.hearthUI(15, weight: .semibold))
                .foregroundStyle(hearth.text)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(
                book.mediaType == .ebook && !book.hasEPUB3MediaOverlay ? "Read" : (live && player.isPlaying ? "Pause" : "Play")
            )
        }
        .padding(.leading, 11)
        .padding(.trailing, 6)
    }

    private func opensReader(_ book: Book) -> Bool {
        book.mediaType == .ebook && !book.hasEPUB3MediaOverlay
    }

    private func openPill(_ book: Book) {
        if opensReader(book) {
            engine.playback.openEbook(book)
        } else {
            appState.currentBook = book
            appState.presentation.isPlayerPresented = true
        }
        PlatformHaptics.impact(.light)
    }

    private func isLive(_ book: Book) -> Bool {
        player.currentBook?.stableId == book.stableId && player.isPlaybackLoaded
    }

    private func pillFraction(_ book: Book) -> Double {
        if book.mediaType == .ebook { return book.canonicalEbookProgress }
        let live = isLive(book) && player.duration > 0
        let position = live ? player.progress : book.currentTime
        let total = live ? player.duration : (book.duration ?? 0)
        guard total > 0 else { return 0 }
        return min(max(position / total, 0), 1)
    }

    private func pillSubtitle(book: Book) -> String {
        if isLive(book) {
            if let chapter = player.currentChapter, !chapter.title.isEmpty {
                return chapter.title
            }
            if player.duration > 0 {
                return HearthFormat.remaining(
                    player.duration - player.progress,
                    speed: player.playbackSpeed
                )
            }
        }
        if book.isPodcastEpisode {
            return book.podcastName ?? PodcastsFormat.displayAuthor(book.author) ?? "Podcast"
        }
        return book.author ?? (book.mediaType == .ebook ? "Ebook" : "Audiobook")
    }

    private var mantelBook: Book? {
        if let current = appState.currentBook,
            current.stableId == lastOpened.stableId,
            profileSession.preferences.includesLibraryBook(current)
        {
            return current
        }
        return [lastOpenedBook, appState.currentBook].compactMap { $0 }
            .first(where: profileSession.preferences.includesLibraryBook)
    }

    private func refreshLastOpenedBook() async {
        guard let stableId = lastOpened.stableId else {
            lastOpenedBook = nil
            return
        }
        lastOpenedBook = await engine.library.book(stableId: stableId)
        if lastOpenedBook == nil {
            lastOpened.clear()
            if appState.currentBook?.stableId == stableId {
                appState.currentBook = nil
            }
        }
    }
}
