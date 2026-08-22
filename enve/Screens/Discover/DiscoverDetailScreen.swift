import SwiftUI

struct DiscoverDetailScreen: View {
    let discoverBook: DiscoverBook

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var libraryMatch: Book?
    @State private var matchChecked = false
    @State private var descriptionExpanded = false
    @State private var hardcoverIsWorking = false
    @State private var hardcoverStatus: HardcoverReadingStatus?
    @State private var hardcoverError: String?
    @State private var hardcoverCandidates: [HardcoverBook] = []
    @State private var pendingHardcoverStatus: HardcoverReadingStatus?
    @State private var showsHardcoverPicker = false
    @State private var showsHardcoverStatusPicker = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") { dismiss() }
                    Spacer()
                }
                .padding(.horizontal, 24)

                hero

                libraryStanding

                if SettingsManager.shared.hardcoverApiKey != nil {
                    hardcoverSection
                }

                aboutGrid

                if let description = discoverBook.shortDescription {
                    descriptionSection(description)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task { await discoverFindInLibrary() }
        .sheet(isPresented: $showsHardcoverPicker) {
            if let pendingHardcoverStatus {
                HardcoverDiscoverMatchSheet(
                    books: hardcoverCandidates,
                    status: pendingHardcoverStatus
                ) { book in
                    Task { await hardcoverSave(book: book, status: pendingHardcoverStatus) }
                }
                .enveEnvironment()
            }
        }
        .alert(
            "Couldn’t save to Hardcover",
            isPresented: Binding(
                get: { hardcoverError != nil },
                set: { if !$0 { hardcoverError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(hardcoverError ?? "Unknown Hardcover error.")
        }
        .confirmationDialog(
            "Save to Hardcover as…",
            isPresented: $showsHardcoverStatusPicker,
            titleVisibility: .visible
        ) {
            ForEach(HardcoverReadingStatus.allCases, id: \.rawValue) { status in
                Button(status.displayName) {
                    Task { await hardcoverResolveAndSave(status: status) }
                }
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 16) {
            ZStack {
                EmberGlow(tint: hearth.ember, isBreathing: false, intensity: 0.45)
                DiscoverArtTile(book: discoverBook, width: 190)
            }
            .frame(height: 230)

            VStack(spacing: 6) {
                Text(LibraryDisplayFormatter.displayTitle(discoverBook.title))
                    .font(.hearthDisplay(24, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                Text(discoverBook.author)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                if let genre = discoverBook.genre {
                    Text(genre.uppercased())
                        .font(.hearthUI(10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(hearth.ember)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(hearth.emberSoft, in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var libraryStanding: some View {
        VStack(spacing: 12) {
            if let match = libraryMatch {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.hearthUI(13))
                    Text("Already on your shelves.")
                        .font(.hearthUI(14, weight: .medium))
                }
                .foregroundStyle(hearth.statusOK)

                HStack(spacing: 10) {
                    NavigationLink {
                        BookDetailScreen(book: match)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "book")
                                .font(.hearthUI(14, weight: .medium))
                            Text("Open in library")
                                .font(.hearthUI(15, weight: .medium))
                        }
                        .foregroundStyle(hearth.text)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background {
                            Capsule()
                                .fill(hearth.bgElevated)
                                .overlay(Capsule().strokeBorder(hearth.hairline, lineWidth: 1))
                        }
                    }
                    .buttonStyle(PressableStyle())

                    EmberButton(
                        title: match.progressPercentage > 0 ? "Continue" : (match.mediaType == .ebook ? "Read" : "Listen"),
                        systemImage: "play.fill"
                    ) {
                        engine.playback.play(match)
                    }
                }
            } else if matchChecked {
                VStack(spacing: 8) {
                    Text("Not in any connected library.")
                        .font(.hearthUI(14, weight: .medium))
                        .foregroundStyle(hearth.textSecondary)
                    Text("Discover only points the way. Add a source that carries this book and it becomes playable here.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background {
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .fill(hearth.bgElevated)
                        .overlay {
                            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                                .strokeBorder(hearth.hairline, lineWidth: 1)
                        }
                }
            } else {
                ProgressView()
                    .tint(hearth.ember)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private var aboutGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "The facts")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                if let duration = discoverBook.formattedDuration {
                    discoverFactCell(value: duration, label: "Length")
                }
                if let narrator = discoverBook.narrator, !narrator.isEmpty {
                    discoverFactCell(value: narrator, label: "Narrator")
                }
                if let year = discoverBook.releaseYear {
                    discoverFactCell(value: year, label: "Released")
                }
                if let genre = discoverBook.genre {
                    discoverFactCell(value: genre, label: "Genre")
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var hardcoverSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Hardcover")

            VStack(alignment: .leading, spacing: 12) {
                if let hardcoverStatus {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Saved as \(hardcoverStatus.displayName).")
                    }
                    .font(.hearthUI(13, weight: .medium))
                    .foregroundStyle(hearth.statusOK)
                } else {
                    Text("Send this book to your Hardcover shelf.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }

                HStack(spacing: 10) {
                    QuietButton(title: "Want to Read", systemImage: "bookmark") {
                        Task { await hardcoverResolveAndSave(status: .wantToRead) }
                    }
                    QuietButton(title: "Other status", systemImage: "ellipsis.circle") {
                        showsHardcoverStatusPicker = true
                    }
                }
                .disabled(hardcoverIsWorking)
                .opacity(hardcoverIsWorking ? 0.55 : 1)

                if hardcoverIsWorking {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(hearth.ember)
                        Text("Finding the exact Hardcover book…")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func discoverFactCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.hearthDisplay(17, weight: .semibold))
                .foregroundStyle(hearth.text)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Overline(label, color: hearth.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
        }
    }

    private func descriptionSection(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "About the story")
            VStack(alignment: .leading, spacing: 10) {
                Text(description)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(descriptionExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                if description.count > 200 {
                    Button {
                        withAnimation(.smooth(duration: 0.35)) {
                            descriptionExpanded.toggle()
                        }
                    } label: {
                        Text(descriptionExpanded ? "Fold it away" : "Read on")
                            .font(.hearthUI(13, weight: .medium))
                            .foregroundStyle(hearth.ember)
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func discoverFindInLibrary() async {
        let title = discoverBook.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let author = discoverBook.author.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let candidates = await engine.library.searchBooks(query: discoverBook.title, limit: 50)
        libraryMatch = candidates.first { candidate in
            let candidateTitle = candidate.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateAuthor = (candidate.author ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let authorClose = candidateAuthor.contains(author) || author.contains(candidateAuthor)
            if candidateTitle == title && authorClose { return true }
            let titleClose =
                (candidateTitle.contains(title) || title.contains(candidateTitle))
                && candidateTitle.count > 3 && title.count > 3
            return titleClose && authorClose
        }
        matchChecked = true
    }

    private func hardcoverResolveAndSave(status: HardcoverReadingStatus) async {
        hardcoverIsWorking = true
        hardcoverError = nil

        do {
            if let asin = audibleASIN {
                let exactMatches = try await HardcoverService.shared.getBooksByAudibleASIN(asin)
                if exactMatches.count == 1, let book = exactMatches.first {
                    await hardcoverSave(book: book, status: status)
                    return
                }
                if !exactMatches.isEmpty {
                    hardcoverPresentPicker(books: exactMatches, status: status)
                    return
                }
            }

            let searchResults = try await HardcoverService.shared.searchBooks(
                query: discoverBook.title,
                limit: 10
            )
            guard !searchResults.isEmpty else {
                throw HardcoverError.noMatchFound
            }
            hardcoverPresentPicker(books: searchResults, status: status)
        } catch is CancellationError {
            hardcoverIsWorking = false
        } catch {
            hardcoverIsWorking = false
            hardcoverError = error.localizedDescription
        }
    }

    private func hardcoverPresentPicker(books: [HardcoverBook], status: HardcoverReadingStatus) {
        hardcoverCandidates = books
        pendingHardcoverStatus = status
        hardcoverIsWorking = false
        showsHardcoverPicker = true
    }

    private func hardcoverSave(book: HardcoverBook, status: HardcoverReadingStatus) async {
        hardcoverIsWorking = true
        hardcoverError = nil
        do {
            _ = try await HardcoverService.shared.setBookStatus(bookId: book.id, status: status)
            hardcoverStatus = status
            hardcoverIsWorking = false
            PlatformHaptics.notification(.success)
        } catch is CancellationError {
            hardcoverIsWorking = false
        } catch {
            hardcoverIsWorking = false
            hardcoverError = error.localizedDescription
        }
    }

    private var audibleASIN: String? {
        let prefix = "audible-"
        guard discoverBook.id.hasPrefix(prefix) else { return nil }
        let asin = String(discoverBook.id.dropFirst(prefix.count)).uppercased()
        guard asin.count == 10,
            asin.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else {
            return nil
        }
        return asin
    }
}

private struct HardcoverDiscoverMatchSheet: View {
    let books: [HardcoverBook]
    let status: HardcoverReadingStatus
    let onSelect: (HardcoverBook) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hearth) private var hearth

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Choose the matching Hardcover book before saving it as \(status.displayName).")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)

                    LazyVStack(spacing: 0) {
                        ForEach(books) { book in
                            Button {
                                dismiss()
                                onSelect(book)
                            } label: {
                                HStack(spacing: 14) {
                                    HardcoverCoverThumb(urlString: book.image?.url)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(book.title)
                                            .font(.hearthDisplay(16, weight: .semibold))
                                            .foregroundStyle(hearth.text)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Text(book.authorDisplay)
                                            .font(.hearthCaption)
                                            .foregroundStyle(hearth.textSecondary)
                                            .lineLimit(1)
                                        if let year = book.releaseYear {
                                            Text(String(year))
                                                .font(.hearthUI(11))
                                                .foregroundStyle(hearth.textTertiary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.hearthUI(11, weight: .semibold))
                                        .foregroundStyle(hearth.textTertiary)
                                }
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle())

                            if book.id != books.last?.id {
                                Rectangle()
                                    .fill(hearth.hairline)
                                    .frame(height: 1)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .background(HearthBackground())
            .navigationTitle("Match on Hardcover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
