import SwiftUI

struct WorkHubScreen: View {
    let workKey: String
    var seed: Book?

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var work: WorkView?
    @State private var loading = true
    @State private var selectedEditionID: String?
    @State private var descriptionExpanded = false
    @State private var sourceToSplit: Book?
    @State private var splitConfirmShown = false

    private var selectedEdition: EditionView? {
        guard let work else { return nil }
        return work.editions.first { $0.id == selectedEditionID } ?? work.primaryEdition
    }

    private var headerBook: Book? { selectedEdition?.representative ?? work?.representative ?? seed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let work, work.editionCount > 1 { editionsSection(work) }
                actions
                if let description = headerBook?.description, !description.isEmpty {
                    descriptionSection(description)
                }
                if let edition = selectedEdition { sourcesSection(edition) }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: workKey) { await load() }
        .confirmationDialog(
            "Separate this copy?",
            isPresented: $splitConfirmShown,
            presenting: sourceToSplit
        ) { book in
            Button("Separate", role: .destructive) {
                engine.library.splitWorkSource(stableId: book.stableId)
                Task { await load() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { book in
            Text("\u{201C}\(book.title)\u{201D} becomes its own entry again.")
        }
    }

    private func load() async {
        loading = true
        let loadedWork = await engine.library.workView(workKey: workKey)
        work = loadedWork
        if selectedEditionID == nil {
            selectedEditionID =
                loadedWork?.editions.first {
                    $0.sources.contains { $0.uniqueId == seed?.uniqueId }
                }?.id ?? loadedWork?.primaryEdition.id
        }
        loading = false
    }

    private var header: some View {
        VStack(spacing: 16) {
            ZStack {
                EmberGlow(tint: hearth.ember, isBreathing: false, intensity: 0.5)
                    .frame(height: 260)
                CachedAsyncCoverImage(
                    url: headerBook?.coverURL,
                    fallbackColor: "Blue",
                    headers: headerBook.map { CachedAsyncCoverImage.authHeaders(for: $0) } ?? [:],
                    book: headerBook
                )
                .frame(width: 190, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
                .shadow(color: .black.opacity(hearth.isInk ? 0.5 : 0.2), radius: 20, y: 10)
            }

            VStack(spacing: 6) {
                Overline(countLine)
                Text(headerBook?.title ?? seed?.title ?? "Work")
                    .font(.hearthDisplay(26))
                    .foregroundStyle(hearth.text)
                    .multilineTextAlignment(.center)
                if let author = headerBook?.author, !author.isEmpty {
                    Text(author)
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
                if let series = headerBook?.series, !series.isEmpty {
                    Overline(seriesLine(series), color: hearth.textTertiary)
                }
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
    }

    private var countLine: String {
        guard let work else { return "One work" }
        let editions = work.editionCount
        let sources = work.sourceCount
        let e = editions == 1 ? "one edition" : "\(editions) editions"
        let s = sources == 1 ? "one copy" : "\(sources) copies"
        return "\(e) · \(s)"
    }

    private func seriesLine(_ series: String) -> String {
        if let seq = headerBook?.seriesSequence ?? headerBook?.seriesNumber.map(String.init) {
            return "\(series) · No. \(seq)"
        }
        return series
    }

    private func editionsSection(_ work: WorkView) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Editions")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(work.editions) { editionChip($0) }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func editionChip(_ edition: EditionView) -> some View {
        let isSelected = edition.id == selectedEdition?.id
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selectedEditionID = edition.id }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: edition.format == .ebook ? "book.closed.fill" : "headphones")
                        .font(.hearthUI(11))
                    Text(edition.label)
                        .font(.hearthUI(14, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(isSelected ? hearth.onEmber : hearth.text)

                HStack(spacing: 10) {
                    if let duration = edition.representative.duration, duration > 0 {
                        Label(HearthFormat.duration(duration), systemImage: "clock")
                    }
                    Label("\(edition.sources.count)", systemImage: "server.rack")
                }
                .font(.hearthUI(11))
                .foregroundStyle(isSelected ? hearth.onEmber.opacity(0.85) : hearth.textSecondary)
            }
            .padding(14)
            .frame(width: 210, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .fill(isSelected ? hearth.ember : hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                            .strokeBorder(isSelected ? Color.clear : hearth.hairline, lineWidth: 1)
                    }
            }
        }
        .buttonStyle(PressableStyle())
    }

    private var actions: some View {
        VStack(spacing: 14) {
            if let edition = selectedEdition {
                EmberButton(title: primaryTitle(edition), systemImage: edition.format == .ebook ? "book.fill" : "play.fill") {
                    PlatformHaptics.impact(.light)
                    engine.playback.play(playbackSource(for: edition))
                }
            }
            if let other = crossFormatEdition {
                QuietButton(
                    title: other.format == .ebook ? "Read instead" : "Listen instead",
                    systemImage: other.format == .ebook ? "book" : "headphones"
                ) {
                    PlatformHaptics.impact(.light)
                    engine.playback.play(other.resumeSource)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private var crossFormatEdition: EditionView? {
        guard let work, let selected = selectedEdition else { return nil }
        return work.editions.first { $0.format != selected.format }
    }

    private func primaryTitle(_ edition: EditionView) -> String {
        if WorkGrouping.progressFraction(playbackSource(for: edition)) > 0.001 { return "Resume" }
        return edition.format == .ebook ? "Read" : "Listen"
    }

    private func playbackSource(for edition: EditionView) -> Book {
        edition.sources.first { $0.uniqueId == seed?.uniqueId } ?? edition.resumeSource
    }

    private func descriptionSection(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: "About")
            Text(description)
                .font(.hearthDisplay(15, weight: .regular))
                .foregroundStyle(hearth.textSecondary)
                .lineSpacing(4)
                .lineLimit(descriptionExpanded ? nil : 4)
                .padding(.horizontal, 24)
            Button {
                withAnimation(.smooth(duration: 0.35)) { descriptionExpanded.toggle() }
            } label: {
                Text(descriptionExpanded ? "Less" : "More")
                    .font(.hearthUI(13, weight: .medium))
                    .foregroundStyle(hearth.ember)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 24)
        }
    }

    private func sourcesSection(_ edition: EditionView) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: edition.sources.count == 1 ? "Source" : "Available on")
            VStack(spacing: 10) {
                ForEach(edition.sources, id: \.uniqueId) { source in
                    sourceCard(source, isOnlyMember: (work?.sourceCount ?? 0) <= 1)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func sourceCard(_ source: Book, isOnlyMember: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: source.source == .local ? "arrow.down.circle.fill" : "server.rack")
                .font(.hearthUI(15))
                .foregroundStyle(source.source == .local ? hearth.ember : hearth.textSecondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(sourceName(source))
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                if let library = source.libraryName, !library.isEmpty {
                    Text(library)
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)

            GlyphButton(systemImage: "play.fill", label: "Play this copy") {
                engine.playback.play(source)
            }
            if !isOnlyMember {
                GlyphButton(systemImage: "rectangle.split.2x1", label: "Separate this copy") {
                    sourceToSplit = source
                    splitConfirmShown = true
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
        }
    }

    private func sourceName(_ book: Book) -> String {
        if let backend = book.backendName, !backend.isEmpty { return backend }
        if book.source == .local { return "On this device" }
        return book.source.rawValue.capitalized
    }
}
