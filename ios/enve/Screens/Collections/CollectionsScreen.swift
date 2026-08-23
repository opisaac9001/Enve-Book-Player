import Combine
import SwiftUI
import UIKit

private struct CollectionsRefreshControl: UIViewRepresentable {
    let action: @MainActor () async -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.hierarchyDidChange = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.attach(to: view)
        }
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        context.coordinator.action = action
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.attach(to: view)
        }
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AnchorView: UIView {
        var hierarchyDidChange: (() -> Void)?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            hierarchyDidChange?()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            hierarchyDidChange?()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor () async -> Void
        private weak var scrollView: UIScrollView?
        private lazy var refreshControl: UIRefreshControl = {
            let control = UIRefreshControl()
            control.addTarget(self, action: #selector(refresh), for: .valueChanged)
            return control
        }()

        init(action: @escaping @MainActor () async -> Void) {
            self.action = action
        }

        func attach(to anchor: UIView) {
            var ancestor = anchor.superview
            while let view = ancestor, !(view is UIScrollView) {
                ancestor = view.superview
            }
            guard let scrollView = ancestor as? UIScrollView else { return }
            guard scrollView.refreshControl !== refreshControl else { return }
            scrollView.refreshControl = refreshControl
            scrollView.alwaysBounceVertical = true
            self.scrollView = scrollView
        }

        func detach() {
            if scrollView?.refreshControl === refreshControl {
                scrollView?.refreshControl = nil
            }
        }

        @objc private func refresh() {
            Task {
                await action()
                refreshControl.endRefreshing()
            }
        }
    }
}

