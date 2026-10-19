import SwiftUI

struct ComicSeriesScreen: View {
    let aggregate: BrowseSeriesAggregate
    let filter: ComicSeriesFilter

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: ComicSeriesModel
    @State private var detailBookId: String?

    init(aggregate: BrowseSeriesAggregate, mediaScope: [String], filter: ComicSeriesFilter, library: LibraryEngine) {
        self.aggregate = aggregate
        self.filter = filter
        _model = State(initialValue: ComicSeriesModel(aggregate: aggregate, mediaScope: mediaScope, filter: filter, library: library))
    }

    var body: some View {
        GeometryReader { geo in
            let contentWidth = HearthAdaptive.contentWidth(for: geo.size.width, maximum: HearthAdaptive.wideReadableWidth)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    header
                    if let book = model.continueBook {
                        continueAction(book)
                    }
                    if model.sections.count > 1 {
                        sectionPicker
                    }
                    if model.hasLoaded {
                        sectionContent(model.selectedSection ?? .issues, width: contentWidth)
                    }
                    footer
                }
                .hearthReadableFrame(width: geo.size.width, maximum: HearthAdaptive.wideReadableWidth)
                .padding(.top, 8)
                .padding(.bottom, mantelInset + 16)
            }
            .scrollIndicators(.hidden)
            .refreshable { await model.refresh() }
        }
        .background(HearthBackground())
        .toolbarBackground(.hidden, for: .navigationBar)
        .hearthBackBar()
        .navigationDestination(item: $detailBookId) { id in
            if let book = model.book(uniqueId: id) {
                BookDetailScreen(book: book)
            }
        }
        .task {
            if model.hasLoaded {
                model.scheduleRefresh()
            } else {
                await model.loadInitial()
            }
            for await _ in engine.library.libraryChanges() {
                model.scheduleRefresh()
            }
        }
        .task {
            for await _ in AppRefreshEvents.stream(
                names: [UnifiedDownloadService.downloadCompletedNotification],
                debounce: .milliseconds(150)
            ) {
                await model.refreshOffline()
            }
        }
        .onChange(of: aggregate) { _, newValue in
            model.update(aggregate: newValue)
        }
        .onChange(of: filter) { _, newValue in
            model.update(filter: newValue)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Overline(model.aggregate.standaloneBookUniqueID == nil ? "Series" : "Comic")
            Text(model.aggregate.name)
                .font(.hearthDisplay(28))
                .foregroundStyle(hearth.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(ComicSeriesFormat.summary(total: model.totalCount, unread: model.unreadCount))
                .font(.hearthCaption.monospacedDigit())
                .foregroundStyle(hearth.textSecondary)
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }

    private func continueAction(_ book: Book) -> some View {
        let title: String
        if book.isCompleted {
            title = "Read again"
        } else if book.canonicalEbookProgress > 0.001 {
            title = "Continue reading"
        } else {
            title = "Read next"
        }
        let issue = [book.comicMetadata?.issueLabel, LibraryDisplayFormatter.displayTitle(book.title)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 8) {
            EmberButton(title: title, systemImage: "book") {
                PlatformHaptics.impact(.medium)
                engine.playback.play(book)
            }
            .accessibilityHint(issue)
            Text(issue)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .lineLimit(2)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 24)
    }

    private var sectionPicker: some View {
        let selected = model.selectedSection
        return ScrollView(.horizontal) {
            HStack(spacing: 24) {
                ForEach(model.sections, id: \.section) { group in
                    Button {
                        PlatformHaptics.selection()
                        model.selectSection(group.section)
                    } label: {
                        VStack(spacing: 5) {
                            Overline(group.section.title, color: selected == group.section ? hearth.ember : nil)
                            Capsule()
                                .fill(selected == group.section ? hearth.ember : .clear)
                                .frame(width: 22, height: 2)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("\(group.section.title), \(ComicSeriesFormat.issueCount(group.count))")
                    .accessibilityAddTraits(selected == group.section ? .isSelected : [])
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func sectionContent(_ section: ComicSection, width: CGFloat) -> some View {
        if let volume = model.directVolume(in: section) {
            issueGrid(model.books(in: volume), width: width)
            pagingRow(volume.slice)
        } else {
            if let slice = model.looseSlice(in: section) {
                issueGrid(model.looseBooks(in: section), width: width)
                pagingRow(slice)
            }
            ForEach(model.volumeSummaries(in: section)) { volume in
                let isExpanded = model.expandedVolumeIds.contains(volume.id)
                ComicVolumeHeader(title: volume.displayTitle, count: volume.count, isExpanded: isExpanded) {
                    PlatformHaptics.selection()
                    if reduceMotion {
                        model.toggleVolume(volume.id)
                    } else {
                        withAnimation(.smooth(duration: 0.25)) { model.toggleVolume(volume.id) }
                    }
                }
                .padding(.horizontal, 24)
                if isExpanded {
                    issueGrid(model.books(in: volume), width: width)
                    pagingRow(volume.slice)
                }
            }
        }
    }

    @ViewBuilder
    private func pagingRow(_ slice: ComicSeriesSlice) -> some View {
        switch model.state(of: slice) {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                    .tint(hearth.ember)
                Text(model.hasFetched(slice) ? "Loading more issues…" : "Loading issues…")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        case .failed:
            VStack(spacing: 12) {
                Text(model.hasFetched(slice) ? "More issues couldn't be loaded." : "These issues couldn't be loaded.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                    .multilineTextAlignment(.center)
                QuietButton(title: "Try again", systemImage: "arrow.clockwise") {
                    Task { await model.loadNextPage(slice) }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        case .idle:
            if model.hasMore(slice) {
                QuietButton(title: "Load more issues", systemImage: "arrow.down.circle") {
                    Task { await model.loadNextPage(slice) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .onAppear {
                    Task { await model.loadNextPage(slice) }
                }
            }
        }
    }

    private func issueGrid(_ books: [Book], width: CGFloat) -> some View {
        let spec = gridSpec(width: width)
        return LazyVGrid(columns: spec.columns, alignment: .leading, spacing: 18) {
            ForEach(books, id: \.uniqueId) { book in
                ComicIssueTile(
                    book: book,
                    width: spec.cellWidth,
                    isRow: spec.isRow,
                    isOffline: model.offlineIds.contains(book.uniqueId),
                    onRead: {
                        PlatformHaptics.impact(.light)
                        engine.playback.play(book)
                    },
                    onDetails: { detailBookId = book.uniqueId }
                )
            }
        }
        .padding(.horizontal, spec.padding)
    }

    private func gridSpec(width: CGFloat) -> (columns: [GridItem], cellWidth: CGFloat, padding: CGFloat, isRow: Bool) {
        let padding = HearthAdaptive.horizontalPadding(for: width)
        if dynamicTypeSize.isAccessibilitySize {
            return ([GridItem(.flexible(), alignment: .leading)], 72, padding, true)
        }
        let spacing: CGFloat = HearthAdaptive.isWide(width) ? 18 : 12
        let minimum: CGFloat = HearthAdaptive.isWide(width) ? 132 : 100
        let available = max(width - padding * 2, minimum)
        let count = max(Int((available + spacing) / (minimum + spacing)), 2)
        let cellWidth = (available - CGFloat(count - 1) * spacing) / CGFloat(count)
        return (Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: count), cellWidth, padding, false)
    }

    @ViewBuilder
    private var footer: some View {
        if !model.hasLoaded {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(hearth.ember)
                Text("Gathering issues…")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if model.showsEmptyState {
            Text("No issues match this view.")
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 56)
        }
    }
}

private extension ComicVolumeSummary {
    var displayTitle: String {
        ComicSeriesVolume(id: id, title: title, order: order, books: []).displayTitle
    }
}

private struct ComicVolumeHeader: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    let toggle: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.hearthDisplay(17, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .multilineTextAlignment(.leading)
                    Text(ComicSeriesFormat.issueCount(count))
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides these issues" : "Shows these issues")
    }
}

private struct ComicIssueTile: View {
    let book: Book
    let width: CGFloat
    let isRow: Bool
    let isOffline: Bool
    let onRead: () -> Void
    let onDetails: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button(action: onRead) {
            if isRow {
                HStack(alignment: .top, spacing: 14) {
                    cover
                    text
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    cover
                    text
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button(action: onRead) {
                Label("Read", systemImage: "book")
            }
            Button(action: onDetails) {
                Label("Details", systemImage: "info.circle")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the reader")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Details", onDetails)
    }

    private var cover: some View {
        let height = width * 1.5
        return CoverTile(book: book, width: min(width, height / book.hearthCoverRatio), showsProgress: true)
            .frame(width: width, height: height, alignment: .bottom)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label = book.comicMetadata?.issueLabel, !label.isEmpty {
                Text(label)
                    .font(.hearthUI(11, weight: .semibold))
                    .foregroundStyle(hearth.ember)
                    .lineLimit(1)
            }
            Text(LibraryDisplayFormatter.displayTitle(book.title))
                .font(.hearthDisplay(13, weight: .semibold))
                .foregroundStyle(hearth.text)
                .lineLimit(isRow ? nil : 2)
                .multilineTextAlignment(.leading)
            if isOffline {
                Label("Offline", systemImage: "checkmark.circle.fill")
                    .font(.hearthUI(10, weight: .semibold))
                    .foregroundStyle(hearth.statusOK)
            }
        }
    }

    private var progressText: String {
        if book.isCompleted { return "Read" }
        let progress = book.canonicalEbookProgress
        return progress > 0.001 ? "\(Int((progress * 100).rounded())) percent read" : "Unread"
    }

    private var accessibilityText: String {
        [
            book.comicMetadata?.issueLabel,
            LibraryDisplayFormatter.displayTitle(book.title),
            progressText,
            isOffline ? "Available offline" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}
