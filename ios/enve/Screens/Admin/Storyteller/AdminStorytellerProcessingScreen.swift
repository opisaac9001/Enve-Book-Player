import SwiftUI

private enum StorytellerProcessIntent: Identifiable {
    case restart(StorytellerProcessingBook, StorytellerAlignmentRestartMode)
    case cancel(StorytellerProcessingBook)

    var id: String {
        switch self {
        case .restart(let book, let mode): return "\(book.id)-\(mode.rawValue)"
        case .cancel(let book): return "\(book.id)-cancel"
        }
    }

    var book: StorytellerProcessingBook {
        switch self {
        case .restart(let book, _), .cancel(let book): return book
        }
    }

    var title: String {
        switch self {
        case .restart(_, .sync): return "Restart synchronization?"
        case .restart(_, .transcription): return "Restart transcription?"
        case .restart(_, .full): return "Restart from scratch?"
        case .restart: return "Start alignment?"
        case .cancel: return "Cancel alignment?"
        }
    }

    var message: String {
        switch self {
        case .restart(let book, .sync):
            return "Storyteller will keep existing files and synchronize “\(book.title)” again."
        case .restart(let book, .transcription):
            return "Storyteller will discard its transcriptions for “\(book.title)” and rebuild them."
        case .restart(let book, .full):
            return "Storyteller will delete all cached alignment work for “\(book.title)” and start over."
        case .restart(let book, .continueExisting):
            return "Storyteller will continue processing “\(book.title)”."
        case .cancel(let book):
            return "Storyteller will stop its current work on “\(book.title)”."
        }
    }

    var confirmTitle: String {
        switch self {
        case .cancel: return "Cancel alignment"
        case .restart: return "Restart"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .cancel, .restart(_, .full), .restart(_, .transcription): return true
        case .restart: return false
        }
    }
}

struct AdminStorytellerProcessingScreen: View {
    let model: AdminStorytellerModel

    @Environment(\.hearth) private var hearth
    @State private var search = ""
    @State private var pendingIntent: StorytellerProcessIntent?

