import SwiftUI

enum DuoShellLayout: Equatable {
    case standard
    case pocket(SideColumn)
    case spread(FoldLine, SideColumn)
    case nightstand(FoldLine)

    static func resolve(
        fold: FoldLine?,
        column: SideColumn?,
        pose: HingePose,
        hingeKnown: Bool,
        horizontalSizeClass: UserInterfaceSizeClass?,
        usesAccessibilityType: Bool
    ) -> DuoShellLayout {
        guard !usesAccessibilityType else { return .standard }
        if let fold {
            switch fold.axis {
            case .vertical:
                if horizontalSizeClass == .regular, let column {
                    return .spread(fold, column)
                }
                return .standard
            case .horizontal:
                return pose == .tabletop ? .nightstand(fold) : .standard
            }
        }
        if let column, hingeKnown, horizontalSizeClass == .compact {
            return .pocket(column)
        }
        return .standard
    }

    var spreadFold: FoldLine? {
        if case .spread(let fold, _) = self { fold } else { nil }
    }

    var nightstandFold: FoldLine? {
        if case .nightstand(let fold) = self { fold } else { nil }
    }

    var sideColumn: SideColumn? {
        switch self {
        case .pocket(let column): column
        case .spread(_, let column): column
        case .standard, .nightstand: nil
        }
    }

    var isSpread: Bool { spreadFold != nil }
}

