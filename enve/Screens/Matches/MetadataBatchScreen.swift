import Combine
import SwiftUI

struct MetadataBatchScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var model = MatchesBatchModel()
    @State private var selectedSourceFilter: LibrarySourceFilter?
    @State private var selectedProvider = SettingsManager.shared.metadataMatchProvider
    @State private var confidenceThreshold = Double(SettingsManager.shared.autoMatchThresholdPercent)
    @State private var isPreparing = false
    @State private var preparedBooks: [Book] = []
    @State private var preparedLibraryName = ""
    @State private var showingRunConfirmation = false
    @State private var matchingError: String?
    private let matchStore = BatchMatchProgressStore.shared

    init(initialSourceFilter: LibrarySourceFilter? = nil) {
        _selectedSourceFilter = State(initialValue: initialSourceFilter)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Overline("Batch tools")
                    Text("Batch metadata")
                        .font(.hearthScreenTitle)
                        .foregroundStyle(hearth.text)
                }
                .padding(.horizontal, 24)

                startCard

                if matchStore.isMatching {
                    matchingCard
                } else if let result = matchStore.lastResult {
                    lastRunCard(result)
                }

                cellularRow

                if model.queue.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The queue is empty.")
                            .font(.hearthDisplay(20, weight: .semibold))
                            .foregroundStyle(hearth.text)
                        Text("Metadata downloads appear here when a batch run starts.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                    }
                    .padding(.horizontal, 24)
                } else {
                    queueSection
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { model.loadQueue() }
        .task {
            await engine.sources.refreshLibrarySourceNamesIfNeeded()
        }
        .onChange(of: selectedSourceFilter) {
            matchingError = nil
        }
        .confirmationDialog(
            "Match metadata for \(preparedLibraryName)?",
            isPresented: $showingRunConfirmation,
            titleVisibility: .visible
        ) {
            Button("Match \(preparedBooks.count) \(preparedBooks.count == 1 ? "audiobook" : "audiobooks")") {
                startMatching()
            }
            Button("Cancel", role: .cancel) {
                preparedBooks = []
            }
        } message: {
            Text(
                "Matches at or above \(Int(confidenceThreshold))% confidence are applied automatically. The rest go to Pending Matches for review."
            )
        }
    }

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Overline("Match a library")

            batchPickerRow(
                title: selectedLibraryName,
                subtitle: "Library",
                systemImage: "books.vertical.fill"
            ) {
                Button {
                    selectedSourceFilter = .all
                } label: {
                    batchPickerLabel("All libraries", selected: selectedSourceFilter == .all)
                }

                Button {
                    selectedSourceFilter = .device
                } label: {
                    batchPickerLabel("This device", selected: selectedSourceFilter == .device)
                }

                ForEach(sourceSnapshot.connections) { connection in
                    let libraries = sourceSnapshot.libraries.filter { $0.providerId == connection.id }
                    Section(connection.name) {
                        let connectionFilter = LibrarySourceFilter.connection(connection.id)
                        Button {
                            selectedSourceFilter = connectionFilter
                        } label: {
                            batchPickerLabel("All in \(connection.name)", selected: selectedSourceFilter == connectionFilter)
                        }

                        if !libraries.isEmpty {
                            ForEach(libraries, id: \.uniqueId) { library in
                                let filter = LibrarySourceFilter.library(
                                    providerId: library.providerId,
                                    libraryId: library.id
                                )
                                Button {
                                    selectedSourceFilter = filter
                                } label: {
                                    batchPickerLabel(
                                        "\(library.name) · \(connection.name)",
                                        selected: selectedSourceFilter == filter
                                    )
                                }
                            }
                        }
                    }
                }
            }

            batchPickerRow(
                title: selectedProvider.displayName,
                subtitle: "Metadata provider",
                systemImage: selectedProvider.icon
            ) {
                ForEach(MetadataProvider.allCases) { provider in
                    Button {
                        selectedProvider = provider
                        SettingsManager.shared.metadataMatchProvider = provider
                    } label: {
                        batchPickerLabel(provider.displayName, selected: selectedProvider == provider)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Auto-match confidence")
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.text)
                    Spacer()
                    Text("\(Int(confidenceThreshold))%")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.ember)
                }
                Slider(value: $confidenceThreshold, in: 70...95, step: 5)
                    .tint(hearth.ember)
                    .onChange(of: confidenceThreshold) { _, value in
                        SettingsManager.shared.autoMatchThresholdPercent = Int(value)
                    }
                Text("Uncertain matches wait for your review instead of changing the book.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }

            if let matchingError {
                Label(matchingError, systemImage: "exclamationmark.triangle.fill")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusError)
            }

            EmberButton(
                title: isPreparing ? "Preparing…" : "Match library",
                systemImage: "wand.and.stars"
            ) {
                prepareMatch()
            }
            .disabled(selectedSourceFilter == nil || isPreparing || matchStore.isMatching)
            .opacity(selectedSourceFilter == nil || isPreparing || matchStore.isMatching ? 0.5 : 1)
        }
        .padding(16)
        .background(dedupCardBackground(hearth))
        .padding(.horizontal, 24)
    }

    private func batchPickerRow<MenuContent: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder menuContent: () -> MenuContent
    ) -> some View {
        Menu(content: menuContent) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.ember)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(subtitle)
                        .font(.hearthUI(11, weight: .medium))
                        .foregroundStyle(hearth.textTertiary)
                    Text(title)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.hearthUI(11, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
            .padding(14)
            .background(hearth.bg.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func batchPickerLabel(_ title: String, selected: Bool) -> Label<Text, Image> {
        Label(title, systemImage: selected ? "checkmark.circle.fill" : "circle")
    }

    private var sourceSnapshot: LibrarySourceSnapshot {
        engine.sources.librarySourceSnapshot
    }

    private var selectedLibraryName: String {
        guard let selectedSourceFilter else { return "Choose a library" }
        switch selectedSourceFilter {
        case .all:
            return "All libraries"
        case let .library(providerId, libraryId):
            let libraryName =
                sourceSnapshot.libraries.first {
                    $0.providerId == providerId && $0.id == libraryId
                }?.name ?? "Library"
            return "\(libraryName) · \(connectionName(providerId))"
        case let .connection(providerId):
            return "All in \(connectionName(providerId))"
        case .device:
            return "This device"
        }
    }

    private func connectionName(_ providerId: UUID) -> String {
        sourceSnapshot.connections.first { $0.id == providerId }?.name ?? "Source"
    }

    private func prepareMatch() {
        guard let selectedSourceFilter else { return }
        matchingError = nil
        isPreparing = true
        Task {
            let books = await engine.library.sourceScopedBooks(
                sourceFilter: selectedSourceFilter,
                mediaTypes: [AppMediaType.audiobook.rawValue]
            )
            isPreparing = false
            guard !books.isEmpty else {
                matchingError = "This library has no audiobooks to match."
                return
            }
            preparedBooks = books
            preparedLibraryName = selectedLibraryName
            showingRunConfirmation = true
        }
    }

    private func startMatching() {
        let books = preparedBooks
        let libraryName = preparedLibraryName
        preparedBooks = []

        matchStore.start(libraryName: libraryName, provider: selectedProvider)
        matchStore.setTotal(books.count)

        let task = BatchMetadataMatcher.shared.batchMatch(
            books: books,
            libraryName: libraryName,
            provider: selectedProvider,
            onProgress: { current, total in
                Task { @MainActor in
                    matchStore.updateProgress(current: current, total: total)
                }
            },
            onComplete: { result in
                Task { @MainActor in
                    matchStore.finish(result: result)
                }
            }
        )
        matchStore.setTask(task)
    }

    private var matchingCard: some View {
        let progress = matchStore.progress
        let current = progress?.current ?? 0
        let total = max(progress?.total ?? 0, 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(hearth.ember)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Matching \(matchStore.lastLibraryName ?? "the library")")
                        .font(.hearthUI(14, weight: .semibold))
                        .foregroundStyle(hearth.text)
                    Text("\(matchStore.currentProvider?.displayName ?? "") · \(current) of \(total)")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
                QuietButton(title: "Stop") {
                    matchStore.stop()
                }
            }
            Ribbon(progress: min(Double(current) / Double(total), 1), tint: hearth.ember)
                .frame(height: 3)
        }
        .padding(16)
        .background(dedupCardBackground(hearth))
        .padding(.horizontal, 24)
    }

    private func lastRunCard(_ result: BatchMatchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Overline("Last run")
            HStack(spacing: 16) {
                matchesRunStat(result.autoMatched, "Matched", hearth.statusOK)
                matchesRunStat(result.pending, "For review", hearth.statusWarn)
                matchesRunStat(result.skipped, "Skipped", hearth.textTertiary)
                matchesRunStat(result.errors, "Errors", result.errors > 0 ? hearth.statusError : hearth.textTertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dedupCardBackground(hearth))
        .padding(.horizontal, 24)
    }

    private func matchesRunStat(_ value: Int, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)")
                .font(.hearthDisplay(22))
                .foregroundStyle(tint)
            Text(label)
                .font(.hearthUI(11))
                .foregroundStyle(hearth.textTertiary)
        }
    }

    private var cellularRow: some View {
        Toggle(isOn: $model.allowCellular) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cellular downloads")
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
                Text(model.allowCellular ? "Allowed" : "Wi-Fi only")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
        .tint(hearth.ember)
        .padding(16)
        .background(dedupCardBackground(hearth))
        .padding(.horizontal, 24)
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Queue")

            if model.totalActive > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.totalActive == 1 ? "1 active download" : "\(model.totalActive) active downloads")
                            .font(.hearthUI(14, weight: .medium))
                            .foregroundStyle(hearth.text)
                        Spacer()
                        Text("\(Int(model.overallProgress * 100))%")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                    Ribbon(progress: model.overallProgress, tint: hearth.ember)
                        .frame(height: 3)
                }
                .padding(.horizontal, 24)
            }

            if let error = model.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.hearthUI(12))
                    Text(error)
                        .font(.hearthCaption)
                    Spacer()
                    Button {
                        model.error = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.hearthUI(11))
                    }
                    .accessibilityLabel("Dismiss error")
                }
                .foregroundStyle(hearth.statusError)
                .padding(.horizontal, 24)
            }

            VStack(spacing: 10) {
                ForEach(model.queue) { item in
                    queueRow(item)
                }
            }
            .padding(.horizontal, 24)

            if model.queue.contains(where: { $0.status == .completed }) {
                QuietButton(title: "Clear completed", systemImage: "trash") {
                    model.clearCompleted()
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func queueRow(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                    matchesStatusBadge(item.status)
                }
                Spacer()
                Menu {
                    if item.status == .downloading {
                        Button {
                            model.pause(item.id)
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                    }
                    if item.status == .paused {
                        Button {
                            model.resume(item.id)
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                    }
                    if item.isActive {
                        Button(role: .destructive) {
                            model.cancel(item.id)
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                    } else {
                        Button(role: .destructive) {
                            model.remove(item.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Download options")
            }

            if item.status == .downloading {
                ProgressView()
                    .tint(hearth.ember)
            }

            if let error = item.errorDescription, !error.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.hearthUI(11))
                    Text(error)
                        .font(.hearthCaption)
                }
                .foregroundStyle(hearth.statusWarn)
            }
        }
        .padding(14)
        .background(dedupCardBackground(hearth))
    }

    private func matchesStatusBadge(_ status: DownloadItem.Status) -> some View {
        let (icon, tint, label): (String, Color, String) =
            switch status {
            case .pending: ("clock", hearth.textTertiary, "Waiting")
            case .downloading: ("arrow.down.circle", hearth.ember, "Downloading")
            case .paused: ("pause.circle", hearth.statusWarn, "Paused")
            case .completed: ("checkmark.circle", hearth.statusOK, "Done")
            case .failed: ("xmark.circle", hearth.statusError, "Failed")
            case .cancelled: ("xmark.circle", hearth.textTertiary, "Cancelled")
            }
        return Label(label, systemImage: icon)
            .font(.hearthUI(11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

@MainActor
@Observable
final class MatchesBatchModel {
    var queue: [DownloadItem] = []
    var error: String?
    var totalActive = 0
    var overallProgress: Double = 0

    var allowCellular: Bool {
        didSet { SettingsManager.shared.allowCellularMetadataDownloads = allowCellular }
    }

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    init() {
        allowCellular = SettingsManager.shared.allowCellularMetadataDownloads
        MetadataBatchDownloader.shared.$queue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                self?.queue = items
                self?.updateStats()
            }
            .store(in: &cancellables)
    }

    func loadQueue() {
        queue = DownloadPersistence.shared.loadMetadataDownloadQueue().items
        updateStats()
    }

    func pause(_ id: String) {
        MetadataBatchDownloader.shared.pauseBatch(id)
    }

    func resume(_ id: String) {
        guard NetworkPolicyService.shared.canDownload(allowCellular: allowCellular) else {
            error = "Can't resume. The network is unavailable or cellular is off."
            return
        }
        MetadataBatchDownloader.shared.resumeBatch(id)
    }

    func cancel(_ id: String) {
        MetadataBatchDownloader.shared.cancelBatch(id)
    }

    func remove(_ id: String) {
        var persisted = DownloadPersistence.shared.loadMetadataDownloadQueue()
        persisted.removeItem(withId: id)
        do {
            try DownloadPersistence.shared.saveMetadataDownloadQueue(persisted)
            queue.removeAll { $0.id == id }
            updateStats()
        } catch {
            self.error = "Couldn't remove the download: \(error.localizedDescription)"
        }
    }

    func clearCompleted() {
        var persisted = DownloadPersistence.shared.loadMetadataDownloadQueue()
        persisted.items.removeAll { $0.status == .completed }
        do {
            try DownloadPersistence.shared.saveMetadataDownloadQueue(persisted)
            queue.removeAll { $0.status == .completed }
            updateStats()
        } catch {
            self.error = "Couldn't clear the finished downloads: \(error.localizedDescription)"
        }
    }

    private func updateStats() {
        totalActive = queue.filter(\.isActive).count
        let total = queue.count
        let completed = queue.filter { $0.status == .completed }.count
        overallProgress = total > 0 ? Double(completed) / Double(total) : 0
    }
}
