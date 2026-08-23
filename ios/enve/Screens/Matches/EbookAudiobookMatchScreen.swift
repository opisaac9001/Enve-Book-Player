import SwiftUI

struct EbookAudiobookMatchScreen: View {
    let book: Book

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var candidates: [Book] = []
    @State private var allCounterparts: [Book] = []
    @State private var hasAutoSearched = false
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var chapterSyncStatus: String?
    @State private var resolvedLinkedEbook: Book?

    private var isAudioSource: Bool { book.mediaType == .audiobook }
    private var sourceEbook: Book? {
        isAudioSource ? (resolvedLinkedEbook ?? EbookAudiobookLinker.shared.linkedEbook(for: book)) : book
    }
    private var linkedAudiobook: Book? {
        isAudioSource ? book : EbookAudiobookLinker.shared.linkedAudiobook(for: book)
    }
    private var linked: Book? { isAudioSource ? sourceEbook : linkedAudiobook }
    private var counterpartMediaType: AppMediaType { isAudioSource ? .ebook : .audiobook }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            CollectionsSearchField(text: $query)
            results
        }
        .padding(.horizontal, 24)
        .hearthPresentationBackground()
        .presentationDragIndicator(.visible)
        .onChange(of: query) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                if Task.isCancelled { return }
                runSearch()
            }
        }
        .task {
            if isAudioSource {
                resolvedLinkedEbook = await EbookAudiobookLinker.shared.linkedEbookAsync(for: book)
            }
            for await fetched in engine.library.observedBooks(mediaType: counterpartMediaType.rawValue) {
                if Task.isCancelled { break }
                allCounterparts = fetched
                if !hasAutoSearched {
                    hasAutoSearched = true
                    autoSearch()
                }
            }
        }
        .task(id: linked?.stableId) {
            await updateChapterSyncStatus()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Overline("One story, two forms")
                    Text(isAudioSource ? "Link the ebook" : "Link the audiobook")
                        .font(.hearthDisplay(24, weight: .semibold))
                        .foregroundStyle(hearth.text)
                }
                Spacer()
                if linked != nil {
                    QuietButton(title: "Unlink") {
                        unlink()
                    }
                }
            }
            .padding(.top, 24)

            HStack(spacing: 12) {
                CoverTile(book: book, width: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                    if let author = book.author {
                        Text(author)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                    if let linked {
                        Label("Linked: \(linked.title)", systemImage: "link")
                            .font(.hearthUI(11, weight: .medium))
                            .foregroundStyle(hearth.statusOK)
                            .lineLimit(1)
                        if let chapterSyncStatus {
                            Text(chapterSyncStatus)
                                .font(.hearthUI(11))
                                .foregroundStyle(hearth.textTertiary)
                                .lineLimit(2)
                        }
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(dedupCardBackground(hearth))

            if let ebook = sourceEbook, let audiobook = linkedAudiobook {
                LinkedBookQuickSyncPanel(ebook: ebook, audiobook: audiobook)
            }
        }
    }

    private var results: some View {
        Group {
            if isSearching && candidates.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(hearth.ember)
                    Text("Listening for a counterpart.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            } else if candidates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(query.isEmpty ? "No matching \(counterpartLabelPlural) found." : "Nothing answers to \u{201C}\(query)\u{201D}.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                    Text("Try the title alone, or the author's name.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(candidates, id: \.stableId) { counterpart in
                            Button {
                                link(to: counterpart)
                            } label: {
                                candidateRow(counterpart)
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var counterpartLabelPlural: String {
        isAudioSource ? "ebooks" : "audiobooks"
    }

    private func candidateRow(_ counterpart: Book) -> some View {
        let isCurrentLink = linked?.stableId == counterpart.stableId
        return HStack(spacing: 12) {
            CoverTile(book: counterpart, width: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(counterpart.title)
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let author = counterpart.author {
                    Text(author)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                if let duration = counterpart.duration, duration > 0 {
                    Text(HearthFormat.duration(duration))
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                }
            }
            Spacer()
            Image(systemName: isCurrentLink ? "checkmark.circle.fill" : "link.badge.plus")
                .font(.hearthUI(18))
                .foregroundStyle(isCurrentLink ? hearth.statusOK : hearth.ember)
        }
        .padding(12)
        .background(dedupCardBackground(hearth))
    }

    private func autoSearch() {
        isSearching = true
        defer { isSearching = false }

        if let asin = book.asin, !asin.isEmpty {
            let matches = allCounterparts.filter { $0.asin == asin }
            if !matches.isEmpty {
                candidates = matches
                return
            }
        }
        if let isbn = book.isbn, !isbn.isEmpty {
            let matches = allCounterparts.filter { $0.isbn == isbn }
            if !matches.isEmpty {
                candidates = matches
                return
            }
        }

        candidates = fuzzySearch(query: book.title, in: allCounterparts)

        if let inferred = linked,
            !candidates.contains(where: { $0.stableId == inferred.stableId })
        {
            candidates.insert(inferred, at: 0)
        }
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            autoSearch()
            return
        }
        candidates = fuzzySearch(query: trimmed, in: allCounterparts)
    }

    private func updateChapterSyncStatus() async {
        if isAudioSource {
            resolvedLinkedEbook = await EbookAudiobookLinker.shared.linkedEbookAsync(for: book)
        }
        guard let ebook = sourceEbook, let audiobook = linkedAudiobook else {
            chapterSyncStatus = nil
            return
        }
        if let calibration = LinkedBookProgressCoordinator.shared.calibrationSummary(
            ebookStableId: ebook.stableId,
            audiobookStableId: audiobook.stableId
        ) {
            chapterSyncStatus = "Quick Sync calibrated · \(calibration.anchorCount) audio landmarks"
            return
        }
        guard let ebookChapters = await EbookChapterSyncService.shared.extractEbookChapters(for: ebook),
            let audiobookChapters = audiobook.chapters,
            !audiobookChapters.isEmpty
        else {
            chapterSyncStatus = "Chapter sync will refine after both formats are downloaded."
            return
        }

        let matches = LinkedBookChapterMapper.matches(
            ebookTitles: ebookChapters.map(\.title),
            audiobookTitles: audiobookChapters.map(\.title)
        )
        let confidence = LinkedBookChapterMapper.mappingConfidence(
            matches: matches,
            ebookCount: ebookChapters.count,
            audiobookCount: audiobookChapters.count
        )
        if matches.count >= 2, confidence >= 0.7 {
            chapterSyncStatus = "High-confidence chapter sync · \(matches.count) matched"
        } else if matches.count >= 2, confidence >= 0.48 {
            chapterSyncStatus = "Chapter sync · \(matches.count) landmarks matched"
        } else {
            chapterSyncStatus = "Approximate chapter sync · Quick Sync can refine this"
        }
    }

    private func fuzzySearch(query: String, in books: [Book]) -> [Book] {
        let tokens = query.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return books }
        return
            books
            .compactMap { candidate -> (Book, Int)? in
                let haystack = "\(candidate.title) \(candidate.author ?? "")".lowercased()
                let score = tokens.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
                return score > 0 ? (candidate, score) : nil
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private func link(to audiobook: Book) {
        Task {
            let didLink: Bool
            if isAudioSource {
                didLink = await engine.library.linkAudiobook(book, to: audiobook)
            } else {
                didLink = await engine.library.linkAudiobook(audiobook, to: book)
            }
            if didLink {
                dismiss()
            }
        }
    }

    private func unlink() {
        guard let ebook = sourceEbook else { return }
        _ = engine.library.unlinkAudiobook(from: ebook)
        dismiss()
    }
}

private struct LinkedBookQuickSyncPanel: View {
    let ebook: Book
    let audiobook: Book

    @Environment(\.hearth) private var hearth
    @State private var showDownloadConfirmation = false
    @State private var calibrationRevision = 0

    private var quickSync: LinkedBookQuickSyncService { .shared }

    private var pairState: LinkedBookQuickSyncService.State? {
        guard let state = quickSync.state,
            state.ebookStableId == ebook.stableId,
            state.audiobookStableId == audiobook.stableId
        else {
            return nil
        }
        return state
    }

    private var calibration: (anchorCount: Int, averageConfidence: Double)? {
        _ = calibrationRevision
        return LinkedBookProgressCoordinator.shared.calibrationSummary(
            ebookStableId: ebook.stableId,
            audiobookStableId: audiobook.stableId
        )
    }

    var body: some View {
        panel
            .alert("Download audiobook for Quick Sync?", isPresented: $showDownloadConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Download & Sync") {
                    quickSync.start(ebook: ebook, audiobook: audiobook)
                }
            } message: {
                Text(
                    "Quick Sync compares short samples across the audiobook. Enve needs a local copy, so the full audiobook will be downloaded first."
                )
            }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            statusView
            actions
        }
        .padding(12)
        .background(dedupCardBackground(hearth))
    }

    private var titleRow: some View {
        HStack {
            Label("Quick Sync", systemImage: "waveform.and.magnifyingglass")
                .font(.hearthUI(14, weight: .semibold))
                .foregroundStyle(hearth.text)
            Spacer()
            if pairState?.error != nil || pairState?.isComplete == true {
                Button {
                    quickSync.dismissResult()
                } label: {
                    Image(systemName: "xmark")
                        .font(.hearthUI(11, weight: .semibold))
                        .foregroundStyle(hearth.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: pairState?.progress ?? 0)
                .tint(hearth.ember)
                .frame(height: pairState == nil ? 0 : nil)
                .opacity(pairState == nil ? 0 : 1)
            Text(statusText)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
    }

    private var statusText: String {
        if let state = pairState {
            if let error = state.error {
                return error
            }
            if state.isComplete {
                switch state.method {
                case .proportional:
                    return "Using approximate progress. You can still switch between formats."
                case .chapterLandmarks:
                    return "\(state.matchedSamples) chapter landmarks saved."
                default:
                    return "\(state.matchedSamples) anchors saved · \(state.method?.displayName ?? "Quick Sync")"
                }
            }
            return "\(state.stage) · \(state.matchedSamples) matches"
        }
        if let calibration {
            return "\(calibration.anchorCount) calibrated anchors · \(Int(calibration.averageConfidence * 100))% average confidence"
        }
        if #available(iOS 26.0, *) {
            return
                "Uses Apple on-device transcription when available, then falls back to audio and chapter matching. No StoryAlign ID or model download is needed."
        }
        return "Uses on-device audio and chapter matching without speech-to-text. No StoryAlign ID or model download is needed."
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if quickSync.isRunning(ebook: ebook, audiobook: audiobook) {
                QuietButton(title: "Cancel") {
                    quickSync.cancel()
                }
            } else {
                QuietButton(title: calibration == nil ? "Set Up Quick Sync" : "Recalibrate") {
                    if quickSync.needsAudiobookDownload(audiobook) {
                        showDownloadConfirmation = true
                    } else {
                        quickSync.start(ebook: ebook, audiobook: audiobook)
                    }
                }
            }
            if calibration != nil, !quickSync.isRunning(ebook: ebook, audiobook: audiobook) {
                Button("Remove") {
                    LinkedBookProgressCoordinator.shared.removeCalibration(
                        ebookStableId: ebook.stableId,
                        audiobookStableId: audiobook.stableId
                    )
                    calibrationRevision += 1
                }
                .font(.hearthUI(12, weight: .medium))
                .foregroundStyle(hearth.textTertiary)
                .buttonStyle(.plain)
            }
        }
    }
}
