import SwiftUI
import UIKit

struct BookDetailScreen: View {
    let book: Book

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dismiss) private var dismiss

    @State private var live: Book?
    @State private var tint: Color = Hearth.accent
    @State private var counterpart: Book?
    @State private var inSeries: [Book] = []
    @State private var descriptionExpanded = false
    @State private var comicCredits: ComicCredits?
    @State private var showChapterEditor = false
    @State private var allChaptersShown = false
    @State private var shelf = DetailShelfStatus()
    @State private var chapterFetcher = DetailChapterFetcher()
    @State private var cachedChapters: [Chapter] = []
    @State private var metadataTool: DetailMetadataTool?
    @State private var didAutoFetchChapters = false
    @State private var confirmDelete = false
    @State private var workSummary: LibraryWorkSummary?
    @State private var bookOrbitCollectionsShown = false
    @State private var canManageBookOrbitCollections = false
    @State private var ratingUpdating = false
    @State private var ratingMessage: String?
    @State private var ratingFailed = false
    @State private var pendingSeparation: PendingChapterSeparation?
    @State private var separationError: String?

    private enum DetailMetadataTool: String, Identifiable {
        case editMetadata, findMatch, linkFormats
        var id: String { rawValue }
    }

    private struct PendingChapterSeparation {
        let track: AudioTrack
        let title: String
    }

    private var shown: Book { live ?? book }
    private var isEbook: Bool { shown.mediaType == .ebook }
    private var alignedListenBook: Book? {
        if shown.epub3Features?.hasMediaOverlay == true { return shown }
        if counterpart?.epub3Features?.hasMediaOverlay == true { return counterpart }
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            let contentWidth = HearthAdaptive.contentWidth(for: geo.size.width, maximum: 980)
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header(size: geo.size, width: contentWidth)

                    actions
                        .padding(.horizontal, 24)

                    if let summary = workSummary {
                        HearthDoorway(
                            glyph: "square.stack.3d.up",
                            title: summary.editions > 1 ? "\(summary.editions) editions" : "Other copies",
                            line: versionsLine(summary)
                        ) {
                            WorkHubScreen(workKey: summary.key, seed: shown)
                        }
                        .padding(.horizontal, 24)
                    }

                    if let message = shelf.message {
                        Text(message)
                            .font(.hearthUI(13))
                            .foregroundStyle(shelf.failed ? hearth.statusError : hearth.textSecondary)
                            .padding(.horizontal, 24)
                            .transition(.opacity)
                    }

                    if engine.library.supportsPersonalRating(shown) {
                        personalRating
                            .padding(.horizontal, 24)
                    }

                    if let text = descriptionText {
                        description(text)
                            .padding(.horizontal, 24)
                    }

                    about
                        .padding(.horizontal, 24)

                    DetailSyncStatusRow(book: shown)
                        .padding(.horizontal, 24)

                    if chapterFetcher.isFetching {
                        chapterFetchStatus
                            .padding(.horizontal, 24)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if shown.isReadAloudBook {
                        DetailReadAloudFormatsSection(book: shown, linkedAudiobook: counterpart, tint: tint)
                    }

                    if !chapterList.isEmpty {
                        chaptersSection
                    } else if shown.mediaType == .audiobook || shown.mediaType == .ebook {
                        chaptersEmptySection
                    }

                    DetailHistorySection(book: shown, tint: tint)

                    DetailBookmarksSection(book: shown, tint: tint)

                    if !inSeries.isEmpty {
                        seriesShelf
                    }

                    if shown.source == .bookOrbit {
                        DetailBookOrbitShelves(book: shown, includesSeries: inSeries.isEmpty)
                    }

                    if shown.source == .booklore || shown.source == .silo {
                        DetailSourceRecommendations(book: shown)
                    }

                    #if DEBUG
                    DetailDebugSection(book: shown)
                        .padding(.horizontal, 24)
                    #endif
                }
                .hearthReadableFrame(width: geo.size.width, maximum: 980)
                .padding(.bottom, mantelInset + 16)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
        }
        .background(HearthBackground())
        .overlay(alignment: .topLeading) {
            GlyphButton(systemImage: "chevron.left", label: "Back") { dismiss() }
                .padding(.leading, 20)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .animation(.smooth(duration: 0.35), value: shelf.message)
        .animation(.smooth(duration: 0.25), value: chapterFetcher.isFetching)
        .sheet(
            item: $metadataTool,
            onDismiss: {
                Task { await refresh() }
            }
        ) { tool in
            Group {
                switch tool {
                case .editMetadata:
                    MetadataEditScreen(book: shown)
                case .findMatch:
                    MetadataMatchScreen(book: shown)
                case .linkFormats:
                    EbookAudiobookMatchScreen(book: shown)
                }
            }
            .enveEnvironment()
        }
        .sheet(isPresented: $bookOrbitCollectionsShown) {
            BookOrbitMembershipSheet(book: shown)
                .enveEnvironment()
        }
        .sheet(isPresented: $showChapterEditor) {
            NavigationStack {
                ChapterEditorScreen(book: shown)
            }
            .enveEnvironment()
        }
        .task {
            await refresh()
            reloadCachedChapters()
            autoFetchChaptersIfNeeded()
            await shelf.load(book: shown, library: engine.library)
            if shown.source == .komga,
                let provider = AppState.shared.getProvider(shown.providerId) as? KomgaProvider
            {

                let bookId = shown.id
                Task { comicCredits = try? await provider.fetchComicCredits(bookId: bookId) }
            }
            if await engine.library.resolveReadAloudIfUnknown(for: shown) != nil {
                await refresh()
            }
            canManageBookOrbitCollections = await engine.library.canManageBookOrbitCollections(for: shown)
            for await _ in engine.library.libraryChanges() {
                await refresh()
                reloadCachedChapters()
            }
        }
        .alert("Delete from library?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                engine.library.permanentlyDelete(shown)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes \"\(shown.title)\" from Enve, deletes local imported or downloaded files on this device, and moves the book to Recently Deleted. Server copies are not deleted."
            )
        }
        .confirmationDialog(
            "Separate into Book",
            isPresented: Binding(
                get: { pendingSeparation != nil },
                set: { if !$0 { pendingSeparation = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingSeparation
        ) { pending in
            Button("Separate") { separate(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("Makes \"\(pending.title)\" its own book in your library. The audio file stays where it is.")
        }
        .alert(
            "Couldn’t separate",
            isPresented: Binding(
                get: { separationError != nil },
                set: { if !$0 { separationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(separationError ?? "")
        }
    }

    private var personalRating: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR RATING")
                .font(.hearthUI(11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(hearth.textTertiary)

            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        setPersonalRating(value)
                    } label: {
                        Image(systemName: value <= Int(shown.personalRating ?? 0) ? "star.fill" : "star")
                            .font(.hearthUI(25, weight: .semibold))
                            .foregroundStyle(value <= Int(shown.personalRating ?? 0) ? Hearth.accent : hearth.textTertiary)
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(ratingUpdating)
                    .accessibilityLabel("\(value) star\(value == 1 ? "" : "s")")
                }

                if ratingUpdating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Hearth.accent)
                        .padding(.leading, 4)
                }
            }

            Text(ratingMessage ?? ratingCaption)
                .font(.hearthUI(13))
                .foregroundStyle(ratingFailed ? hearth.statusError : hearth.textSecondary)
        }
        .padding(18)
        .background {
            HearthChromeBackground(
                shape: .rounded(20),
                fill: hearth.bgElevated,
                stroke: hearth.hairline,
                tint: tint
            )
        }
        .animation(.smooth(duration: 0.2), value: shown.personalRating)
    }

    private var ratingCaption: String {
        if let rating = shown.personalRating {
            return "\(Int(rating.rounded())) of 5 · Saved with \(ratingDestination)"
        }
        return "Choose 1-5 stars. This saves to \(ratingDestination)."
    }

    private var ratingDestination: String {
        engine.library.sourceConnection(for: shown)?.name
            ?? {
                switch shown.source {
                case .booklore: "Grimmory"
                case .storyteller: "Storyteller"
                case .bookOrbit: "BookOrbit"
                default: "the source service"
                }
            }()
    }

    private func setPersonalRating(_ rating: Int) {
        guard !ratingUpdating else { return }
        PlatformHaptics.impact(.light)
        ratingUpdating = true
        ratingMessage = nil
        ratingFailed = false
        Task {
            do {
                live = try await engine.library.setPersonalRating(rating, for: shown)
                ratingMessage = "Rating saved to \(ratingDestination)."
            } catch {
                ratingFailed = true
                ratingMessage = "Couldn’t save the rating to \(ratingDestination)."
            }
            ratingUpdating = false
        }
    }

    private func header(size: CGSize, width: CGFloat) -> some View {
        let isWideLandscape = size.width >= 760 && size.width > size.height
        let compactCoverWidth =
            isEbook
            ? min(max(width * 0.30, 168), 236)
            : min(max(width * 0.22, 136), 196)
        let coverWidth = isWideLandscape ? min(max(width * 0.18, 142), 190) : compactCoverWidth

        return Group {
            if isWideLandscape {
                HStack(alignment: .center, spacing: 26) {
                    CoverTile(book: shown, width: coverWidth)
                        .shadow(color: tint.opacity(0.22), radius: 20, y: 7)

                    VStack(alignment: .leading, spacing: 16) {
                        headerText(alignment: .leading)
                        progressBlock(alignment: .leading)
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 20) {
                    CoverTile(book: shown, width: coverWidth)
                        .shadow(color: tint.opacity(0.25), radius: 22, y: 8)
                    headerText(alignment: .center)
                    progressBlock(alignment: .center)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 96)
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
        .background { wash }
    }

    private func headerText(alignment: TextAlignment) -> some View {
        VStack(alignment: alignment == .leading ? .leading : .center, spacing: 12) {
            Overline(shown.isComic ? "Comic" : (isEbook ? "Ebook" : "Audiobook"))
            Text(shown.title)
                .font(.hearthDisplay(26, weight: .semibold))
                .foregroundStyle(hearth.text)
                .multilineTextAlignment(alignment)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: alignment == .leading ? .leading : .center, spacing: 6) {
                if let author = shown.author {
                    NavigationLink {
                        LibraryDetailListScreen(scope: .author(author))
                    } label: {
                        metaLink(author)
                    }
                    .buttonStyle(PressableStyle())
                }
                if let narrator = shown.narrator, !narrator.isEmpty {
                    Text("Read by \(narrator)")
                        .font(.hearthUI(13))
                        .foregroundStyle(hearth.textTertiary)
                }
                if let series = shown.seriesInfo {
                    NavigationLink {
                        LibraryDetailListScreen(scope: .series(series.name))
                    } label: {
                        let unit = shown.isComic ? "Issue" : "Book"
                        metaLink(series.sequence.map { "\(series.name) · \(unit) \($0)" } ?? series.name)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private func progressBlock(alignment: Alignment) -> some View {
        VStack(alignment: alignment.horizontal == .leading ? .leading : .center, spacing: 9) {
            Ribbon(progress: progressFraction, tint: tint, ticks: chapterTicks)
            Text(statusLine)
                .font(.hearthUI(13, weight: .medium))
                .foregroundStyle(hearth.textSecondary)
        }
    }

    private func metaLink(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.hearthUI(15, weight: .medium))
                .foregroundStyle(hearth.textSecondary)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.hearthUI(9, weight: .semibold))
                .foregroundStyle(hearth.textTertiary)
        }
    }

    private var wash: some View {
        ZStack {
            CachedAsyncCoverImage(
                url: shown.coverURL,
                fallbackColor: "Blue",
                headers: CachedAsyncCoverImage.authHeaders(for: shown),
                book: shown
            )
            .scaleEffect(1.2)
            .blur(radius: 56, opaque: true)
            hearth.bg.opacity(0.45)
            LinearGradient(
                colors: [.clear, hearth.bg.opacity(0.7), hearth.bg],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
    }

    private var progressFraction: Double {
        if isEbook { return shown.canonicalEbookProgress }
        guard let duration = shown.duration, duration > 0 else { return 0 }
        return min(max(shown.currentTime / duration, 0), 1)
    }

    private var chapterTicks: [Double] {
        let chapters = chapterList
        guard !isEbook, chapters.count > 1,
            let duration = shown.duration, duration > 0
        else { return [] }
        return chapters.dropFirst().map { $0.start / duration }
    }

    private var statusLine: String {
        if shown.isFinished { return "Finished" }
        if isEbook {
            let pct = Int((shown.canonicalEbookProgress * 100).rounded())
            return pct > 0 ? "\(pct)% read" : "Unread"
        }
        guard let duration = shown.duration, duration > 0 else { return "Audiobook" }
        let remaining = HearthFormat.remaining(max(duration - shown.currentTime, 0))
        let chapters = chapterList
        if !chapters.isEmpty {
            let index = chapters.lastIndex(where: { $0.start <= shown.currentTime }) ?? 0
            return "Chapter \(index + 1) of \(chapters.count) · \(remaining)"
        }
        return shown.currentTime > 1 ? remaining : HearthFormat.duration(duration)
    }

    private var needsDownloadForReadAloud: Bool {
        guard let readAloud = alignedListenBook else { return false }
        return !engine.downloads.isDownloaded(readAloud)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ForEach(primaryActions) { action in
                    EmberButton(title: action.title, systemImage: action.glyph, tint: tint, action: action.run)
                        .frame(maxWidth: .infinity)
                }
            }

            if needsDownloadForReadAloud {
                DetailNotice(
                    glyph: "waveform.badge.magnifyingglass",
                    text: "Read-aloud book. Download it to listen along with the narration - reading works either way."
                )
            }

            HStack(spacing: 10) {
                if showsDownload {
                    DetailDownloadButton(book: shown, tint: tint)
                }
                QuietButton(
                    title: shown.isFinished ? "Mark unfinished" : "Mark finished",
                    systemImage: shown.isFinished ? "checkmark.circle.fill" : "checkmark.circle"
                ) {
                    toggleFinished()
                }
                Spacer(minLength: 0)
                moreMenu
            }
        }
    }

    private struct DetailPrimaryAction: Identifiable {
        let id: String
        let title: String
        let glyph: String
        let run: () -> Void
    }

    private var primaryActions: [DetailPrimaryAction] {
        let target = shown
        let readTarget = isEbook ? target : (counterpart ?? (alignedListenBook?.mediaType == .ebook ? alignedListenBook : nil))
        let listen = DetailPrimaryAction(id: "listen", title: "Listen", glyph: "play.fill") {
            PlatformHaptics.impact(.light)
            if isEbook, let counterpart {
                engine.playback.play(counterpart)
            } else if !isEbook {
                engine.playback.play(target)
            } else if let alignedListenBook {
                engine.playback.playAlignedReadAloud(alignedListenBook)
            }
        }
        let read = DetailPrimaryAction(
            id: "read",
            title: readerActionTitle(for: readTarget ?? target),
            glyph: readerActionGlyph(for: readTarget ?? target)
        ) {
            PlatformHaptics.impact(.light)
            guard let readTarget else { return }
            if let activity = matchingReaderActivity(for: readTarget) {
                if case .failed = activity.phase {
                    engine.readerOpen.retry()
                }
                return
            }
            engine.playback.openEbook(readTarget)
        }
        if isEbook {
            return counterpart != nil || alignedListenBook != nil ? [read, listen] : [read]
        }
        let hasReadPath = counterpart != nil || alignedListenBook != nil
        return hasReadPath ? [listen, read] : [listen]
    }

    private func matchingReaderActivity(for target: Book) -> ReaderOpenCoordinator.Activity? {
        guard let activity = engine.readerOpen.activity,
            activity.book.uniqueId == target.uniqueId
        else {
            return nil
        }
        return activity
    }

    private func readerActionTitle(for target: Book) -> String {
        guard let activity = matchingReaderActivity(for: target) else { return "Read" }
        switch activity.phase {
        case .downloading:
            guard let progress = readerDownloadProgress(for: activity) else {
                return "Downloading…"
            }
            return "Downloading \(Int((progress * 100).rounded()))%"
        case .preparing:
            return "Preparing…"
        case .failed:
            return "Try again"
        }
    }

    private func readerActionGlyph(for target: Book) -> String {
        guard let activity = matchingReaderActivity(for: target) else { return "book" }
        switch activity.phase {
        case .downloading:
            return "arrow.down"
        case .preparing:
            return "book"
        case .failed:
            return "arrow.clockwise"
        }
    }

    private func readerDownloadProgress(for activity: ReaderOpenCoordinator.Activity) -> Double? {
        if let direct = activity.directProgress, direct > 0 {
            return min(max(direct, 0), 1)
        }
        guard let task = engine.downloads.mostRelevantTask(for: activity.book),
            task.status == .downloading,
            task.totalBytes > 0 || task.progress > 0
        else {
            return nil
        }
        return min(max(task.progress, 0), 1)
    }

    private var showsDownload: Bool {
        engine.library.canDownload(shown)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                UIPasteboard.general.string = shown.title
            } label: {
                Label("Copy title", systemImage: "doc.on.doc")
            }

            Divider()

            if !isEbook {
                Button {
                    PlatformHaptics.impact(.light)
                    engine.playback.addNext(shown)
                } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                Button {
                    PlatformHaptics.impact(.light)
                    engine.playback.addLast(shown)
                } label: {
                    Label("Add to Up Next", systemImage: "text.append")
                }
                Divider()
            }

            Button {
                metadataTool = .editMetadata
            } label: {
                Label("Edit metadata", systemImage: "square.and.pencil")
            }
            Button {
                metadataTool = .findMatch
            } label: {
                Label("Find a better match", systemImage: "text.magnifyingglass")
            }
            if shown.mediaType != .podcast {
                Button {
                    metadataTool = .linkFormats
                } label: {
                    Label("Link ebook/audiobook", systemImage: "link")
                }
            }
            if shown.mediaType == .audiobook || shown.mediaType == .ebook {
                Button {
                    fetchChapters()
                } label: {
                    Label(
                        chapterFetcher.isFetching ? "Fetching chapters…" : "Fetch chapters",
                        systemImage: chapterFetcher.isFetching ? "hourglass" : "list.bullet.indent"
                    )
                }
                .disabled(chapterFetcher.isFetching)
            }
            if shown.source == .audiobookshelf, shown.mediaType == .audiobook {
                Button {
                    showChapterEditor = true
                } label: {
                    Label("Edit chapters", systemImage: "list.bullet.rectangle")
                }
            }

            if shown.source == .bookOrbit {
                Divider()
                Menu {
                    shelfButton("Want to Read", glyph: "bookmark", status: .wantToRead)
                    shelfButton("Reading", glyph: "book", status: .reading)
                    shelfButton("On Hold", glyph: "pause.circle", status: .onHold)
                    shelfButton("Finished", glyph: "checkmark.circle", status: .read)
                    shelfButton("Abandoned", glyph: "flag.slash", status: .abandoned)
                } label: {
                    Label("BookOrbit shelf", systemImage: "books.vertical")
                }
                if canManageBookOrbitCollections {
                    Button {
                        bookOrbitCollectionsShown = true
                    } label: {
                        Label("BookOrbit collections", systemImage: "rectangle.stack.badge.plus")
                    }
                }
            }

            if shown.currentTime > 0 || (shown.ebookProgress ?? 0) > 0 || shown.isFinished {
                Button {
                    engine.library.resetProgressToBeginning(for: shown)
                    Task { await refresh() }
                } label: {
                    Label("Reset progress", systemImage: "arrow.counterclockwise")
                }
            }

            Divider()

            Button(role: .destructive) {
                hideBook()
            } label: {
                Label("Hide from library", systemImage: "eye.slash")
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete from library", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.hearthUI(17, weight: .semibold))
                .foregroundStyle(hearth.text)
                .frame(width: 44, height: 44)
                .background {
                    HearthChromeBackground(
                        shape: .circle,
                        fill: hearth.bgElevated,
                        stroke: hearth.hairline,
                        tint: hearth.bgElevated
                    )
                }
        }
        .accessibilityLabel("More")
    }

    private func toggleFinished() {
        if shown.source == .bookOrbit {
            setShelfStatus(shown.isFinished ? .reading : .read)
            return
        }
        if shown.isFinished {
            PlatformHaptics.impact(.light)
        } else {
            PlatformHaptics.notification(.success)
        }
        live = engine.library.toggleFinished(shown)
    }

    private func shelfButton(_ title: String, glyph: String, status: BookOrbitProvider.BookOrbitReadStatus) -> some View {
        Button {
            setShelfStatus(status)
        } label: {
            Label(title, systemImage: shelf.current == status ? "checkmark" : glyph)
        }
        .disabled(shelf.isUpdating)
    }

    private func setShelfStatus(_ status: BookOrbitProvider.BookOrbitReadStatus) {
        PlatformHaptics.impact(.light)
        Task {
            await shelf.set(status, book: shown, library: engine.library)
            await refresh()
        }
    }

    private func fetchChapters() {
        guard !chapterFetcher.isFetching else { return }
        PlatformHaptics.impact(.light)
        Task {
            await chapterFetcher.fetch(book: shown, library: engine.library)
            await refresh()
        }
    }

    private func autoFetchChaptersIfNeeded() {
        guard !didAutoFetchChapters, shown.mediaType == .audiobook || shown.mediaType == .ebook, chapterList.isEmpty else { return }
        didAutoFetchChapters = true
        Task {
            await chapterFetcher.fetch(book: shown, library: engine.library)
            await refresh()
        }
    }

    private func hideBook() {
        let target = shown
        PlatformHaptics.impact(.medium)
        Task { await engine.library.hide(target) }
        dismiss()
    }

    private var descriptionText: String? {
        DescriptionNormalizer.normalize(shown.description)
    }

    private func description(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.hearthDisplay(16, weight: .regular))
                .lineSpacing(5)
                .foregroundStyle(hearth.text)
                .lineLimit(descriptionExpanded ? nil : 6)
            if descriptionNeedsExpansion(text) {
                Button(descriptionExpanded ? "Less" : "More") {
                    withAnimation(.smooth(duration: 0.35)) { descriptionExpanded.toggle() }
                }
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(hearth.ember)
            }
        }
    }

    private func descriptionNeedsExpansion(_ text: String) -> Bool {
        text.count > 280 || text.filter(\.isNewline).count >= 6
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 16) {
            Overline("Details")
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                alignment: .leading,
                spacing: 18
            ) {
                if !isEbook, let duration = shown.duration, duration > 0 {
                    aboutCell("Length", HearthFormat.duration(duration))
                }
                if let narrator = shown.narrator, !narrator.isEmpty {
                    aboutCell("Narrator", narrator)
                }
                if let year = shown.publishedYear {
                    aboutCell("Published", String(year))
                }
                if let publisher = shown.publisher, !publisher.isEmpty {
                    aboutCell("Publisher", publisher)
                }
                if let language = shown.language, !language.isEmpty {
                    aboutCell("Language", language.uppercased())
                }
                if let format = formatLabel {
                    aboutCell("Format", format)
                }
                if let genres = shown.genres, !genres.isEmpty {
                    aboutCell("Genres", genres.prefix(3).joined(separator: ", "))
                }
                if let isbn = shown.isbn, !isbn.isEmpty {
                    aboutCell("ISBN", isbn)
                }
                if let added = shown.addedAt {
                    aboutCell("Added", added.formatted(date: .abbreviated, time: .omitted))
                }
                if let credits = comicCredits {
                    if let releaseDate = credits.releaseDate {
                        aboutCell("Released", releaseDate.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let pages = credits.pageCount {
                        aboutCell("Pages", String(pages))
                    }
                    ForEach(credits.roles) { group in
                        aboutCell(group.displayName, group.names.joined(separator: ", "))
                    }
                }
                sourceCell
            }
        }
    }

    private var formatLabel: String? {
        if isEbook {
            return (shown.ebookFormat ?? shown.ebookFileURL?.pathExtension)?.uppercased()
        }
        if let codec = shown.audioTracks?.first?.format, !codec.isEmpty {
            return codec.uppercased()
        }
        return nil
    }

    private func aboutCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Overline(label, color: hearth.textTertiary)
            Text(value)
                .font(.hearthUI(15, weight: .medium))
                .foregroundStyle(hearth.text)
        }
    }

    private var sourceCell: some View {
        let connection = engine.library.sourceConnection(for: shown)
        return VStack(alignment: .leading, spacing: 5) {
            Overline("Source", color: hearth.textTertiary)
            HStack(spacing: 6) {
                if let asset = connection?.iconAssetName {
                    Image(asset)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .opacity(0.85)
                } else {
                    Image(systemName: connection?.iconSystemName ?? "internaldrive")
                        .font(.hearthUI(12))
                        .foregroundStyle(hearth.textSecondary)
                }
                Text(connection?.name ?? (shown.source == .local ? "On this device" : shown.source.rawValue.capitalized))
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
            }
        }
    }

    private var chapterList: [Chapter] {

        let source = (shown.chapters?.isEmpty == false) ? shown.chapters! : cachedChapters
        return source.sorted { $0.start < $1.start }
    }

    private func reloadCachedChapters() {
        cachedChapters =
            ReaderArtifactsStore.shared.loadCachedChapters(bookId: shown.stableId)
            ?? ReaderArtifactsStore.shared.loadCachedChapters(bookId: book.id)
            ?? []
    }

    private var chaptersSection: some View {
        let chapters = chapterList
        let visible = allChaptersShown ? chapters : Array(chapters.prefix(8))
        return VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Chapters")
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, chapter in
                    chapterRow(chapter, index: index)
                    if chapter.id != visible.last?.id {
                        Rectangle()
                            .fill(hearth.hairline)
                            .frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 24)

            if chapters.count > 8 {
                Button(allChaptersShown ? "Fewer chapters" : "All \(chapters.count) chapters") {
                    withAnimation(.smooth(duration: 0.35)) { allChaptersShown.toggle() }
                }
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(hearth.ember)
                .padding(.horizontal, 24)
            }
        }
    }

    private var chaptersEmptySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Chapters")
            VStack(alignment: .leading, spacing: 12) {
                Text("This book arrived without chapter marks.")
                    .font(.hearthUI(14))
                    .foregroundStyle(hearth.textSecondary)
                QuietButton(
                    title: chapterFetcher.isFetching ? "Looking…" : "Find chapters",
                    systemImage: "list.bullet"
                ) {
                    fetchChapters()
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var chapterFetchStatus: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(hearth.ember)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text("Looking for chapters")
                    .font(.hearthUI(14, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Text("Checking sidecars, server metadata, and embedded audio markers.")
                    .font(.hearthUI(12))
                    .foregroundStyle(hearth.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                )
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func chapterRow(_ chapter: Chapter, index: Int) -> some View {
        let isCurrent = !isEbook && !shown.isFinished && shown.currentTime >= chapter.start && shown.currentTime < chapter.end
        if isEbook {
            chapterRowContent(chapter, index: index, isCurrent: false)
                .padding(.vertical, 13)
        } else if let track = separableTrack(for: chapter) {
            chapterButton(chapter, index: index, isCurrent: isCurrent)
                .contextMenu {
                    Button {
                        PlatformHaptics.impact(.medium)
                        pendingSeparation = PendingChapterSeparation(
                            track: track,
                            title: chapterTitle(chapter, index: index)
                        )
                    } label: {
                        Label("Separate into Book", systemImage: "square.split.1x2")
                    }
                }
        } else {
            chapterButton(chapter, index: index, isCurrent: isCurrent)
        }
    }

    private func chapterButton(_ chapter: Chapter, index: Int, isCurrent: Bool) -> some View {
        Button {
            playChapter(chapter)
        } label: {
            chapterRowContent(chapter, index: index, isCurrent: isCurrent)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func separableTrack(for chapter: Chapter) -> AudioTrack? {
        guard shown.mediaType == .audiobook,
            shown.source == .local || shown.source == .smb,
            let tracks = shown.audioTracks,
            tracks.count > 1
        else {
            return nil
        }
        return tracks.first { abs($0.startOffset - chapter.start) < 1 }
    }

    private func separate(_ pending: PendingChapterSeparation) {
        Task {
            do {
                try await engine.library.separateTrackIntoBook(pending.track, from: shown)
                PlatformHaptics.notification(.success)
                dismiss()
            } catch {
                separationError = "Couldn’t separate \"\(pending.title)\" into its own book. \(error.localizedDescription)"
            }
        }
    }

    private func chapterTitle(_ chapter: Chapter, index: Int) -> String {
        chapter.title.isEmpty ? "Chapter \(index + 1)" : chapter.title
    }

    private func chapterRowContent(_ chapter: Chapter, index: Int, isCurrent: Bool) -> some View {
        HStack(spacing: 14) {
            Text("\(index + 1)")
                .font(.hearthUI(13, weight: .medium).monospacedDigit())
                .foregroundStyle(isCurrent ? tint : hearth.textTertiary)
                .frame(width: 26, alignment: .trailing)
            Text(chapterTitle(chapter, index: index))
                .font(.hearthDisplay(15, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(hearth.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !isEbook {
                Text(HearthFormat.clock(chapter.duration))
                    .font(.hearthUI(13).monospacedDigit())
                    .foregroundStyle(hearth.textTertiary)
            }
        }
    }

    private func playChapter(_ chapter: Chapter) {
        PlatformHaptics.selection()
        engine.playback.playChapter(chapter, in: shown)
    }

    private var seriesShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "In this series")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .bottom, spacing: 16) {
                    ForEach(inSeries, id: \.stableId) { sibling in
                        NavigationLink {
                            BookDetailScreen(book: sibling)
                        } label: {
                            ShelfCoverCell(book: sibling, width: 104)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func versionsLine(_ summary: LibraryWorkSummary) -> String {
        let copies = summary.sources == 1 ? "one copy" : "\(summary.sources) copies"
        if summary.editions > 1 {
            return "Listen, read, and every copy in one place · \(copies)"
        }
        return "The same book across \(copies)"
    }

    private func refresh() async {
        let snapshot = await engine.library.detailSnapshot(for: book, current: live)
        let fresh = snapshot.book
        live = fresh
        tint = await AmbientColorStore.shared.resolve(for: fresh)
        counterpart = snapshot.counterpart
        inSeries = snapshot.inSeries
        workSummary = snapshot.workSummary
    }
}

private struct DetailNotice: View {
    let glyph: String
    let text: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: glyph)
                .font(.hearthUI(13, weight: .semibold))
                .foregroundStyle(hearth.textTertiary)
            Text(text)
                .font(.hearthUI(13))
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                .fill(hearth.bgElevated)
        }
    }
}
