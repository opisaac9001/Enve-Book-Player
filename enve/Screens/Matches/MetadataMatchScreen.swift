import SwiftUI

struct MetadataMatchScreen: View {
    let book: Book

    @Environment(EnveEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MatchesSearchView(
            book: book,
            fileMetadata: FileMetadataLayer(
                title: book.title,
                author: book.author,
                narrator: book.narrator,
                description: book.description,
                duration: book.duration,
                isbn: book.isbn,
                fileName: book.filePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ),
            initialQuery: book.title,
            oniTunes: { apply($0) },
            onAudible: { apply($0) },
            onGoogleBooks: { apply($0) },
            onOpenLibrary: { apply($0) },
            onComicVine: { apply($0) },
            onEnve: { apply($0) }
        )
    }

    private func apply(_ layer: Any) {
        Task {
            await engine.matches.applyMetadataLayer(layer, to: book)
            dismiss()
        }
    }
}

struct MatchesSearchView: View {
    let book: Book
    let oniTunes: (iTunesMetadataLayer) -> Void
    let onAudible: (AudibleMetadataLayer) -> Void
    let onGoogleBooks: (GoogleBooksMetadataLayer) -> Void
    let onOpenLibrary: (OpenLibraryMetadataLayer) -> Void
    let onComicVine: (ComicVineMetadataLayer) -> Void
    let onEnve: (EnveMetadataLayer) -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var model: MatchesSearchModel
    @State private var expandedResultId: String?

