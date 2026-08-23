import Combine
import SwiftUI

struct LibraryScreen: View {

    var isActive: Bool = true

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.shellNavigationStyle) private var shellNavigationStyle

    @State private var model = LibraryModel()
    @State private var searchText = ""
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool
    @State private var showFilesImport = false
    @State private var showAddSource = false
    @State private var showOPDSImport = false
    @State private var showLibraryControls = false
    @State private var collectionSelection: LibraryCollectionSelection?
    @State private var visibleScopeRefreshInProgress = false
    #if DEBUG
    @State private var didPresentDebugCollectionSelection = false
    @State private var didPresentDebugLibraryControls = false
    #endif
    @AppStorage("library.gridColumns") private var gridColumns = 0

    private var searchRestInset: CGFloat {
        switch shellNavigationStyle {
        case .classic: MantelBar.height + 12
        case .liquidGlass: MantelBar.liquidHeight - 18 + 12
        }
    }

    var body: some View {
        GeometryReader { geo in
            let contentWidth = HearthAdaptive.contentWidth(for: geo.size.width, maximum: HearthAdaptive.wideReadableWidth)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(width: contentWidth)
                    scopeRow
                    if !model.isSearchActive {
                        shelvesHub
                    }
                    chipRow
                    if !model.isSearchActive {
                        facetRow
                    }
                    content(width: contentWidth)
                }
                .hearthReadableFrame(width: geo.size.width, maximum: HearthAdaptive.wideReadableWidth)
                .padding(.top, 8)

                .padding(.bottom, mantelInset + (model.isSelecting ? 76 : 80))
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                await refreshVisibleLibraryScope()
            }
        }
        .background(HearthBackground())
        .accessibilityIdentifier("library-screen")
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) {
            if model.isSelecting {
                LibrarySelectionBar(model: model) { books in
                    guard !books.isEmpty else { return }
                    collectionSelection = LibraryCollectionSelection(books: books)
                }
                .padding(.bottom, mantelInset + 10)
            } else {
                HearthFloatingSearch(
                    text: $searchText,
                    expanded: $searchExpanded,
                    focused: $searchFocused,
                    restInset: searchRestInset
                )
            }
        }
        .navigationDestination(isPresented: $showAddSource) {
            SourcesQuickConnectScreen()
        }
        .navigationDestination(isPresented: $showOPDSImport) {
            SourcesOPDSBulkScreen()
        }
        .sheet(isPresented: $showFilesImport) {
            SourcesFilesScreen(onAdded: { showFilesImport = false })
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .sheet(isPresented: $showLibraryControls) {
            LibraryControlsSheet(model: model)
                .enveEnvironment()
                .hearthPresentationBackground()
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $collectionSelection) { selection in
            CollectionsBatchAddSheet(books: selection.books)
                .enveEnvironment()
                .presentationDetents([.medium, .large])
        }
        .task(id: isActive) {
            guard isActive else { return }
            await engine.sources.refreshLibrarySourceNamesIfNeeded()

            if model.hasLoaded {
                await model.reload()
            } else {
                await model.bootstrap()
            }
            presentDebugCollectionSelectionIfRequested()
            presentDebugLibraryControlsIfRequested()
            var pendingReload: Task<Void, Never>?
            defer { pendingReload?.cancel() }
            for await _ in engine.library.libraryChanges() {
                pendingReload?.cancel()
                pendingReload = Task {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled else { return }
                    await model.reload()
                }
            }
        }
        .task(id: isActive) {
            guard isActive else { return }
            for await _ in AppRefreshEvents.stream(
                names: [
                    UnifiedDownloadService.downloadCompletedNotification,
                    .localLibraryUpdated,
                ],
                debounce: .milliseconds(150)
            ) {
                await model.reload()
            }
        }
        .onChange(of: searchText) { _, newValue in
            model.updateSearch(newValue)
        }
        .onChange(of: searchFocused) { _, isFocused in

            if !isFocused && searchText.isEmpty {
                searchExpanded = false
            }
        }
    }

    private func header(width: CGFloat) -> some View {
        let effectiveColumns = HearthAdaptive.bookGridCount(width: width, preferred: gridColumns)
        let compact = width < 520
        return VStack(alignment: .leading, spacing: 7) {
            Overline("The stacks")
            HStack(alignment: .center, spacing: 12) {
                Text("Library")
                    .font(.hearthScreenTitle)
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 6)
                headerControls(effectiveColumns: effectiveColumns, compact: compact)
            }
        }
        .padding(.horizontal, 24)
    }

    private func headerControls(effectiveColumns: Int, compact: Bool) -> some View {
        let buttonSize: CGFloat = compact ? 40 : 44
        return HStack(spacing: compact ? 6 : 8) {
            if visibleScopeRefreshInProgress {
                ProgressView()
                    .tint(hearth.ember)
                    .frame(width: buttonSize, height: buttonSize)
                    .background {
                        HearthChromeBackground(
                            shape: .circle,
                            fill: hearth.bgElevated,
                            stroke: hearth.hairline,
                            tint: hearth.bgElevated
                        )
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Refreshing sources")
            } else {
                GlyphButton(
                    systemImage: "arrow.clockwise",
                    size: buttonSize,
                    glyphSize: 15,
                    label: "Refresh sources"
                ) {
                    PlatformHaptics.impact(.light)
                    Task { await refreshVisibleLibraryScope() }
                }
            }
            importMenu(size: buttonSize)
            if showsBookControls {
                GlyphButton(
                    systemImage: model.isSelecting ? "checkmark.circle.fill" : "checkmark.circle",
                    size: buttonSize,
                    glyphSize: 16,
                    prominent: model.isSelecting,
                    label: model.isSelecting ? "Done choosing" : "Choose books"
                ) {
                    PlatformHaptics.selection()
                    model.toggleSelecting()
                }
            }
            GlyphButton(
                systemImage: displayGlyph,
                size: buttonSize,
                glyphSize: 15,
                label: displayCycleLabel(effectiveColumns: effectiveColumns, compact: compact)
            ) {
                PlatformHaptics.selection()
                cycleDisplay(effectiveColumns: effectiveColumns, compact: compact)
            }
        }
        .fixedSize()
    }

    private var showsBookControls: Bool {
        model.isSearchActive || model.facet == .books
    }

    private func refreshVisibleLibraryScope() async {
        guard !visibleScopeRefreshInProgress else { return }
        visibleScopeRefreshInProgress = true
        defer { visibleScopeRefreshInProgress = false }
        await engine.sources.refreshVisibleLibraryScope(model.sourceFilter)
        await model.reload()
    }

    private func presentDebugCollectionSelectionIfRequested() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard !didPresentDebugCollectionSelection,
            let routeIndex = arguments.firstIndex(of: "-imagineScreen"),
            arguments.indices.contains(routeIndex + 1),
            ["librarybatch", "librarybatchbar"].contains(arguments[routeIndex + 1])
        else { return }
        didPresentDebugCollectionSelection = true
        let books = Array(model.displayBooks.prefix(2))
        guard !books.isEmpty else { return }
        if !model.isSelecting {
            model.toggleSelecting()
        }
        for book in books where !model.isSelected(book) {
            model.toggleSelected(book)
        }
        if arguments[routeIndex + 1] == "librarybatch" {
            collectionSelection = LibraryCollectionSelection(books: books)
        }
        #endif
    }

    private func presentDebugLibraryControlsIfRequested() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard !didPresentDebugLibraryControls,
            let routeIndex = arguments.firstIndex(of: "-imagineScreen"),
            arguments.indices.contains(routeIndex + 1),
            arguments[routeIndex + 1] == "libraryfilters"
        else { return }
        didPresentDebugLibraryControls = true
        showLibraryControls = true
        #endif
    }

    private var shelvesHub: some View {
        quickShelves
            .padding(.top, 2)
    }

    private var quickShelves: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShelfHeader(title: "Shelves")
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    LibraryShelfButton(
                        glyph: "books.vertical",
                        title: "Everything",
                        line: "All sources",
                        isActive: isShelfActive(status: .all, media: .all, source: .all)
                    ) {
                        focusShelf(status: .all, media: .all, source: .all)
                    }
                    LibraryShelfButton(
                        glyph: "play.circle",
                        title: "In progress",
                        line: "Audiobooks",
                        isActive: isShelfActive(status: .listening, media: .all, source: .all)
                    ) {
                        focusShelf(status: .listening, media: .all, source: .all)
                    }
                    LibraryShelfButton(
                        glyph: "book.pages",
                        title: "Reading",
                        line: "Ebooks & comics",
                        isActive: isShelfActive(status: .reading, media: .ebooks, source: .all)
                    ) {
                        focusShelf(status: .reading, media: .ebooks, source: .all)
                    }
                    LibraryShelfButton(
                        glyph: "arrow.down.circle",
                        title: "Downloaded",
                        line: "On this device",
                        isActive: isShelfActive(status: .downloaded, media: .all, source: .all)
                    ) {
                        focusShelf(status: .downloaded, media: .all, source: .all)
                    }
                    NavigationLink {
                        CollectionsScreen()
                    } label: {
                        LibraryShelfLabel(glyph: "folder", title: "Collections", line: "Smart shelves")
                    }
                    .buttonStyle(PressableStyle())
                    NavigationLink {
                        DiscoverScreen()
                    } label: {
                        LibraryShelfLabel(glyph: "sparkles", title: "Discover", line: "Find new books")
                    }
                    .buttonStyle(PressableStyle())
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func importMenu(size: CGFloat = 44) -> some View {
        Menu {
            Button {
                showFilesImport = true
            } label: {
                Label("Import from Files", systemImage: "folder")
            }
            Button {
                showOPDSImport = true
            } label: {
                Label("Import from an OPDS catalog", systemImage: "books.vertical")
            }
            Button {
                showAddSource = true
            } label: {
                Label("Add a source", systemImage: "externaldrive.badge.plus")
            }
        } label: {
            Image(systemName: "plus")
                .font(.hearthUI(16, weight: .semibold))
                .foregroundStyle(hearth.text)
                .frame(width: size, height: size)
                .background {
                    HearthChromeBackground(
                        shape: .circle,
                        fill: hearth.bgElevated,
                        stroke: hearth.hairline,
                        tint: hearth.bgElevated
                    )
                }
        }
        .accessibilityLabel("Add books")
    }

    private var displayGlyph: String {
        model.layout == .grid ? "square.grid.3x3" : "list.bullet"
    }

    private func displayCycleLabel(effectiveColumns: Int, compact: Bool) -> String {
        if model.layout == .list {
            return "Show grid"
        }
        let maximum = compact ? 4 : 12
        if effectiveColumns >= maximum {
            return "Show as list"
        }
        return "Cover size, \(effectiveColumns + 1) columns"
    }

    private func cycleDisplay(effectiveColumns: Int, compact: Bool) {
        let minimum = compact ? 2 : 5
        let maximum = compact ? 4 : 12
        if model.layout == .list {
            gridColumns = minimum
            model.selectLayout(.grid)
        } else if effectiveColumns >= maximum {
            model.selectLayout(.list)
        } else {
            gridColumns = min(effectiveColumns + 1, maximum)
        }
    }

    private var chipRow: some View {
        HStack(spacing: 12) {
            Button {
                showLibraryControls = true
            } label: {
                LibraryMenuChip(
                    title: controlsTitle,
                    systemImage: "line.3.horizontal.decrease",
                    isActive: model.isNarrowed || !model.usesDefaultSorting
                )
            }
            Spacer(minLength: 8)
            if model.facet == .books || model.isSearchActive {
                Text(model.resultSummary)
                    .font(.hearthCaption.monospacedDigit())
                    .foregroundStyle(hearth.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 24)
    }

    private var scopeRow: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    selectSource(.all)
                } label: {
                    sourceMenuLabel("All sources", isSelected: model.sourceFilter == .all)
                }
                Button {
                    selectSource(.device)
                } label: {
                    sourceMenuLabel("This device", isSelected: model.sourceFilter == .device)
                }
                if !activeConnections.isEmpty {
                    Divider()
                }
                ForEach(activeConnections, id: \.id) { connection in
                    Button {
                        selectSource(.connection(connection.id))
                    } label: {
                        sourceMenuLabel(connection.name, isSelected: model.sourceFilter == .connection(connection.id))
                    }
                }
            } label: {
                LibraryScopeButton(
                    title: sourceFilterTitle,
                    subtitle: "Source",
                    systemImage: "externaldrive.connected.to.line.below",
                    isActive: model.sourceFilter != .all
                )
            }
            libraryMenu
        }
        .padding(.horizontal, 24)
    }

    private var libraryMenu: some View {
        Menu {
            libraryMenuContent
        } label: {
            LibraryScopeButton(
                title: libraryFilterTitle,
                subtitle: "Library",
                systemImage: "books.vertical",
                isActive: model.sourceFilter.libraryId != nil
            )
        }
    }

    @ViewBuilder
    private var libraryMenuContent: some View {
        if let providerId = model.sourceFilter.providerId,
            let connection = activeConnections.first(where: { $0.id == providerId })
        {
            Button {
                selectSource(.connection(providerId))
            } label: {
                sourceMenuLabel("All in \(connection.name)", isSelected: model.sourceFilter == .connection(providerId))
            }
            ForEach(libraries(for: providerId), id: \.uniqueId) { library in
                Button {
                    selectSource(.library(providerId: providerId, libraryId: library.id))
                } label: {
                    sourceMenuLabel(library.name, isSelected: model.sourceFilter == .library(providerId: providerId, libraryId: library.id))
                }
            }
        } else if activeProviderLibraries.isEmpty {
            Text("No server libraries")
        } else {
            ForEach(activeConnections, id: \.id) { connection in
                let libraries = libraries(for: connection.id)
                if !libraries.isEmpty {
                    Section(connection.name) {
                        Button {
                            selectSource(.connection(connection.id))
                        } label: {
                            sourceMenuLabel("All libraries", isSelected: model.sourceFilter == .connection(connection.id))
                        }
                        ForEach(libraries, id: \.uniqueId) { library in
                            Button {
                                selectSource(.library(providerId: connection.id, libraryId: library.id))
                            } label: {
                                sourceMenuLabel(
                                    library.name,
                                    isSelected: model.sourceFilter == .library(providerId: connection.id, libraryId: library.id)
                                )
                            }
                        }
                    }
                }
            }
        }

    }

    private var mediaBinding: Binding<LibraryMediaFilter> {
        Binding(get: { model.media }, set: { model.select($0) })
    }

    private var controlsTitle: String {
        if model.activeFilterCount > 0 {
            return "Filters \(model.activeFilterCount)"
        }
        return model.usesDefaultSorting ? "Filter & Sort" : "Sort: \(model.sort.title)"
    }

    private var sourceSnapshot: LibrarySourceSnapshot {
        engine.sources.librarySourceSnapshot
    }

    private var activeConnections: [LibrarySourceConnectionSummary] {
        sourceSnapshot.connections
    }

    private var activeProviderLibraries: [LibrarySourceLibrarySummary] {
        sourceSnapshot.libraries
    }

    private var sourceFilterTitle: String {
        switch model.sourceFilter {
        case .all: "All sources"
        case .device: "This device"
        case let .connection(id), let .library(id, _):
            sourceTitle(id)
        }
    }

    private var libraryFilterTitle: String {
        switch model.sourceFilter {
        case let .library(providerId, libraryId):
            libraries(for: providerId).first { $0.id == libraryId }?.name ?? "Library"
        case .connection:
            "All libraries"
        case .all:
            "All libraries"
        case .device:
            "Device"
        }
    }

    private func sourceTitle(_ id: UUID) -> String {
        activeConnections.first { $0.id == id }?.name ?? "Source"
    }

    private func libraries(for providerId: UUID) -> [LibrarySourceLibrarySummary] {
        activeProviderLibraries
            .filter { $0.providerId == providerId }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func sourceMenuLabel(_ title: String, isSelected: Bool) -> Label<Text, Image> {
        Label(title, systemImage: isSelected ? "checkmark.circle.fill" : "circle")
    }

    private func selectSource(_ source: LibrarySourceFilter) {
        PlatformHaptics.selection()
        model.select(source)
    }

    private func focusShelf(
        status: LibraryStatusFilter,
        media: LibraryMediaFilter,
        source: LibrarySourceFilter,
        facet: LibraryFacet = .books
    ) {
        PlatformHaptics.selection()
        model.focus(status: status, media: media, source: source, facet: facet)
    }

    private func isShelfActive(
        status: LibraryStatusFilter,
        media: LibraryMediaFilter,
        source: LibrarySourceFilter,
        facet: LibraryFacet = .books
    ) -> Bool {
        model.status == status && model.media == media && model.sourceFilter == source && model.facet == facet
    }

    private var facetRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 24) {
                ForEach(LibraryFacet.allCases, id: \.self) { facet in
                    Button {
                        PlatformHaptics.selection()
                        model.select(facet)
                    } label: {
                        VStack(spacing: 5) {
                            Overline(facet.title, color: model.facet == facet ? hearth.ember : nil)
                            Capsule()
                                .fill(model.facet == facet ? hearth.ember : .clear)
                                .frame(width: 22, height: 2)
                        }
                    }
                    .buttonStyle(PressableStyle())
                }
                NavigationLink {
                    CollectionsScreen()
                } label: {
                    VStack(spacing: 5) {
                        Overline("Collections")
                        Capsule()
                            .fill(.clear)
                            .frame(width: 22, height: 2)
                    }
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if !model.hasLoaded {
            loadingStacks
        } else if model.totalLibraryCount == 0 {
            emptyLibrary
        } else if model.isSearchActive {
            if model.displayBooks.isEmpty {
                quietNote("Nothing answers to that name.")
            } else {
                bookResults(width: width)
            }
        } else {
            switch model.facet {
            case .books:
                if model.media == .podcasts {
                    browseShowsLink
                }
                if model.displayBooks.isEmpty {
                    if model.isNarrowed {
                        filteredEmpty
                    } else {
                        quietNote("Nothing here yet.")
                    }
                } else {
                    bookResults(width: width)
                }
            case .series:
                if model.seriesAggregates.isEmpty {
                    quietNote("No series shelved yet.")
                } else if model.layout == .grid {
                    let spec = browseGridSpec(width: width)
                    LazyVGrid(columns: spec.columns, spacing: 20) {
                        ForEach(model.seriesAggregates, id: \.name) { aggregate in
                            LibrarySeriesGridCell(aggregate: aggregate, mediaScope: model.mediaScope, width: spec.cellWidth)
                        }
                    }
                    .padding(.horizontal, spec.padding)
                } else {
                    LazyVStack(spacing: 18) {
                        ForEach(model.seriesAggregates, id: \.name) { aggregate in
                            LibrarySeriesRow(aggregate: aggregate, mediaScope: model.mediaScope)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            case .authors:
                if model.authorAggregates.isEmpty {
                    quietNote("No authors on the shelves yet.")
                } else if model.layout == .grid {
                    let spec = browseGridSpec(width: width)
                    LazyVGrid(columns: spec.columns, spacing: 20) {
                        ForEach(model.authorAggregates, id: \.name) { aggregate in
                            LibraryAuthorGridCell(aggregate: aggregate, mediaScope: model.mediaScope, width: spec.cellWidth)
                        }
                    }
                    .padding(.horizontal, spec.padding)
                } else {
                    LazyVStack(spacing: 18) {
                        ForEach(model.authorAggregates, id: \.name) { aggregate in
                            LibraryAuthorRow(aggregate: aggregate, mediaScope: model.mediaScope)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            case .narrators:
                if model.narratorAggregates.isEmpty {
                    quietNote("No narrators on record yet.")
                } else if model.layout == .grid {
                    let spec = browseGridSpec(width: width)
                    LazyVGrid(columns: spec.columns, spacing: 20) {
                        ForEach(model.narratorAggregates, id: \.name) { aggregate in
                            LibraryNarratorGridCell(aggregate: aggregate, mediaScope: model.mediaScope, width: spec.cellWidth)
                        }
                    }
                    .padding(.horizontal, spec.padding)
                } else {
                    LazyVStack(spacing: 18) {
                        ForEach(model.narratorAggregates, id: \.name) { aggregate in
                            LibraryNarratorRow(aggregate: aggregate, mediaScope: model.mediaScope)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            case .genres:
                if model.genreAggregates.isEmpty {
                    quietNote("No genres on record yet.")
                } else if model.layout == .grid {
                    let spec = browseGridSpec(width: width)
                    LazyVGrid(columns: spec.columns, spacing: 20) {
                        ForEach(model.genreAggregates, id: \.name) { aggregate in
                            LibraryGenreGridCell(aggregate: aggregate, width: spec.cellWidth) {
                                await model.books(forGenre: aggregate)
                            }
                        }
                    }
                    .padding(.horizontal, spec.padding)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(model.genreAggregates, id: \.name) { aggregate in
                            LibraryGenreRow(aggregate: aggregate) {
                                await model.books(forGenre: aggregate)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            case .shows:
                showsContent
            }
        }
    }

    @ViewBuilder
    private func bookResults(width: CGFloat) -> some View {

        if model.layout == .grid {
            LibraryBookGrid(
                books: model.displayBooks,
                width: width,
                columns: gridColumns,
                onBookAppear: { model.loadNextPageIfNeeded(currentBookId: $0.uniqueId) },
                onHide: { model.hide($0) },
                workRefFor: { model.consolidatedWork(for: $0) },
                isDownloaded: { model.isDownloaded($0) },
                isSelecting: model.isSelecting,
                isSelected: { model.isSelected($0) },
                onToggleSelect: { model.toggleSelected($0) }
            )
        } else {
            LazyVStack(spacing: 14) {
                ForEach(model.displayBooks, id: \.uniqueId) { book in
                    LibraryBookRow(
                        book: book,
                        workRef: model.consolidatedWork(for: book),
                        isDownloaded: model.isDownloaded(book),
                        isSelecting: model.isSelecting,
                        isSelected: model.isSelected(book),
                        onToggleSelect: { model.toggleSelected($0) },
                        onHide: { model.hide($0) }
                    )
                    .onAppear { model.loadNextPageIfNeeded(currentBookId: book.uniqueId) }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func browseGridSpec(width: CGFloat) -> (columns: [GridItem], cellWidth: CGFloat, padding: CGFloat) {
        let count = HearthAdaptive.bookGridCount(width: width, preferred: gridColumns)
        let spacing: CGFloat = HearthAdaptive.isWide(width) ? 18 : 12
        let padding = HearthAdaptive.horizontalPadding(for: width)
        let cellWidth = max((width - padding * 2 - CGFloat(count - 1) * spacing) / CGFloat(count), 72)
        return (Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: count), cellWidth, padding)
    }

    private var showsContent: some View {
        let podcasts = PodcastsModel.shared
        return VStack(alignment: .leading, spacing: 18) {
            browseShowsLink
            if podcasts.isLoading && podcasts.playableShows.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(hearth.ember)
                    Text("Gathering the feeds…")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if podcasts.playableShows.isEmpty {
                quietNote("No shows on the shelf yet.")
            } else {
                LazyVStack(spacing: 18) {
                    ForEach(podcasts.playableShows, id: \.id) { show in
                        LibraryShowRow(show: show)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private var browseShowsLink: some View {
        NavigationLink {
            PodcastBrowseScreen()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.ember)
                Text("Browse shows")
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background {
                HearthChromeBackground(
                    shape: .rounded(16),
                    fill: hearth.bgElevated,
                    stroke: hearth.hairline,
                    tint: hearth.bgElevated
                )
            }
        }
        .buttonStyle(PressableStyle())
        .padding(.horizontal, 24)
    }

    private var loadingStacks: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(hearth.ember)
            Text("Walking the stacks…")
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private func quietNote(_ text: String) -> some View {
        Text(text)
            .font(.hearthBody)
            .foregroundStyle(hearth.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 56)
    }

    private var filteredEmpty: some View {
        VStack(spacing: 16) {
            Text("Nothing matches this filter.")
                .font(.hearthDisplay(22))
                .foregroundStyle(hearth.text)
                .multilineTextAlignment(.center)
            Text("Your shelves aren't empty. A filter is just hiding them.")
                .font(.hearthUI(14))
                .foregroundStyle(hearth.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            QuietButton(title: "Show everything", systemImage: "line.3.horizontal.decrease.circle") {
                model.clearFilters()
                PlatformHaptics.selection()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 64)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            Text("The stacks are empty.")
                .font(.hearthDisplay(24))
                .foregroundStyle(hearth.text)
            NavigationLink {
                SourcesQuickConnectScreen()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.hearthUI(14, weight: .medium))
                    Text("Add a source")
                        .font(.hearthUI(15, weight: .medium))
                }
                .foregroundStyle(hearth.text)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background {
                    HearthChromeBackground(
                        shape: .capsule,
                        fill: hearth.bgElevated,
                        stroke: hearth.hairline,
                        tint: hearth.bgElevated
                    )
                }
            }
            .buttonStyle(PressableStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }
}

private struct LibraryCollectionSelection: Identifiable {
    let id = UUID()
    let books: [Book]
}

private struct LibraryShelfButton: View {
    let glyph: String
    let title: String
    let line: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LibraryShelfLabel(glyph: glyph, title: title, line: line, isActive: isActive)
        }
        .buttonStyle(PressableStyle())
    }
}

private struct LibraryShelfLabel: View {
    let glyph: String
    let title: String
    let line: String
    var isActive = false

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: glyph)
                .font(.hearthUI(13, weight: .semibold))
                .foregroundStyle(isActive ? hearth.readableOnEmber : hearth.ember)
                .frame(width: 16, height: 16)
            Text(title)
                .font(.hearthUI(12, weight: .semibold))
                .foregroundStyle(isActive ? hearth.readableOnEmber : hearth.text)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(height: 38)
        .padding(.horizontal, 12)
        .background {
            HearthChromeBackground(
                shape: .capsule,
                fill: isActive ? hearth.ember : hearth.bgElevated,
                stroke: isActive ? hearth.ember : hearth.hairline,
                tint: isActive ? hearth.ember : hearth.bgElevated
            )
        }
        .contentShape(Rectangle())
        .accessibilityLabel("\(title), \(line)")
    }
}

struct HearthFloatingSearch: View {
    @Binding var text: String
    @Binding var expanded: Bool
    var focused: FocusState<Bool>.Binding

    let restInset: CGFloat

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 0) {
            if expanded {
                field
            } else {
                Spacer(minLength: 0)
                glass
            }
        }
        .padding(.horizontal, 20)

        .padding(.bottom, restInset)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: expanded)
    }

    private var glass: some View {
        Button {
            expanded = true
            focused.wrappedValue = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.hearthUI(19, weight: .semibold))
                .foregroundStyle(hearth.ember)
                .frame(width: 54, height: 54)
                .background {
                    HearthChromeBackground(
                        shape: .circle,
                        fill: hearth.bgElevated,
                        stroke: hearth.hairline,
                        tint: hearth.ember
                    )
                }
                .shadow(color: .black.opacity(hearth.isInk ? 0.55 : 0.18), radius: 12, y: 4)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Search the library")
        .transition(.scale.combined(with: .opacity))
    }

    private var field: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.hearthUI(16, weight: .medium))
                .foregroundStyle(hearth.textTertiary)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text("Find a story…")
                        .font(.hearthDisplay(19, weight: .regular))
                        .italic()
                        .foregroundStyle(hearth.textTertiary)
                }
                TextField("", text: $text)
                    .font(.hearthDisplay(19, weight: .regular))
                    .foregroundStyle(hearth.text)
                    .focused(focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { focused.wrappedValue = false }
            }
            Button {
                text = ""
                focused.wrappedValue = false
                expanded = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.hearthUI(17))
                    .foregroundStyle(hearth.textTertiary)
                    .contentShape(Rectangle().inset(by: -12))
            }
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background {
            HearthChromeBackground(
                shape: .capsule,
                fill: hearth.bgElevated,
                stroke: hearth.hairline,
                tint: hearth.bgElevated
            )
        }
        .shadow(color: .black.opacity(hearth.isInk ? 0.55 : 0.18), radius: 14, y: 4)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}

struct LibraryScopeButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var isActive: Bool

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.hearthUI(14, weight: .semibold))
                .foregroundStyle(isActive ? hearth.ember : hearth.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle.uppercased())
                    .font(.hearthUI(9, weight: .semibold))
                    .foregroundStyle(isActive ? hearth.textSecondary : hearth.textTertiary)
                Text(title)
                    .font(.hearthUI(13, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Image(systemName: "chevron.down")
                .font(.hearthUI(9, weight: .semibold))
                .foregroundStyle(hearth.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .padding(.horizontal, 12)
        .background {
            HearthChromeBackground(
                shape: .rounded(14),
                fill: hearth.bgElevated,
                stroke: isActive ? hearth.ember.opacity(0.35) : hearth.hairline,
                tint: hearth.bgElevated
            )
        }
    }
}

struct LibraryMenuChip: View {
    let title: String
    var systemImage: String? = nil
    var isActive: Bool
    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.hearthUI(12, weight: .semibold))
            }
            Text(title)
                .font(.hearthUI(14, weight: isActive ? .semibold : .medium))
            Image(systemName: "chevron.down")
                .font(.hearthUI(9, weight: .semibold))
        }
        .foregroundStyle(isActive ? hearth.ember : hearth.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            HearthChromeBackground(
                shape: .capsule,
                fill: hearth.bgElevated,
                stroke: isActive ? hearth.ember.opacity(0.35) : hearth.hairline,
                tint: hearth.bgElevated
            )
        }
    }
}

private struct LibraryControlsSheet: View {
    let model: LibraryModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hearth) private var hearth

    private let columns = [
        GridItem(.adaptive(minimum: 132), spacing: 8, alignment: .leading)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Overline("Library")
                        Text("Filter & Sort")
                            .font(.hearthDisplay(28))
                            .foregroundStyle(hearth.text)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.ember)
                }

                controlSection("Sort priority") {
                    VStack(spacing: 8) {
                        ForEach(Array(model.sortDescriptors.enumerated()), id: \.element.field) { index, descriptor in
                            LibrarySortPriorityRow(
                                index: index,
                                descriptor: descriptor,
                                canMoveUp: index > 0,
                                canMoveDown: index < model.sortDescriptors.count - 1,
                                canRemove: model.sortDescriptors.count > 1,
                                onDirection: { direction in
                                    PlatformHaptics.selection()
                                    model.select(direction, for: descriptor.field)
                                },
                                onMoveUp: {
                                    PlatformHaptics.selection()
                                    model.moveSortUp(descriptor.field)
                                },
                                onMoveDown: {
                                    PlatformHaptics.selection()
                                    model.moveSortDown(descriptor.field)
                                },
                                onRemove: {
                                    PlatformHaptics.selection()
                                    model.removeSort(descriptor.field)
                                }
                            )
                        }
                    }
                }

                let availableSorts = LibrarySort.allCases.filter { sort in
                    !model.sortDescriptors.contains(where: { $0.field == sort })
                }
                if !availableSorts.isEmpty {
                    controlSection("Add sort") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            ForEach(availableSorts, id: \.self) { sort in
                                LibraryControlPill(
                                    title: sort.title,
                                    systemImage: "plus",
                                    isSelected: false
                                ) {
                                    PlatformHaptics.selection()
                                    model.addSort(sort)
                                }
                            }
                        }
                    }
                }

                controlSection("Primary direction") {
                    HStack(spacing: 8) {
                        ForEach(LibrarySortDirection.allCases, id: \.self) { direction in
                            LibraryControlPill(
                                title: direction.title,
                                systemImage: direction.glyph,
                                isSelected: model.sortDirection == direction
                            ) {
                                PlatformHaptics.selection()
                                model.select(direction)
                            }
                        }
                    }
                }

                controlSection("Status") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(LibraryStatusFilter.allCases, id: \.self) { status in
                            LibraryControlPill(
                                title: status.title,
                                isSelected: model.status == status
                            ) {
                                PlatformHaptics.selection()
                                model.select(status)
                            }
                        }
                    }
                }

                controlSection("Media") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(LibraryMediaFilter.allCases, id: \.self) { media in
                            LibraryControlPill(
                                title: media.title,
                                isSelected: model.media == media
                            ) {
                                PlatformHaptics.selection()
                                model.select(media)
                            }
                        }
                    }
                }

                controlSection("Rating") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach([nil, 3.0, 4.0, 4.5] as [Double?], id: \.self) { rating in
                            LibraryControlPill(
                                title: rating.map { "\(String(format: "%.1f", $0))+ stars" } ?? "Any rating",
                                isSelected: model.advancedFilters.minimumRating == rating
                            ) {
                                PlatformHaptics.selection()
                                model.selectMinimumRating(rating)
                            }
                        }
                    }
                }

                controlSection("Series") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(LibrarySeriesFilter.allCases, id: \.self) { series in
                            LibraryControlPill(
                                title: series.title,
                                isSelected: model.advancedFilters.series == series
                            ) {
                                PlatformHaptics.selection()
                                model.selectSeriesFilter(series)
                            }
                        }
                    }
                }

                if model.isLoadingAdvancedFilterOptions {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(hearth.ember)
                        Text("Gathering genres and languages…")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                } else {
                    let genres = Array(Set(model.advancedFilterOptions.genres).union(model.advancedFilters.genres))
                        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    if !genres.isEmpty {
                        controlSection("Genres") {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                                ForEach(genres, id: \.self) { genre in
                                    LibraryControlPill(
                                        title: genre,
                                        isSelected: model.advancedFilters.genres.contains(genre)
                                    ) {
                                        PlatformHaptics.selection()
                                        model.toggleGenre(genre)
                                    }
                                }
                            }
                        }
                    }

                    let languages = Array(Set(model.advancedFilterOptions.languages).union(model.advancedFilters.languages))
                        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    if !languages.isEmpty {
                        controlSection("Languages") {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                                ForEach(languages, id: \.self) { language in
                                    LibraryControlPill(
                                        title: language,
                                        isSelected: model.advancedFilters.languages.contains(language)
                                    ) {
                                        PlatformHaptics.selection()
                                        model.toggleLanguage(language)
                                    }
                                }
                            }
                        }
                    }
                }

                Button {
                    PlatformHaptics.selection()
                    model.clearFilters()
                    model.clearSorting()
                } label: {
                    Label("Reset filters and sorting", systemImage: "arrow.counterclockwise")
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background {
                            HearthChromeBackground(
                                shape: .capsule,
                                fill: hearth.bgElevated,
                                stroke: hearth.hairline,
                                tint: hearth.bgElevated
                            )
                        }
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .background(HearthBackground())
        .task {
            await model.loadAdvancedFilterOptions()
        }
    }

    @ViewBuilder
    private func controlSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Overline(title)
            content()
        }
    }
}

