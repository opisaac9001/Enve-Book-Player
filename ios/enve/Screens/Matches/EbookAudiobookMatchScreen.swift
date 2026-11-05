import SwiftUI

struct EbookAudiobookMatchScreen: View {
    let book: Book

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.profileSession) private var capturedSession

    @State private var query = ""
    @State private var candidates: [Book] = []
    @State private var allCounterparts: [Book] = []
    @State private var hasAutoSearched = false
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var chapterSyncStatus: String?
    @State private var resolvedLinkedEbook: Book?

    private var isAudioSource: Bool { book.mediaType == .audiobook }
    private var profile: ProfileSession { capturedSession ?? .owner }
    private var pair: (ebook: Book?, audiobook: Book?) {
        Self.pair(of: book, resolvedEbook: resolvedLinkedEbook, linker: profile.ebookLinker)
    }
    private var sourceEbook: Book? { pair.ebook }
    private var linkedAudiobook: Book? { pair.audiobook }
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
                let profile = profile
                let resolved = await profile.ebookLinker.linkedEbookAsync(for: book)
                if !profile.isRetired { resolvedLinkedEbook = resolved }
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
                if LinkedBookQuickSyncService.isAvailable(for: profile) {
                    LinkedBookQuickSyncPanel(ebook: ebook, audiobook: audiobook, profile: profile)
                }
                PassagePreparationPanel(ebook: ebook, audiobook: audiobook)
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
        // Captured before any await; another profile never sees the owner's Quick Sync calibration.
        let profile = profile
        let calibrations = profile.isOwner ? LinkedBookProgressCoordinator.shared : profile.linkedProgress
        if isAudioSource {
            let resolved = await profile.ebookLinker.linkedEbookAsync(for: book)
            guard !profile.isRetired else { return }
            resolvedLinkedEbook = resolved
        }
        guard let ebook = sourceEbook, let audiobook = linkedAudiobook else {
            chapterSyncStatus = nil
            return
        }
        if let calibration = calibrations.calibrationSummary(
            ebookStableId: ebook.stableId,
            audiobookStableId: audiobook.stableId
        ) {
            chapterSyncStatus = "Quick Sync calibrated · \(calibration.anchorCount) audio landmarks"
            return
        }
        let extracted = await EbookChapterSyncService.shared.extractEbookChapters(for: ebook)
        guard !profile.isRetired else { return }
        guard let ebookChapters = extracted,
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

    /// The other half of `book`'s pair, from the presenting profile's own library only.
    static func pair(of book: Book, resolvedEbook: Book?, linker: EbookAudiobookLinker) -> (ebook: Book?, audiobook: Book?) {
        book.mediaType == .audiobook
            ? (resolvedEbook ?? linker.linkedEbook(for: book), book)
            : (book, linker.linkedAudiobook(for: book))
    }

    private func unlink() {
        guard let ebook = sourceEbook else { return }
        _ = engine.library.unlinkAudiobook(from: ebook)
        dismiss()
    }
}