    init(
        book: Book,
        fileMetadata: FileMetadataLayer,
        initialQuery: String,
        oniTunes: @escaping (iTunesMetadataLayer) -> Void,
        onAudible: @escaping (AudibleMetadataLayer) -> Void,
        onGoogleBooks: @escaping (GoogleBooksMetadataLayer) -> Void,
        onOpenLibrary: @escaping (OpenLibraryMetadataLayer) -> Void,
        onComicVine: @escaping (ComicVineMetadataLayer) -> Void,
        onEnve: @escaping (EnveMetadataLayer) -> Void
    ) {
        self.book = book
        self.oniTunes = oniTunes
        self.onAudible = onAudible
        self.onGoogleBooks = onGoogleBooks
        self.onOpenLibrary = onOpenLibrary
        self.onComicVine = onComicVine
        self.onEnve = onEnve
        _model = State(
            initialValue: MatchesSearchModel(
                fileMetadata: fileMetadata,
                initialQuery: initialQuery,
                mediaType: book.mediaType
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Overline("Set the record straight")
                    Text("Match metadata")
                        .font(.hearthDisplay(24, weight: .semibold))
                        .foregroundStyle(hearth.text)
                }
                Spacer()
                GlyphButton(systemImage: "xmark", size: 40, glyphSize: 14, label: "Close") {
                    model.stopPreview()
                    dismiss()
                }
            }
            .padding(.top, 24)

            bookCard

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.availableSources) { source in
                        HearthChip(title: source.displayName, isSelected: model.selectedProvider == source) {
                            model.selectedProvider = source
                        }
                    }
                }
            }

            if model.selectedProvider == .comicVine && !ComicVineService.shared.hasApiKey {
                comicVineSetup
            } else {
                searchRow
                resultsList
            }
        }
        .padding(.horizontal, 24)
        .hearthPresentationBackground()
        .presentationDragIndicator(.visible)
        .onDisappear { model.stopPreview() }
    }

    private var bookCard: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverTile(book: book, width: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.fileMetadata.title ?? book.title)
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                if let author = model.fileMetadata.author ?? book.author {
                    Text(author)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(1)
                }
                if book.mediaType != .ebook, let duration = model.fileDuration {
                    Label(HearthFormat.duration(duration), systemImage: "clock")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                if let fileName = model.fileMetadata.fileName, !fileName.isEmpty {
                    Text(fileName)
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                        .lineLimit(1)
                }
                if model.supportsPreview {
                    previewButton
                }
                if let previewError = model.previewError {
                    Text(previewError)
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.statusError)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(dedupCardBackground(hearth))
    }

    private var previewButton: some View {
        Button {
            if model.isPreviewPlaying || model.isStartingPreview {
                model.stopPreview()
            } else {
                Task { await model.startPreview(book: book) }
            }
        } label: {
            HStack(spacing: 5) {
                if model.isStartingPreview {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(hearth.onEmber)
                } else {
                    Image(systemName: model.isPreviewPlaying ? "stop.fill" : "play.fill")
                        .font(.hearthUI(10, weight: .semibold))
                }
                Text(model.isStartingPreview ? "Loading\u{2026}" : (model.isPreviewPlaying ? "Stop" : "Hear a minute"))
                    .font(.hearthUI(12, weight: .semibold))
            }
            .foregroundStyle(hearth.onEmber)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(hearth.ember, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .padding(.top, 2)
        .accessibilityLabel(model.isPreviewPlaying ? "Stop preview" : "Play a one minute preview")
    }

    private var searchRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CollectionsSearchField(text: $model.query)
                Button {
                    Task { await model.search(source: model.selectedProvider) }
                } label: {
                    Group {
                        if model.isSearching {
                            ProgressView()
                                .tint(hearth.onEmber)
                        } else {
                            Image(systemName: "magnifyingglass")
                                .font(.hearthUI(15, weight: .semibold))
                                .foregroundStyle(hearth.onEmber)
                        }
                    }
                    .frame(width: 46, height: 44)
                    .background(hearth.ember, in: Circle())
                }
                .buttonStyle(PressableStyle())
                .disabled(model.isSearching)
                .accessibilityLabel("Search")
            }
            if let error = model.errorMessage, !model.isSearching {
                Text(error)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusWarn)
            }
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if model.results.isEmpty && !model.isSearching && model.errorMessage == nil {
                    Text("Search \(model.selectedProvider.displayName) to see candidates.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                }
                ForEach(model.results) { result in
                    resultRow(result)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func resultRow(_ result: MatchesSearchModel.Result) -> some View {
        let isExpanded = expandedResultId == result.id
        return VStack(spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.3)) {
                    expandedResultId = isExpanded ? nil : result.id
                }
            } label: {
                HStack(spacing: 12) {
                    MatchesRemoteCover(urlString: result.coverUrl, width: 46, height: 70)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.title)
                            .font(.hearthUI(14, weight: .semibold))
                            .foregroundStyle(hearth.text)
                            .lineLimit(isExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                        if let author = result.author, !author.isEmpty {
                            Text(author)
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                                .lineLimit(1)
                        }
                        if let series = result.seriesName, !series.isEmpty {
                            Text(result.seriesPosition.map { "\(series) · No. \($0)" } ?? series)
                                .font(.hearthUI(11))
                                .foregroundStyle(hearth.textTertiary)
                                .lineLimit(1)
                        }
                        durationLine(result)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
                        if let confidence = result.confidence {
                            matchesConfidenceTag(Int(confidence * 100), hearth: hearth)
                        }
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                    }
                }
                .padding(12)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 12) {
                    Rectangle().fill(hearth.hairline).frame(height: 1)
                    if let description = result.description, !description.isEmpty {
                        ScrollView {
                            Text(matchesStripHTML(description))
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                    EmberButton(title: "Use this match", systemImage: "checkmark") {
                        Task { await approve(result) }
                    }
                }
                .padding(12)
            }
        }
        .background(dedupCardBackground(hearth))
    }

    @ViewBuilder
    private func durationLine(_ result: MatchesSearchModel.Result) -> some View {
        if let duration = result.duration {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                Text(HearthFormat.duration(duration))
                if let fileDuration = model.fileDuration {
                    let diff = abs(duration - fileDuration)
                    Text(diff <= 60 ? "exact" : "\(HearthFormat.duration(diff)) off")
                        .foregroundStyle(diff <= 60 ? hearth.statusOK : diff <= 300 ? hearth.statusWarn : hearth.statusError)
                }
            }
            .font(.hearthUI(11))
            .foregroundStyle(hearth.textTertiary)
        } else if let pageCount = result.pageCount {
            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                Text("\(pageCount) pages")
                if let year = result.publishedYear {
                    Text("· \(String(year))")
                }
            }
            .font(.hearthUI(11))
            .foregroundStyle(hearth.textTertiary)
        }
    }

    private var comicVineSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("ComicVine needs an API key", systemImage: "key.fill")
                .font(.hearthUI(15, weight: .semibold))
                .foregroundStyle(hearth.text)
            Text(
                "ComicVine carries volume-level manga and comic metadata. Create a free account, copy your key, and paste it under Settings."
            )
            .font(.hearthCaption)
            .foregroundStyle(hearth.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            Link(destination: URL(string: "https://comicvine.gamespot.com/api/")!) {
                Text("Open the ComicVine API page")
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.ember)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dedupCardBackground(hearth))
    }

    private func approve(_ result: MatchesSearchModel.Result) async {
        do {
            switch result.source {
            case .iTunes:
                let layer = try await model.applyiTunes(id: result.id)
                model.stopPreview()
                oniTunes(layer)
            case .audiobookshelf:
                let layer = try await model.applyAudioBookshelf(id: result.id)
                model.stopPreview()
                onAudible(layer)
            case .enveSearch:
                let layer = try await model.applyEnveSearch(id: result.id)
                model.stopPreview()
                onEnve(layer)
            case .googleBooks:
                let layer = try await model.applyGoogleBooks(id: result.id)
                model.stopPreview()
                onGoogleBooks(layer)
            case .openLibrary:
                let layer = try await model.applyOpenLibrary(id: result.id)
                model.stopPreview()
                onOpenLibrary(layer)
            case .comicVine:
                let layer = try await model.applyComicVine(id: result.id)
                model.stopPreview()
                onComicVine(layer)
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

func matchesConfidenceTag(_ percent: Int, hearth: HearthPalette) -> some View {
    let tint: Color = percent >= 85 ? hearth.statusOK : percent >= 70 ? hearth.statusWarn : hearth.statusError
    return Text("\(percent)%")
        .font(.hearthUI(12, weight: .bold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
}

struct MatchesRemoteCover: View {
    let urlString: String?
    var width: CGFloat
    var height: CGFloat

    @Environment(\.hearth) private var hearth

    var body: some View {
        if let urlString, let url = URL(string: urlString) {
            CachedAsyncCoverImage(url: url, fallbackColor: "Blue", headers: [:], book: nil)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hearth.emberSoft)
                .frame(width: width, height: height)
                .overlay {
                    Image(systemName: "book.closed")
                        .font(.hearthUI(15))
                        .foregroundStyle(hearth.ember)
                }
        }
    }
}