private struct LibrarySortPriorityRow: View {
    let index: Int
    let descriptor: LibrarySortDescriptor
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canRemove: Bool
    let onDirection: (LibrarySortDirection) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.hearthUI(13, weight: .bold))
                    .foregroundStyle(hearth.readableOnEmber)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(hearth.ember))

                Text(descriptor.title)
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 8)

                sortIconButton("chevron.up", isEnabled: canMoveUp, action: onMoveUp)
                sortIconButton("chevron.down", isEnabled: canMoveDown, action: onMoveDown)
                sortIconButton("xmark", isEnabled: canRemove, action: onRemove)
            }

            HStack(spacing: 8) {
                ForEach(LibrarySortDirection.allCases, id: \.self) { direction in
                    Button {
                        onDirection(direction)
                    } label: {
                        Label(direction.title, systemImage: direction.glyph)
                            .font(.hearthUI(13, weight: .semibold))
                            .foregroundStyle(descriptor.direction == direction ? hearth.readableOnEmber : hearth.text)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background {
                                HearthChromeBackground(
                                    shape: .capsule,
                                    fill: descriptor.direction == direction ? hearth.ember : hearth.bgElevated,
                                    stroke: descriptor.direction == direction ? hearth.ember : hearth.hairline,
                                    tint: descriptor.direction == direction ? hearth.ember : hearth.bgElevated
                                )
                            }
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .padding(12)
        .background {
            HearthChromeBackground(
                shape: .rounded(22),
                fill: hearth.bgElevated,
                stroke: hearth.hairline,
                tint: hearth.bgElevated
            )
        }
    }

    private func sortIconButton(
        _ systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.hearthUI(12, weight: .bold))
                .foregroundStyle(isEnabled ? hearth.text : hearth.textTertiary)
                .frame(width: 30, height: 30)
                .background {
                    HearthChromeBackground(
                        shape: .circle,
                        fill: hearth.bg,
                        stroke: hearth.hairline,
                        tint: hearth.bg
                    )
                }
        }
        .disabled(!isEnabled)
        .buttonStyle(PressableStyle())
        .accessibilityLabel(systemImage)
    }
}

private struct LibraryControlPill: View {
    let title: String
    var systemImage: String?
    var isSelected: Bool
    let action: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.hearthUI(12, weight: .semibold))
                }
                Text(title)
                    .font(.hearthUI(14, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(isSelected ? hearth.readableOnEmber : hearth.text)
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, 12)
            .background {
                HearthChromeBackground(
                    shape: .capsule,
                    fill: isSelected ? hearth.ember : hearth.bgElevated,
                    stroke: isSelected ? hearth.ember : hearth.hairline,
                    tint: isSelected ? hearth.ember : hearth.bgElevated
                )
            }
        }
        .buttonStyle(PressableStyle())
    }
}