struct CollectionsScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var smart: [SmartCollection] = []
    @State private var mine: [Collection] = []
    @State private var server: [Collection] = []
    @State private var smartPreviews: [String: (count: Int, book: Book?)] = [:]
    @State private var memberPreviews: [String: Book] = [:]
    @State private var newSmartShown = false
    @State private var newManualShown = false
    @State private var bookOrbitEditorShown = false
    @State private var bookOrbitCollectionToEdit: Collection?
    @State private var bookOrbitAdminConnections: [ServerConnection] = []
    @State private var collectionError: String?
    @State private var loaded = false
    @State private var previewLoadGeneration = 0
    @State private var isRefreshing = false

    var body: some View {
        GeometryReader { geo in
            let contentWidth = HearthAdaptive.contentWidth(for: geo.size.width, maximum: HearthAdaptive.wideReadableWidth)
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 6) {
                        Overline("Shelves of your own")
                        Text("Collections")
                            .font(.hearthScreenTitle)
                            .foregroundStyle(hearth.text)
                    }
                    .padding(.horizontal, 24)

                    if isRefreshing {
                        refreshStatus
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if !loaded {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(hearth.ember)
                            Text("Arranging the shelves.")
                                .font(.hearthBody)
                                .foregroundStyle(hearth.textSecondary)
                        }
                        .padding(.horizontal, 24)
                    } else if smart.isEmpty && mine.isEmpty && server.isEmpty {
                        emptyInvitation
                    }

                    if !smart.isEmpty {
                        smartSection(width: contentWidth)
                    }
                    if loaded {
                        mySection(width: contentWidth)
                    }
                    if !server.isEmpty || !bookOrbitAdminConnections.isEmpty {
                        serverSection(width: contentWidth)
                    }
                }
                .hearthReadableFrame(width: geo.size.width, maximum: HearthAdaptive.wideReadableWidth)
                .padding(.top, 8)
                .padding(.bottom, mantelInset + 16)
                .background {
                    CollectionsRefreshControl {
                        await refreshCollections()
                    }
                    .frame(width: 0, height: 0)
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always)
        }
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await collectionsLoadPreviews()
            for await _ in AppRefreshEvents.stream(
                names: [.collectionsDidChange, .libraryDidFinishSync, .bookStoreDidChange],
                debounce: .milliseconds(150)
            ) {
                await collectionsLoadPreviews()
            }
        }
        .onChange(of: newSmartShown) { _, shown in
            if !shown { Task { await collectionsLoadPreviews() } }
        }
        .onChange(of: newManualShown) { _, shown in
            if !shown { Task { await collectionsLoadPreviews() } }
        }
        .sheet(isPresented: $newSmartShown) {
            CollectionsEditorSheet(isSmart: true)
                .enveEnvironment()
        }
        .sheet(isPresented: $newManualShown) {
            CollectionsEditorSheet()
                .enveEnvironment()
        }
        .sheet(isPresented: $bookOrbitEditorShown) {
            BookOrbitCollectionEditor(
                collection: bookOrbitCollectionToEdit,
                connections: bookOrbitAdminConnections,
                onSaved: { Task { await collectionsLoadPreviews() } }
            )
            .enveEnvironment()
        }
        .alert(
            "BookOrbit collections",
            isPresented: Binding(
                get: { collectionError != nil },
                set: { if !$0 { collectionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(collectionError ?? "")
        }
        .animation(.easeInOut(duration: 0.2), value: isRefreshing)
    }

    private func smartSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Smart shelves", actionTitle: "New rule") {
                newSmartShown = true
            }
            LazyVGrid(columns: HearthAdaptive.gridColumns(width: width, minimum: 220, maximum: 4, compactFallback: 2), spacing: 14) {
                ForEach(smart) { collection in
                    NavigationLink {
                        CollectionsSmartDetailScreen(collection: collection)
                    } label: {
                        CollectionsCard(
                            name: collection.name,
                            count: smartPreviews[collection.id]?.count ?? 0,
                            iconName: collection.iconName,
                            colorName: collection.color,
                            customCoverPath: collection.customCoverPath,
                            previewBook: smartPreviews[collection.id]?.book,
                            badge: collection.isSystem ? nil : "by rule"
                        )
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func mySection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Your shelves", actionTitle: "New shelf") {
                newManualShown = true
            }
            if mine.isEmpty {
                Text("Build a shelf by hand. Add books from their pages.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .padding(.horizontal, 24)
            } else {
                LazyVGrid(columns: HearthAdaptive.gridColumns(width: width, minimum: 220, maximum: 4, compactFallback: 2), spacing: 14) {
                    ForEach(mine) { collection in
                        NavigationLink {
                            CollectionDetailScreen(collection: collection)
                        } label: {
                            memberCard(collection)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func serverSection(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if bookOrbitAdminConnections.isEmpty {
                ShelfHeader(title: "From your servers")
            } else {
                ShelfHeader(title: "From your servers", actionTitle: "New BookOrbit") {
                    bookOrbitCollectionToEdit = nil
                    bookOrbitEditorShown = true
                }
            }
            LazyVGrid(columns: HearthAdaptive.gridColumns(width: width, minimum: 220, maximum: 4, compactFallback: 2), spacing: 14) {
                ForEach(server, id: \.scopedID) { collection in
                    NavigationLink {
                        CollectionDetailScreen(collection: collection)
                    } label: {
                        memberCard(collection)
                    }
                    .buttonStyle(PressableStyle())
                    .contextMenu {
                        if collection.isServerEditable {
                            Button {
                                bookOrbitCollectionToEdit = collection
                                bookOrbitEditorShown = true
                            } label: {
                                Label("Edit collection", systemImage: "pencil")
                            }
                            Button {
                                moveBookOrbitCollection(collection, offset: -1)
                            } label: {
                                Label("Move earlier", systemImage: "arrow.up")
                            }
                            Button {
                                moveBookOrbitCollection(collection, offset: 1)
                            } label: {
                                Label("Move later", systemImage: "arrow.down")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func memberCard(_ collection: Collection) -> some View {
        CollectionsCard(
            name: collection.name,
            count: max(collection.bookCount, collection.books.count),
            iconName: collection.iconName,
            colorName: collection.color,
            customCoverPath: collection.customCoverPath,
            previewBook: memberPreviews[collection.scopedID],
            representativeThumb: collection.representativeThumbs.first
        )
    }

    private var emptyInvitation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nothing gathered yet.")
                .font(.hearthDisplay(22, weight: .semibold))
                .foregroundStyle(hearth.text)
            Text("A collection gathers books by rule or by hand. A smart shelf fills itself, and yours holds what you place there.")
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                QuietButton(title: "New smart shelf", systemImage: "wand.and.stars") {
                    newSmartShown = true
                }
                QuietButton(title: "New shelf", systemImage: "plus") {
                    newManualShown = true
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    private var refreshStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(hearth.ember)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Refreshing your shelves")
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.text)
                    Text("Fetching shelves and collections from your connected servers.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background {
            HearthChromeBackground(
                shape: .rounded(Hearth.radiusCard),
                fill: hearth.bgElevated,
                stroke: hearth.hairline,
                tint: hearth.ember,
                interactive: false
            )
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }

    private func refreshCollections() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let minimumDisplay: Void = Task.sleep(for: .milliseconds(750))
        await engine.sources.refreshServerCollections()
        await collectionsLoadPreviews()
        try? await minimumDisplay
    }

    private func collectionsLoadPreviews() async {
        previewLoadGeneration += 1
        let generation = previewLoadGeneration
        async let overview = engine.library.collectionsOverview()
        async let adminConnections = engine.library.bookOrbitAdminConnections()
        let (resolvedOverview, resolvedAdminConnections) = await (overview, adminConnections)
        guard generation == previewLoadGeneration else { return }

        smart = resolvedOverview.smart
        mine = resolvedOverview.mine
        server = resolvedOverview.server
        smartPreviews = resolvedOverview.smartPreviews
        memberPreviews = resolvedOverview.memberPreviews
        bookOrbitAdminConnections = resolvedAdminConnections
        loaded = true
    }

    private func moveBookOrbitCollection(_ collection: Collection, offset: Int) {
        guard let providerId = collection.providerId else { return }
        var ordered =
            server
            .filter { $0.providerId == providerId && $0.remoteId != nil }
            .sorted { $0.displayOrder < $1.displayOrder }
        guard let index = ordered.firstIndex(where: { $0.id == collection.id }) else { return }
        let destination = index + offset
        guard ordered.indices.contains(destination) else { return }
        ordered.swapAt(index, destination)
        Task {
            do {
                try await engine.library.reorderBookOrbitCollections(ordered)
                await collectionsLoadPreviews()
            } catch {
                collectionError = error.localizedDescription
            }
        }
    }
}
