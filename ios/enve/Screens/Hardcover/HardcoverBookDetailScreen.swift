import SwiftUI

struct HardcoverBookDetailScreen: View {
    let bookId: Int
    let bookTitle: String?

    @Environment(AppState.self) private var appState
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var book: HardcoverBook?
    @State private var userBook: HardcoverUserBook?
    @State private var editions: [HardcoverEdition] = []
    @State private var reviews: [HardcoverReview] = []
    @State private var linkedLocalBooks: [Book] = []
    @State private var loadError: String?
    @State private var loaded = false

    @State private var ratingShown = false
    @State private var reviewShown = false
    @State private var statusPickerShown = false
    @State private var reverseMatchTarget: HardcoverUserBookLegacy?
    @State private var pendingRating: Double = 0
    @State private var pendingReview = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HardcoverScreenHeader(overline: "Hardcover", title: bookTitle ?? book?.title ?? "A book")

                if !loaded {
                    HardcoverLoading(line: "Opening the record.")
                } else if let loadError {
                    HardcoverEmpty(glyph: "exclamationmark.triangle", title: "Hardcover is out of reach.", line: loadError)
                } else if let book {
                    header(book)
                    actions
                    linkedSection
                    if let description = book.description, !description.isEmpty {
                        descriptionSection(description)
                    }
                    if !reviews.isEmpty {
                        reviewsSection
                    }
                    if !editions.isEmpty {
                        editionsSection
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await hardcoverLoadDetails()
            await hardcoverReloadLinked()
        }
        .sheet(isPresented: $ratingShown) { ratingSheet }
        .sheet(isPresented: $reviewShown) { reviewSheet }
        .sheet(item: $reverseMatchTarget) { legacy in
            HardcoverReverseMatchScreen(hardcoverBook: legacy)
                .onDisappear { Task { await hardcoverReloadLinked() } }
                .enveEnvironment()
        }
        .confirmationDialog("Where does this book stand?", isPresented: $statusPickerShown, titleVisibility: .visible) {
            ForEach(HardcoverReadingStatus.allCases, id: \.rawValue) { status in
                Button(status.displayName) {
                    Task { await hardcoverUpdateStatus(status) }
                }
            }
            Button("Take off the shelf", role: .destructive) {
                Task { await hardcoverRemove() }
            }
        }
    }