private struct FacingPageBookIdKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct SharesShellBackdropKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    // Exclude the facing-page book from the stacks.
    var facingPageBookId: String? {
        get { self[FacingPageBookIdKey.self] }
        set { self[FacingPageBookIdKey.self] = newValue }
    }

    var sharesShellBackdrop: Bool {
        get { self[SharesShellBackdropKey.self] }
        set { self[SharesShellBackdropKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder
    func clearsNavigationContainerBackground() -> some View {
        if #available(iOS 18, *) {
            containerBackground(.clear, for: .navigation)
        } else {
            self
        }
    }
}

struct DuoSpreadBackdrop: View {
    let book: Book?

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.profileSession) private var capturedSession
    @Environment(\.hearth) private var hearth
    @State private var ambient: Color = Hearth.accent

    private var showsPlayer: Bool {
        book.map { !MantelBar.opensReader($0) } ?? false
    }

    var body: some View {
        ZStack {
            hearth.bgSunken
            EmberGlow(
                tint: book == nil ? hearth.ember : ambient,
                isBreathing: showsPlayer && playerVM.isPlaying,
                intensity: book == nil ? 0.35 : showsPlayer ? 1 : 0.7
            )
            LinearGradient(
                colors: [.clear, .black.opacity(hearth.isInk ? 0.5 : 0.12)],
                startPoint: UnitPoint(x: 0.5, y: 0.45),
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: book?.stableId) {
            guard let book else { return }
            let resolved = await (capturedSession ?? .owner).ambientColors.resolve(for: book)
            guard !Task.isCancelled else { return }
            ambient = resolved
        }
    }
}

struct DuoSpine: View {
    let fold: FoldLine
    private let hinge = HingeStateStore.shared

    var body: some View {
        HearthSpineShadow(axis: .vertical, depth: hinge.spineDepth(flat: 0.35))
            .frame(width: 84)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .offset(x: fold.center - 42)
            .ignoresSafeArea(edges: .vertical)
            .allowsHitTesting(false)
    }
}

struct FacingPage: View {
    let book: Book?
    var topInset: CGFloat = 0

    @Environment(AppState.self) private var appState
    @Environment(EnveEngine.self) private var engine
    @State private var detailBook: Book?
    @State private var showsDetail = false

    var body: some View {
        NavigationStack {
            Group {
                if let book {
                    if MantelBar.opensReader(book) {
                        FacingReadingPage(book: book, topInset: topInset) { showDetails(for: book) }
                    } else {
                        PlayerScreen(presentation: .page, topInset: topInset, onShowDetails: showDetails)
                    }
                } else {
                    FacingReadingRoom(topInset: topInset)
                }
            }
            .clearsNavigationContainerBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showsDetail) {
                if let detailBook {
                    BookDetailScreen(book: detailBook)
                        .padding(.top, topInset)
                        .clearsNavigationContainerBackground()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("facing-page")
        }
        .task(id: book?.stableId) {
            // Like a tap on the pill, the page puts the mantel book in front of the player when nothing is loaded.
            if let book, !MantelBar.opensReader(book), engine.playback.currentBook == nil {
                appState.currentBook = book
            }
        }
    }

    private func showDetails(for book: Book) {
        detailBook = book
        showsDetail = true
    }
}

private struct FacingReadingPage: View {
    let book: Book
    let topInset: CGFloat
    let onShowDetails: () -> Void

    @Environment(EnveEngine.self) private var engine
    @Environment(\.profileSession) private var capturedSession
    @Environment(\.hearth) private var hearth
    @State private var tint: Color = Hearth.accent
    @State private var pageTotal: Int?
    @State private var counterpart: Book?

    private var profileSession: ProfileSession { capturedSession ?? .owner }
    private var fraction: Double { engine.playback.progressFraction(for: book) }

    var body: some View {
        GeometryReader { geo in
            let coverWidth = min(geo.size.width * 0.54, (geo.size.height * 0.4) / book.hearthCoverRatio)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                CoverTile(book: book, width: coverWidth, badges: false)
                    .shadow(color: tint.opacity(0.25), radius: 24, y: 8)
                    .accessibilityHidden(true)
                Spacer(minLength: 24)
                VStack(spacing: 7) {
                    Overline(overline, color: tint)
                        .lineLimit(1)
                    Text(book.title)
                        .font(.hearthDisplay(24, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let author = book.author {
                        Text(author)
                            .font(.hearthUI(14))
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 22)
                VStack(spacing: 10) {
                    Ribbon(progress: fraction, tint: tint, height: 4)
                    HStack {
                        Text(positionLabel)
                        Spacer()
                        if let remainingLabel {
                            Text(remainingLabel)
                        }
                    }
                    .font(.hearthUI(13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(hearth.textSecondary)
                }
                Spacer(minLength: 24)
                EmberButton(title: continueTitle, systemImage: "book", tint: tint) {
                    PlatformHaptics.impact(.light)
                    engine.playback.openEbook(book)
                }
                HStack(spacing: 10) {
                    if let counterpart {
                        QuietButton(title: "Listen", systemImage: "play.fill") {
                            engine.playback.play(counterpart)
                        }
                    }
                    QuietButton(title: "Details", systemImage: "info.circle", action: onShowDetails)
                }
                .padding(.top, 10)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.top, topInset)
        .task(id: book.stableId) {
            tint = await profileSession.ambientColors.resolve(for: book)
            pageTotal = await profileSession.readingStats.currentSnapshot().perBook[book.id]?.totalPages
            counterpart = await engine.library.detailSnapshot(for: book, current: nil).counterpart
        }
    }

    private var chapterTitle: String? {
        guard let data = book.epubLocator?.data(using: .utf8),
            let locator = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let title = (locator["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        else { return nil }
        return title
    }

    private var overline: String {
        if book.isFinished { return "Finished" }
        return chapterTitle ?? "On the hearth"
    }

    private var currentPage: Int? {
        guard let total = pageTotal, total > 0 else { return nil }
        return min(total, max(1, Int((fraction * Double(total)).rounded(.up))))
    }

    private var positionLabel: String {
        if let page = currentPage, let total = pageTotal {
            return "Page \(page) of \(total)"
        }
        let percent = Int((fraction * 100).rounded())
        return percent == 0 ? "Not started" : "\(percent)% read"
    }

    private var remainingLabel: String? {
        guard let page = currentPage, let total = pageTotal else { return nil }
        let left = total - page
        return left == 1 ? "1 page left" : "\(left) pages left"
    }

    private var continueTitle: String {
        fraction > 0.001 ? "Continue reading" : "Start reading"
    }
}

private struct FacingReadingRoom: View {
    let topInset: CGFloat

    @Environment(EnveEngine.self) private var engine
    @Environment(\.profileSession) private var capturedSession
    @Environment(\.hearth) private var hearth
    @State private var fresh: [Book] = []

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "flame")
                .font(.hearthUI(28, weight: .medium))
                .foregroundStyle(hearth.ember)
                .accessibilityHidden(true)
            Overline("The reading room")
            Text("Choose a story from the stacks and it will wait for you here.")
                .font(.hearthDisplay(20, weight: .regular))
                .foregroundStyle(hearth.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !fresh.isEmpty {
                VStack(spacing: 14) {
                    Overline("Fresh ink", color: hearth.textTertiary)
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(fresh, id: \.stableId) { book in
                            NavigationLink {
                                BookDetailScreen(book: book)
                                    .padding(.top, topInset)
                                    .clearsNavigationContainerBackground()
                            } label: {
                                ShelfCoverCell(book: book, width: 72, showsProgress: false)
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel(book.title)
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, topInset)
        .task {
            await loadFresh()
            for await _ in engine.library.libraryChanges() {
                await loadFresh()
            }
        }
    }

    private func loadFresh() async {
        let session = capturedSession ?? .owner
        let feed = await engine.library.hearthFeed(dismissedStableIds: session.dismissedShelves.stableIds, currentStableId: nil)
        fresh = Array(feed.fresh.filter(session.preferences.includesLibraryBook).prefix(4))
    }
}

struct NightstandDock: View {
    @Binding var tab: HearthTab
    var style: UserPreferences.ShellNavigationStyle
    var bottomSafeArea: CGFloat
    var onSelect: (HearthTab) -> Void

    @Environment(AppState.self) private var appState
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @State private var book: Book?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let book {
                    if MantelBar.opensReader(book) {
                        NightstandReadingRow(book: book)
                    } else {
                        PlayerScreen(presentation: .dock)
                    }
                } else {
                    Text("Nothing on the hearth yet.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            MantelBar(
                tab: $tab,
                style: style,
                bottomSafeArea: bottomSafeArea,
                onSelect: onSelect,
                showsPill: false,
                onMantelBookChange: { book = $0 }
            )
        }
        .background {
            hearth.bgSunken.ignoresSafeArea(edges: [.horizontal, .bottom])
        }
        .task(id: book?.stableId) {
            if let book, !MantelBar.opensReader(book), engine.playback.currentBook == nil {
                appState.currentBook = book
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nightstand-dock")
    }
}

private struct NightstandReadingRow: View {
    let book: Book

    @Environment(EnveEngine.self) private var engine
    @Environment(\.profileSession) private var capturedSession
    @Environment(\.hearth) private var hearth
    @State private var tint: Color = Hearth.accent

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                CoverTile(book: book, width: 64 / book.hearthCoverRatio, badges: false, corner: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.hearthDisplay(18, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                    if let author = book.author {
                        Text(author)
                            .font(.hearthUI(13))
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                    Ribbon(progress: engine.playback.progressFraction(for: book), tint: tint)
                        .padding(.top, 4)
                }
            }
            EmberButton(title: "Continue reading", systemImage: "book", tint: tint) {
                PlatformHaptics.impact(.light)
                engine.playback.openEbook(book)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: PlayerLayoutPolicy.stackedContentWidth)
        .task(id: book.stableId) {
            tint = await (capturedSession ?? .owner).ambientColors.resolve(for: book)
        }
    }
}