    private var filteredBooks: [StorytellerProcessingBook] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.processingBooks }
        return model.processingBooks.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || ($0.author?.localizedCaseInsensitiveContains(needle) == true)
        }
    }

    private var activeProcessingKey: String {
        model.processingBooks
            .filter(\.isProcessing)
            .map(\.id)
            .sorted()
            .joined(separator: ",")
    }

    var body: some View {
        AdminSubScreen(overline: "Storyteller", title: "Alignment quality") {
            if let facets = model.alignmentFacets { facetsCard(facets) }
            searchField

            if filteredBooks.isEmpty {
                SourcesCard {
                    AdminEmptyText(
                        search.isEmpty
                            ? "No books have both an ebook and audiobook ready for alignment."
                            : "No alignable books match this search."
                    )
                }
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(filteredBooks) { book in
                        processingCard(book)
                    }
                }
            }
        }
        .alert(
            pendingIntent?.title ?? "Storyteller",
            isPresented: Binding(
                get: { pendingIntent != nil },
                set: { if !$0 { pendingIntent = nil } }
            ),
            presenting: pendingIntent
        ) { intent in
            Button(intent.confirmTitle, role: intent.isDestructive ? .destructive : nil) {
                run(intent)
            }
            Button("Keep current work", role: .cancel) { pendingIntent = nil }
        } message: { intent in
            Text(intent.message)
        }
        .adminMessageAlert(
            error: Binding(get: { model.error }, set: { model.error = $0 }),
            success: Binding(get: { model.successMessage }, set: { model.successMessage = $0 })
        )
        .task(id: activeProcessingKey) {
            guard !activeProcessingKey.isEmpty else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                await model.refreshProcessing()
            }
        }
    }

    private func facetsCard(_ facets: StorytellerAlignmentFacets) -> some View {
        SourcesCard {
            HStack {
                Overline("Library quality")
                Spacer()
                if !activeProcessingKey.isEmpty {
                    AdminTag(
                        text: model.isRefreshingProcessing ? "Updating" : "Live",
                        color: hearth.ember
                    )
                }
            }
            HStack(alignment: .top) {
                AdminStat(value: facets.total.formatted(), label: "Reports")
                AdminStat(value: facets.muted.formatted(), label: "Muted")
                AdminStat(value: "\(model.processingBooks.count(where: \.isProcessing))", label: "Running")
            }
            if !facets.grades.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
                    ForEach(sortedGrades(facets), id: \.key) { grade in
                        VStack(spacing: 3) {
                            Text(grade.key)
                                .font(.hearthDisplay(20))
                                .foregroundStyle(gradeColor(grade.key))
                            Text(grade.value.formatted())
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(hearth.bg, in: RoundedRectangle(cornerRadius: Hearth.radiusInner))
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.hearthUI(14))
                .foregroundStyle(hearth.textTertiary)
            TextField("Search alignable books", text: $search)
                .font(.hearthUI(15))
                .foregroundStyle(hearth.text)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
        }
    }

    private func processingCard(_ book: StorytellerProcessingBook) -> some View {
        SourcesCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: book.isProcessing ? "waveform" : "book.closed")
                    .font(.hearthUI(16, weight: .medium))
                    .foregroundStyle(book.isProcessing ? hearth.ember : hearth.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(book.isProcessing ? hearth.emberSoft : hearth.bg, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                    if let author = book.author {
                        Text(author)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if model.processingBookId == book.id {
                    ProgressView().tint(hearth.ember)
                } else {
                    AdminTag(text: book.statusLabel, color: statusColor(book))
                }
            }

            if let progress = book.stageProgress, book.isProcessing {
                AdminProgressLine(fraction: progress)
            }

            HStack(spacing: 10) {
                NavigationLink {
                    AdminStorytellerAlignmentReportScreen(connection: model.connection, book: book)
                } label: {
                    Label("Report", systemImage: "doc.text.magnifyingglass")
                        .font(.hearthUI(13, weight: .medium))
                        .foregroundStyle(hearth.text)
                        .frame(minHeight: 38)
                }
                .buttonStyle(PressableStyle())

                Spacer()

                if book.isProcessing {
                    Button("Cancel", role: .destructive) {
                        pendingIntent = .cancel(book)
                    }
                    .font(.hearthUI(13, weight: .medium))
                    .foregroundStyle(hearth.statusError)
                    .disabled(model.processingBookId != nil)
                } else {
                    Menu {
                        Button("Continue", systemImage: "play.fill") {
                            Task { await model.startAlignment(for: book, restart: .continueExisting) }
                        }
                        Button("Restart synchronization", systemImage: "arrow.triangle.2.circlepath") {
                            pendingIntent = .restart(book, .sync)
                        }
                        Button("Restart transcription", systemImage: "waveform") {
                            pendingIntent = .restart(book, .transcription)
                        }
                        Button("Restart from scratch", systemImage: "trash", role: .destructive) {
                            pendingIntent = .restart(book, .full)
                        }
                    } label: {
                        Label("Process", systemImage: "gearshape.2")
                            .font(.hearthUI(13, weight: .semibold))
                            .foregroundStyle(hearth.ember)
                            .frame(minHeight: 38)
                    }
                    .disabled(model.processingBookId != nil)
                }
            }
        }
    }

    private func run(_ intent: StorytellerProcessIntent) {
        pendingIntent = nil
        Task {
            switch intent {
            case .restart(let book, let mode):
                await model.startAlignment(for: book, restart: mode)
            case .cancel(let book):
                await model.cancelAlignment(for: book)
            }
        }
    }

    private func sortedGrades(_ facets: StorytellerAlignmentFacets) -> [(key: String, value: Int)] {
        let order = ["A+", "A", "A-", "B", "B-", "C", "D", "F"]
        return facets.grades.sorted {
            let left = order.firstIndex(of: $0.key.uppercased()) ?? order.count
            let right = order.firstIndex(of: $1.key.uppercased()) ?? order.count
            return left == right ? $0.key < $1.key : left < right
        }
    }

    private func gradeColor(_ grade: String) -> Color {
        switch grade.uppercased() {
        case "A+", "A", "A-", "B", "B-": return hearth.statusOK
        case "C": return hearth.statusWarn
        case "D", "F": return hearth.statusError
        default: return hearth.textSecondary
        }
    }

    private func statusColor(_ book: StorytellerProcessingBook) -> Color {
        switch book.readaloudStatus?.uppercased() {
        case "ALIGNED": return hearth.statusOK
        case "ERROR": return hearth.statusError
        case "PROCESSING", "QUEUED": return hearth.ember
        default: return hearth.textSecondary
        }
    }
}

struct AdminStorytellerAlignmentReportScreen: View {
    let connection: ServerConnection
    let book: StorytellerProcessingBook

    @Environment(\.hearth) private var hearth
    @State private var model = AdminStorytellerReportModel()
    @State private var flaggedOnly = true

    private var visibleChapters: [StorytellerAlignmentChapter] {
        guard let chapters = model.report?.chapters else { return [] }
        let flagged = chapters.filter(\.flagged)
        return flaggedOnly && !flagged.isEmpty ? flagged : chapters
    }

