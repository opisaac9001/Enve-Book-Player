import SwiftUI

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
    var onSelect: (HearthTab) -> Void = { _ in }

    @Environment(\.hearth) private var hearth
    @Environment(AppState.self) private var appState
    @Environment(EnveEngine.self) private var engine

    private var player: PlayerViewModel { PlayerViewModel.shared }
    private let lastOpened = LastOpenedBookStore.shared

    @State private var pillTint: Color = Hearth.accent
    @State private var lastOpenedBook: Book?

    static let height: CGFloat = 64
    static let liquidHeight: CGFloat = 74

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
    }

    private var classicBar: some View {
        let book = mantelBook
        return HStack(spacing: 0) {
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
        .frame(height: Self.height)
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
        .animation(.smooth(duration: 0.35), value: book?.stableId)
    }

    private var liquidGlassBar: some View {
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
        .offset(y: 18)
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
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("tab_\(item.rawValue)")
        }
    }

    private var compactTabs: some View {
        HStack(spacing: 2) {
            ForEach(HearthTab.allCases, id: \.self) { item in
                Button {
                    onSelect(item)
                    PlatformHaptics.selection()
                } label: {
                    Image(systemName: item.glyph)
                        .font(.hearthUI(17, weight: .medium))
                        .foregroundStyle(tab == item ? hearth.ember : hearth.textSecondary)
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("tab_\(item.rawValue)")
            }
        }
        .padding(.trailing, 10)
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
                .accessibilityIdentifier("tab_\(item.rawValue)")
            }
        }
        .padding(.horizontal, hasBook ? 6 : 8)
    }

    private func emberPill(book: Book) -> some View {
        let live = isLive(book)
        return HStack(spacing: 8) {
            Button {
                if book.mediaType == .ebook && !book.hasEPUB3MediaOverlay {
                    engine.playback.openEbook(book)
                } else {
                    appState.currentBook = book
                    appState.presentation.isPlayerPresented = true
                }
                PlatformHaptics.impact(.light)
            } label: {
                HStack(spacing: 10) {
                    CachedAsyncCoverImage(
                        url: book.coverURL,
                        fallbackColor: "Blue",
                        headers: CachedAsyncCoverImage.authHeaders(for: book),
                        book: book
                    )
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
                    .padding(2.5)
                    .overlay {

                        RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                            .trim(from: 0, to: pillFraction(book))
                            .stroke(pillTint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .opacity(pillFraction(book) > 0.001 ? 1 : 0)
                    }
                    .task(id: book.stableId) {
                        pillTint = await AmbientColorStore.shared.resolve(for: book)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HearthMarqueeText(
                            text: book.title,
                            size: 13,
                            weight: .semibold,
                            serif: true,
                            color: hearth.text,
                            height: Hearth.scaled(17)
                        )
                        Text(pillSubtitle(book: book))
                            .font(.hearthUI(11, weight: .medium))
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())

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
                .frame(width: 38, height: 38)
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
            current.stableId == lastOpened.stableId
        {
            return current
        }
        return lastOpenedBook ?? appState.currentBook
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