    private func header(_ book: HardcoverBook) -> some View {
        VStack(spacing: 14) {
            HardcoverCoverThumb(urlString: book.image?.url, width: 130)

            VStack(spacing: 6) {
                Text(book.title)
                    .font(.hearthDisplay(24, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                Text(book.authorDisplay)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                if let year = book.releaseYear {
                    Text(String(year))
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                }
            }

            if let userBook {
                VStack(spacing: 10) {
                    HardcoverStatusChip(status: userBook.readingStatus)
                    if let rating = userBook.rating, rating > 0 {
                        HardcoverStars(rating: rating, size: 13)
                    }
                    if userBook.progress > 0, userBook.readingStatus == .currentlyReading {
                        Ribbon(progress: userBook.progress, tint: hearth.ember)
                            .frame(maxWidth: 200)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            if userBook != nil {
                HStack(spacing: 10) {
                    QuietButton(title: "Status", systemImage: "book") { statusPickerShown = true }
                    QuietButton(title: "Rate", systemImage: "star") {
                        pendingRating = userBook?.rating ?? 0
                        ratingShown = true
                    }
                    QuietButton(title: "Review", systemImage: "text.quote") {
                        pendingReview = userBook?.review ?? ""
                        reviewShown = true
                    }
                }
                EmberButton(title: "Match to your library", systemImage: "link.badge.plus") {
                    if let legacy = hardcoverLegacyForMatch() {
                        reverseMatchTarget = legacy
                    }
                }
            } else {
                HStack(spacing: 10) {
                    QuietButton(title: "Want to read", systemImage: "bookmark") {
                        Task { await hardcoverAddToShelf(startReading: false) }
                    }
                    EmberButton(title: "Start reading", systemImage: "book.fill") {
                        Task { await hardcoverAddToShelf(startReading: true) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private var linkedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "In your library here")
            if linkedLocalBooks.isEmpty {
                Text("Nothing linked yet. Match to your library and progress flows between the two.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .padding(.horizontal, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(linkedLocalBooks, id: \.stableId) { localBook in
                        NavigationLink {
                            BookDetailScreen(book: localBook)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: localBook.mediaType == .ebook ? "book.closed" : "headphones")
                                    .font(.hearthUI(14, weight: .medium))
                                    .foregroundStyle(hearth.ember)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(localBook.title)
                                        .font(.hearthUI(15, weight: .medium))
                                        .foregroundStyle(hearth.text)
                                        .lineLimit(1)
                                    Text(localBook.author ?? "Unknown author")
                                        .font(.hearthCaption)
                                        .foregroundStyle(hearth.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.hearthUI(11, weight: .semibold))
                                    .foregroundStyle(hearth.textTertiary)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        if localBook.stableId != linkedLocalBooks.last?.stableId {
                            Rectangle().fill(hearth.hairline).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func descriptionSection(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "About")
            Text(description.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
                .lineLimit(8)
                .padding(.horizontal, 24)
        }
    }

    private var reviewsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "What the circle said")
            VStack(spacing: 14) {
                ForEach(reviews.prefix(5)) { review in
                    HardcoverCard {
                        HStack {
                            Text("@\(review.username)")
                                .font(.hearthUI(13, weight: .semibold))
                                .foregroundStyle(hearth.text)
                            Spacer()
                            if let rating = review.rating, rating > 0 {
                                HardcoverStars(rating: rating, size: 10)
                            }
                        }
                        if let text = review.reviewText, !text.isEmpty {
                            Text(text)
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                                .lineLimit(4)
                        }
                        if !review.timeAgo.isEmpty {
                            Text(review.timeAgo)
                                .font(.hearthUI(11))
                                .foregroundStyle(hearth.textTertiary)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var editionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Editions")
            VStack(spacing: 0) {
                ForEach(editions.prefix(5)) { edition in
                    HStack(spacing: 12) {
                        HardcoverCoverThumb(urlString: edition.image?.url, width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(edition.title ?? "Edition \(edition.id)")
                                .font(.hearthUI(14, weight: .medium))
                                .foregroundStyle(hearth.text)
                                .lineLimit(1)
                            if !edition.displayInfo.isEmpty {
                                Text(edition.displayInfo)
                                    .font(.hearthCaption)
                                    .foregroundStyle(hearth.textSecondary)
                            }
                            if let publisher = edition.publisher?.name {
                                Text(publisher)
                                    .font(.hearthUI(11))
                                    .foregroundStyle(hearth.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if edition.isAudiobook {
                            Image(systemName: "headphones")
                                .font(.hearthUI(13))
                                .foregroundStyle(hearth.ember)
                        }
                    }
                    .padding(.vertical, 9)
                    if edition.id != editions.prefix(5).last?.id {
                        Rectangle().fill(hearth.hairline).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var ratingSheet: some View {
        VStack(spacing: 26) {
            VStack(spacing: 6) {
                Overline("Rating")
                Text("How did it sit with you?")
                    .font(.hearthDisplay(22, weight: .semibold))
                    .foregroundStyle(hearth.text)
            }
            .padding(.top, 28)

            HStack(spacing: 10) {
                ForEach(1...5, id: \.self) { i in
                    Button {
                        pendingRating = Double(i)
                    } label: {
                        Image(systemName: Double(i) <= pendingRating ? "star.fill" : "star")
                            .font(.hearthUI(30))
                            .foregroundStyle(hearth.ember)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("\(i) of five")
                }
            }

            EmberButton(title: "Keep this rating") {
                Task {
                    if let userBookId = userBook?.id {
                        try? await HardcoverService.shared.rateBook(userBookId: userBookId, rating: pendingRating)
                        await hardcoverLoadDetails()
                    }
                    ratingShown = false
                }
            }
            .disabled(pendingRating == 0)
            .opacity(pendingRating == 0 ? 0.5 : 1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .presentationDetents([.height(300)])
        .hearthPresentationBackground()
    }

    private var reviewSheet: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Overline("Review")
                Text("A few words for the circle")
                    .font(.hearthDisplay(22, weight: .semibold))
                    .foregroundStyle(hearth.text)
            }
            .padding(.top, 28)

            TextEditor(text: $pendingReview)
                .font(.hearthBody)
                .foregroundStyle(hearth.text)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 160)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(hearth.bg)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(hearth.hairline, lineWidth: 1)
                        }
                }

            EmberButton(title: "Post the review") {
                Task {
                    if let userBookId = userBook?.id {
                        try? await HardcoverService.shared.reviewBook(userBookId: userBookId, reviewText: pendingReview)
                        await hardcoverLoadDetails()
                    }
                    reviewShown = false
                }
            }
            .disabled(pendingReview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(pendingReview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .presentationDetents([.medium])
        .hearthPresentationBackground()
    }

    private func hardcoverLoadDetails() async {
        loadError = nil
        do {
            async let bookReq = HardcoverService.shared.getBookById(bookId)
            async let editionsReq = HardcoverService.shared.getEditionsForBook(bookId: bookId)
            async let reviewsReq = HardcoverService.shared.getBookReviews(bookId: bookId)
            async let userBooksReq = HardcoverService.shared.getUserBooksRich(limit: 200)
            let (b, e, r, ubs) = try await (bookReq, editionsReq, reviewsReq, userBooksReq)
            book = b
            editions = e
            reviews = r
            userBook = ubs.first { $0.bookId == bookId }
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }

    private func hardcoverReloadLinked() async {
        let linkedIds = Set(
            SettingsManager.shared.getAllHardcoverMatches()
                .filter { $0.hardcoverBookId == bookId }
                .map(\.localBookId)
        )
        var matched: [Book] = []
        for id in linkedIds {
            if let localBook = await appState.bookStore.book(byBookId: id) {
                matched.append(localBook)
            }
        }
        linkedLocalBooks = matched.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func hardcoverAddToShelf(startReading: Bool) async {
        do {
            _ = try await HardcoverService.shared.addBookToLibrary(bookId: bookId, startReading: startReading)
            PlatformHaptics.notification(.success)
            await hardcoverLoadDetails()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func hardcoverUpdateStatus(_ status: HardcoverReadingStatus) async {
        guard let userBookId = userBook?.id else { return }
        try? await HardcoverService.shared.updateBookStatus(userBookId: userBookId, statusId: status.rawValue)
        await hardcoverLoadDetails()
    }

    private func hardcoverRemove() async {
        guard let userBookId = userBook?.id else { return }
        try? await HardcoverService.shared.deleteUserBook(userBookId: userBookId)
        userBook = nil
    }

    private func hardcoverLegacyForMatch() -> HardcoverUserBookLegacy? {
        guard let book else { return nil }
        let reads = userBook?.userBookReads?.map {
            HardcoverUserBookReadLegacy(
                id: $0.id,
                startedAt: $0.startedAt,
                finishedAt: $0.finishedAt,
                progress: $0.progressPages.map(Double.init)
            )
        }
        return HardcoverUserBookLegacy(
            id: userBook?.id ?? 0,
            book: book,
            rating: userBook?.rating.map { Int($0.rounded()) },
            review: userBook?.review,
            statusId: userBook?.statusId ?? HardcoverReadingStatus.wantToRead.rawValue,
            editionId: userBook?.editionId,
            totalPages: userBook?.edition?.pages,
            userBookReads: reads,
            authors: nil
        )
    }
}
