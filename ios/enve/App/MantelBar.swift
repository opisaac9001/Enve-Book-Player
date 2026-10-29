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
    var placement: Placement = .bottom
    var showsPill = true
    var onMantelBookChange: ((Book?) -> Void)? = nil
    var onRailPillTap: (() -> Void)? = nil

    enum Placement: Equatable {
        /// Docked along the bottom edge.
        case bottom
        /// Standing in the side column of a folding phone, where the system keeps its own bars.
        case rail(SideColumn)
    }

    @Environment(\.hearth) private var hearth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(AppState.self) private var appState
    @Environment(EnveEngine.self) private var engine

    @Environment(PlayerViewModel.self) private var player
    @Environment(\.profileSession) private var capturedSession
    private var profileSession: ProfileSession { capturedSession ?? .owner }
    private var lastOpened: LastOpenedBookStore { profileSession.lastOpened }

    @State private var pillTint: Color = Hearth.accent
    @State private var lastOpenedBook: Book?

    static let height: CGFloat = 88
    static let phoneHeight: CGFloat = 76
    static let liquidHeight: CGFloat = 84
    static let railWidth: CGFloat = 72

    // The taller bar needs room in both axes; a phone in landscape is regular wide but compact tall.
    static func classicHeight(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) -> CGFloat {
        horizontal == .regular && vertical == .regular ? height : phoneHeight
    }

    private var classicHeight: CGFloat {
        Self.classicHeight(horizontal: horizontalSizeClass, vertical: verticalSizeClass)
    }

    private static let liquidSink: CGFloat = 18

    // Dip into the home-indicator area like a native tab bar, keeping 24pt for the gesture zone.
    private var classicSink: CGFloat {
        min(10, max(0, bottomSafeArea - 24))
    }

    var body: some View {
        Group {
            switch placement {
            case .rail(let column):
                railBar(column: column)
            case .bottom:
                switch style {
                case .classic:
                    classicBar
                case .liquidGlass:
                    liquidGlassBar
                }
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
        .onChange(of: mantelBook?.stableId, initial: true) { onMantelBookChange?(mantelBook) }
        .highPriorityGesture(openPlayerSwipe, including: placement == .bottom && mantelBook != nil ? .all : .subviews)
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
        let book = showsPill ? mantelBook : nil
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    if let book {
                        emberPill(book: book)
                            .frame(minHeight: classicHeight)
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
                .frame(height: classicHeight)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: book == nil ? 560 : 720)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(hearth.bgElevated)
                .overlay(alignment: .top) {
                    if hearth.decorated {
                        VStack(spacing: 0) {
                            Rectangle()
                                .fill(hearth.outline)
                                .frame(height: 1.5)
                            Rectangle()
                                .fill(hearth.wood)
                                .frame(height: 2.5)
                            Rectangle()
                                .fill(hearth.hairline)
                                .frame(height: 1)
                        }
                    } else {
                        Rectangle()
                            .fill(hearth.hairline)
                            .frame(height: 1)
                    }
                }
                .shadow(color: .black.opacity(hearth.isInk ? 0.4 : 0.12), radius: 12, y: -3)
                // The surface runs edge to edge like a system bar, including under a vertical status bar;
                // the tabs above stay inside the safe area.
                .ignoresSafeArea(edges: [.horizontal, .bottom])
        }
        .padding(.bottom, -classicSink)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: book?.stableId)
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
        let book = showsPill ? mantelBook : nil
        return HStack(spacing: 10) {
            if let book {
                glassSurface(cornerRadius: 26) {
                    emberPill(book: book)
                        .frame(height: 64)
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
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: book?.stableId)
    }

    private var accessibleLiquidGlassBar: some View {
        let book = showsPill ? mantelBook : nil
        return VStack(spacing: 10) {
            if let book {
                glassSurface(cornerRadius: 26) {
                    emberPill(book: book)
                        .frame(minHeight: 64)
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
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: book?.stableId)
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
                VStack(spacing: 5) {
                    Image(systemName: item.glyph)
                        .font(.system(size: 24 * Hearth.visionFactor, weight: .medium))
                    Text(item.title)
                        .font(.hearthUI(13, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(tab == item ? hearth.ember : hearth.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background { selectionMark(for: item) }
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
                        .font(.system(size: 24 * Hearth.visionFactor, weight: .medium))
                        .foregroundStyle(tab == item ? hearth.ember : hearth.textSecondary)
                        .frame(width: 52, height: 56)
                        .background { selectionMark(for: item).padding(3) }
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
                    VStack(spacing: hasBook ? 0 : 5) {
                        Image(systemName: item.glyph)
                            .font(.system(size: 24 * Hearth.visionFactor, weight: .semibold))
                        if !hasBook {
                            Text(item.title)
                                .font(.hearthUI(13, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    .foregroundStyle(tab == item ? hearth.ember : hearth.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
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
            .background { selectionMark(for: item) }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(item.title)
        .accessibilityIdentifier("tab_\(item.rawValue)")
    }

    private func railBar(column: SideColumn) -> some View {
        let book = showsPill ? mantelBook : nil
        return Group {
            if style == .liquidGlass {
                glassSurface(cornerRadius: 28) {
                    railContent(book: book)
                        .padding(.vertical, 8)
                }
            } else {
                railContent(book: book)
            }
        }
        .padding(.top, column.statusBarBottom + 8)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: book?.stableId)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mantel-rail")
    }

    private func railContent(book: Book?) -> some View {
        VStack(spacing: 8) {
            if let book {
                railPill(book: book)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            VStack(spacing: 2) {
                ForEach(HearthTab.allCases, id: \.self) { item in
                    railTab(item)
                }
            }
        }
        .frame(width: Self.railWidth)
    }

    private func railTab(_ item: HearthTab) -> some View {
        Button {
            onSelect(item)
            PlatformHaptics.selection()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: item.glyph)
                    .font(.hearthUI(19, weight: .medium))
                Text(item.title)
                    .font(.hearthUI(10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tab == item ? hearth.ember : hearth.textSecondary)
            .frame(width: Self.railWidth - 12, height: 58)
            .background {
                if tab == item, style == .liquidGlass {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(hearth.emberSoft)
                } else {
                    selectionMark(for: item)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(tab == item ? .isSelected : [])
        .accessibilityIdentifier("tab_\(item.rawValue)")
    }

    @ViewBuilder
    private func selectionMark(for item: HearthTab) -> some View {
        if tab == item, style == .classic {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hearth.emberSoft)
                .hearthOutlined(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func railPill(book: Book) -> some View {
        Button {
            if let onRailPillTap {
                onRailPillTap()
            } else {
                openPill(book)
            }
            PlatformHaptics.impact(.light)
        } label: {
            pillCover(book: book)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(book.title)
        .accessibilityValue(pillSubtitle(book: book))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("mantel-pill")
    }

    private func pillCover(book: Book) -> some View {
        let artworkWidth = 42 / book.hearthCoverRatio
        return CachedAsyncCoverImage(
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
    }

    private func emberPill(book: Book) -> some View {
        let live = isLive(book)
        return HStack(spacing: 8) {
            Button {
                openPill(book)
            } label: {
                HStack(spacing: 10) {
                    pillCover(book: book)

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
            .accessibilityAction(named: Self.opensReader(book) ? "Open book" : "Open player") { openPill(book) }

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

    static func opensReader(_ book: Book) -> Bool {
        book.mediaType == .ebook && !book.hasEPUB3MediaOverlay
    }

    private func openPill(_ book: Book) {
        if Self.opensReader(book) {
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