    var body: some View {
        AdminSubScreen(overline: "Alignment report", title: book.title) {
            if model.isLoading && !model.hasLoaded {
                AdminLoadingRow("Reading Storyteller's alignment report…")
            } else if let error = model.error {
                SourcesCard {
                    Text(error)
                        .font(.hearthBody)
                        .foregroundStyle(hearth.statusError)
                }
            } else if let report = model.report {
                summaryCard(report)
                chaptersHeader(report)
                LazyVStack(spacing: 14) {
                    ForEach(visibleChapters) { chapter in
                        chapterCard(chapter)
                    }
                }
                if !report.unalignedChapters.isEmpty {
                    Overline("Unaligned chapters")
                    LazyVStack(spacing: 14) {
                        ForEach(report.unalignedChapters) { chapter in
                            unalignedChapterCard(chapter)
                        }
                    }
                }
                if !report.unalignedAudioFiles.isEmpty {
                    Overline("Unaligned audio")
                    LazyVStack(spacing: 14) {
                        ForEach(report.unalignedAudioFiles) { audio in
                            unalignedAudioCard(audio)
                        }
                    }
                }
            } else if model.hasLoaded {
                SourcesCard {
                    AdminEmptyText("Storyteller has no alignment report for this book yet.")
                }
            }
        }
        .task(id: book.id) {
            await model.load(connection: connection, bookId: book.id)
            flaggedOnly = model.report?.chapters.contains(where: \.flagged) == true
        }
    }

    private func summaryCard(_ report: StorytellerAlignmentReport) -> some View {
        SourcesCard {
            Overline("Quality summary")
            HStack(alignment: .top) {
                AdminStat(value: report.summary.grade, label: "Grade")
                AdminStat(
                    value: report.summary.score.map { String(format: "%.1f", $0) } ?? "—",
                    label: "Score"
                )
                AdminStat(value: "\(report.summary.chapters)", label: "Chapters")
            }
            let sentenceCoverage = report.totalSentences > 0
                ? Double(report.alignedSentences) / Double(report.totalSentences)
                : 0
            AdminInfoRow(
                label: "Sentences aligned",
                value: "\(report.alignedSentences.formatted()) of \(report.totalSentences.formatted())"
            )
            AdminProgressLine(fraction: sentenceCoverage)
            if report.totalAudioDuration > 0 {
                AdminInfoRow(
                    label: "Audio aligned",
                    value: percentage(report.alignedAudioDuration / report.totalAudioDuration)
                )
            }
            AdminInfoRow(label: "Missing sentences", value: report.summary.missingSentences.formatted())
            AdminInfoRow(label: "Failed chapters", value: report.summary.failedChapters.formatted())
            AdminInfoRow(label: "Unaligned audio", value: report.summary.unalignedAudio.formatted())
        }
    }

    private func chaptersHeader(_ report: StorytellerAlignmentReport) -> some View {
        HStack {
            Overline("Chapters")
            Spacer()
            if report.chapters.contains(where: \.flagged) {
                HearthChip(title: "Flagged only", isSelected: flaggedOnly) {
                    flaggedOnly.toggle()
                }
            }
        }
    }

    private func chapterCard(_ chapter: StorytellerAlignmentChapter) -> some View {
        SourcesCard {
            HStack(alignment: .firstTextBaseline) {
                Text(chapter.title ?? chapter.label)
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Spacer()
                if chapter.markedOk {
                    AdminTag(text: "Reviewed", color: hearth.statusOK)
                } else if chapter.flagged {
                    AdminTag(text: "Flagged", color: hearth.statusWarn)
                }
            }
            if let coverage = chapter.coverage {
                AdminInfoRow(label: "Coverage", value: percentage(coverage))
                AdminProgressLine(fraction: coverage)
            }
            AdminInfoRow(
                label: "Sentences",
                value: "\(chapter.alignedSentenceCount) of \(chapter.chapterSentenceCount)"
            )
            if chapter.delta != 0 || chapter.deltaPct != 0 {
                let delta = chapter.delta.formatted(.number.precision(.fractionLength(0...1)))
                let deltaPercent = String(format: "%+.1f%%", chapter.deltaPct * 100)
                AdminInfoRow(
                    label: "Sentence delta",
                    value: "\(delta) (\(deltaPercent))"
                )
            }
            ForEach(chapter.flags) { flag in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(flagColor(flag.tone))
                    Text(flag.label)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
        }
    }

    private func unalignedChapterCard(_ chapter: StorytellerUnalignedChapter) -> some View {
        SourcesCard {
            HStack {
                Text(chapter.label)
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Spacer()
                if chapter.intended { AdminTag(text: "Intentional", color: hearth.statusOK) }
            }
            Text(chapter.reason)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
            if let preview = chapter.preview, !preview.isEmpty {
                Text(preview)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
                    .lineLimit(4)
            }
        }
    }

    private func unalignedAudioCard(_ audio: StorytellerUnalignedAudioFile) -> some View {
        SourcesCard {
            HStack {
                Text(audio.title ?? URL(fileURLWithPath: audio.filepath).lastPathComponent)
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                Spacer()
                if audio.excluded { AdminTag(text: "Excluded", color: hearth.textSecondary) }
            }
            if let duration = audio.duration {
                AdminInfoRow(label: "Duration", value: AdminFormat.hours(duration))
            }
            if let transcription = audio.transcription, !transcription.isEmpty {
                Text(transcription)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(5)
            }
        }
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    private func flagColor(_ tone: String) -> Color {
        switch tone.lowercased() {
        case "poor": return hearth.statusError
        case "moderate": return hearth.statusWarn
        case "good": return hearth.statusOK
        default: return hearth.ember
        }
    }
}