struct LinkedBookQuickSyncSheet: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    let ebook: Book
    let audiobook: Book
    let profile: ProfileSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Overline("One story, two forms")
                        Text("Quick Sync")
                            .font(.hearthDisplay(24, weight: .semibold))
                            .foregroundStyle(hearth.text)
                    }
                    Spacer()
                    QuietButton(title: "Done") { dismiss() }
                }
                .padding(.top, 24)

                VStack(alignment: .leading, spacing: 6) {
                    Label(ebook.title, systemImage: "book")
                    Label(audiobook.title, systemImage: "headphones")
                }
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(hearth.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(dedupCardBackground(hearth))

                if LinkedBookQuickSyncService.isAvailable(for: profile) {
                    LinkedBookQuickSyncPanel(ebook: ebook, audiobook: audiobook, profile: profile)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .hearthPresentationBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Sentence-level preparation for read along and precise switching, kept separate from approximate Quick Sync.
private struct PassagePreparationPanel: View {
    let ebook: Book
    let audiobook: Book

    @Environment(\.hearth) private var hearth
    @Environment(\.profileSession) private var capturedSession

    private var passages: PassageAlignmentService { (capturedSession ?? .owner).passageAlignment }
    private var status: PassagePairStatus { passages.status(ebook: ebook, audiobook: audiobook) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Read along", systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(.hearthUI(14, weight: .semibold))
                .foregroundStyle(hearth.text)
            if status.totalSeconds > 0 {
                ProgressView(value: min(1, status.coveredSeconds / status.totalSeconds))
                    .tint(hearth.ember)
                    .accessibilityLabel("Prepared narration")
                    .accessibilityValue("\(Int(min(1, status.coveredSeconds / status.totalSeconds) * 100)) percent")
            }
            Text(statusText)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .success = passages.capability(ebook: ebook, audiobook: audiobook), status.activity != .preparing {
                QuietButton(title: "Prepare whole book", systemImage: "square.and.arrow.down.on.square") {
                    passages.prepareWholeBook(ebook: ebook, audiobook: audiobook)
                }
                .accessibilityHint("Prepares every passage on this device. Keep Enve open; preparation pauses in the background unless the system allows it to continue.")
            }
        }
        .padding(12)
        .background(dedupCardBackground(hearth))
    }

    private var statusText: String {
        switch status.activity {
        case .preparing:
            return "Preparing passages · \(Int(status.coveredSeconds / 60)) of \(Int(status.totalSeconds / 60)) minutes"
        case .identifying:
            return "Checking the downloaded files"
        case .loadingEngine:
            return "Loading the alignment engine and book text"
        case .paused(let reason):
            return reason.message
        case .idle:
            if status.coveredSeconds > 0 {
                return "\(Int(status.coveredSeconds / 60)) of \(Int(status.totalSeconds / 60)) minutes prepared. Passages also prepare while you read along."
            }
            switch passages.capability(ebook: ebook, audiobook: audiobook) {
            case .success(let engine):
                return "Passages prepare as you read along or switch formats, using \(engine.title) on this device."
            case .failure(let reason):
                return reason.message
            }
        }
    }
}

private struct LinkedBookQuickSyncPanel: View {
    let ebook: Book
    let audiobook: Book
    let profile: ProfileSession

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

    private var calibration: LinkedBookProgressCoordinator.CalibrationSummary? {
        _ = calibrationRevision
        return profile.linkedProgress.calibrationSummary(
            ebookStableId: ebook.stableId,
            audiobookStableId: audiobook.stableId
        )
    }

    var body: some View {
        panel
            .alert("Download audiobook for Quick Sync?", isPresented: $showDownloadConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Download & Sync") {
                    quickSync.start(ebook: ebook, audiobook: audiobook, profile: profile)
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
                if let keptPreviousReason = state.keptPreviousReason {
                    return "Kept the existing calibration because \(keptPreviousReason)."
                }
                switch state.method {
                case .proportional:
                    return "Using approximate progress. You can still switch between formats."
                case .chapterLandmarks:
                    return "\(state.acceptedAnchors) chapter landmarks saved."
                default:
                    let checked = state.sampleCount > 0 ? " · \(state.matchedSamples) of \(state.checkedSamples) points matched" : ""
                    return "\(state.acceptedAnchors) anchors saved\(checked) · \(state.method?.displayName ?? "Quick Sync")"
                }
            }
            guard state.sampleCount > 0 else { return state.stage }
            let remaining = state.sampleCount - state.checkedSamples
            let counts = "\(state.matchedSamples) matched · \(state.unmatchedSamples) unmatched · \(remaining) left"
            return state.isProvisional ? "\(state.stage)\n\(counts) · using what is matched so far" : "\(state.stage)\n\(counts)"
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
                    if quickSync.needsAudiobookDownload(audiobook, profile: profile) {
                        showDownloadConfirmation = true
                    } else {
                        quickSync.start(ebook: ebook, audiobook: audiobook, profile: profile)
                    }
                }
            }
            if let calibration, !quickSync.isRunning(ebook: ebook, audiobook: audiobook) {
                if calibration.hasPreviousVersion {
                    QuietButton(title: "Restore Previous") {
                        profile.linkedProgress.restorePreviousCalibration(
                            ebookStableId: ebook.stableId,
                            audiobookStableId: audiobook.stableId
                        )
                        quickSync.dismissResult()
                        calibrationRevision += 1
                    }
                }
                Button("Remove") {
                    profile.linkedProgress.removeCalibration(
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
