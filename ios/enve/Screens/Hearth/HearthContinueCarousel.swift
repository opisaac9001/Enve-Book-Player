import SwiftUI

struct HearthContinueCarousel<MenuItems: View>: View {
    let books: [Book]
    let sourceLabel: (Book) -> String
    @ViewBuilder let menu: (Book) -> MenuItems

    @Environment(\.hearth) private var hearth
    @State private var visibleId: String?

    private let maxDots = 10

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(books, id: \.stableId) { book in
                        HearthBookCard(book: book, sourceLabel: sourceLabel(book))
                            .contextMenu { menu(book) }
                            .containerRelativeFrame(.horizontal) { width, _ in
                                books.count > 1 ? width - 72 : width - 48
                            }
                            .id(book.stableId)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 24, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $visibleId)
            .scrollIndicators(.hidden)

            if books.count > 1 {
                pageIndicator
            }
        }
    }

    private var visibleIndex: Int {
        books.firstIndex { $0.stableId == visibleId } ?? 0
    }

    @ViewBuilder
    private var pageIndicator: some View {
        if books.count <= maxDots {
            HStack(spacing: 6) {
                ForEach(books.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == visibleIndex ? hearth.ember : hearth.hairline)
                        .frame(width: index == visibleIndex ? 14 : 6, height: 6)
                }
            }
            .animation(.snappy(duration: 0.2), value: visibleIndex)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Book \(visibleIndex + 1) of \(books.count)")
        } else {
            Text("\(visibleIndex + 1) of \(books.count)")
                .font(.hearthUI(11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(hearth.textTertiary)
        }
    }
}

struct HearthBookCard: View {
    let book: Book
    let sourceLabel: String
    var prominent = false

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @State private var tint: Color = Hearth.accent
    @State private var counterpart: Book?
    @State private var pageTotal: Int?

    @Environment(PlayerViewModel.self) private var player
    private var coverHeight: CGFloat { prominent ? 140 : 92 }
    private var padding: CGFloat { prominent ? 18 : 14 }

    private var isEbook: Bool { book.mediaType == .ebook }
    private var position: TimeInterval { engine.playback.position(for: book) }
    private var duration: TimeInterval? { engine.playback.duration(for: book) }
    private var fraction: Double { engine.playback.progressFraction(for: book) }
    private var percent: Int { Int((fraction * 100).rounded()) }

    private var byline: String? {
        if book.isPodcastEpisode {
            return book.podcastName ?? PodcastsFormat.displayAuthor(book.author)
        }
        return book.author
    }

    private var chapterTitle: String? {
        if isEbook {
            let title = (locator?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return title?.isEmpty == false ? title : nil
        }
        guard let chapters = book.chapters, !chapters.isEmpty else { return nil }
        let index = chapters.lastIndex { $0.start <= position } ?? 0
        return chapters[index].title.isEmpty ? "Chapter \(index + 1)" : chapters[index].title
    }

    private var locator: [String: Any]? {
        guard let data = book.epubLocator?.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private var locatorPosition: Int? {
        (locator?["locations"] as? [String: Any])?["position"] as? Int
    }

    private var readAloudBook: Book? {
        if book.epub3Features?.hasMediaOverlay == true { return book }
        if counterpart?.epub3Features?.hasMediaOverlay == true { return counterpart }
        return nil
    }

    private var offersReadAndListen: Bool {
        prominent && (counterpart != nil || readAloudBook != nil)
    }

    var body: some View {
        NavigationLink {
            BookDetailScreen(book: book)
        } label: {
            VStack(alignment: .leading, spacing: prominent ? 16 : 12) {
                percentBar
                HStack(alignment: .top, spacing: prominent ? 18 : 14) {
                    CoverTile(book: book, width: coverHeight / book.hearthCoverRatio, badges: false, corner: prominent ? 12 : 8)
                    details
                }
                positionBar
                    .padding(.trailing, prominent ? 0 : 56)
                if prominent {
                    heroActions.hidden()
                }
            }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { backdrop }
            .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .strokeBorder(hearth.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(accessibilitySummary)
        .overlay(alignment: prominent ? .bottom : .bottomTrailing) {
            if prominent {
                heroActions.padding(padding)
            } else {
                playButton.padding(10)
            }
        }
        .task(id: book.stableId) {
            tint = await AmbientColorStore.shared.resolve(for: book)
            if isEbook {
                pageTotal = await ReadingStatsTracker.shared.currentSnapshot().perBook[book.id]?.totalPages
            }
            if prominent, book.mediaType != .podcast {
                counterpart = await engine.library.detailSnapshot(for: book, current: nil).counterpart
            }
        }
    }

    private var percentBar: some View {
        VStack(spacing: 6) {
            Ribbon(progress: fraction, tint: tint, ticks: prominent ? chapterTicks : [], height: prominent ? 4 : 3)
            HStack(spacing: 12) {
                Text(book.isFinished ? "Finished" : "\(percent)% complete")
                    .foregroundStyle(hearth.text)
                Spacer(minLength: 0)
                if let chapterTitle {
                    Text(chapterTitle)
                        .foregroundStyle(hearth.textSecondary)
                        .truncationMode(.tail)
                }
            }
            .font(.hearthUI(prominent ? 12 : 10, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    private var chapterTicks: [Double] {
        guard !isEbook, let chapters = book.chapters, chapters.count > 1, let duration, duration > 0 else { return [] }
        return chapters.dropFirst().map { $0.start / duration }
    }

    private var positionReading: (label: String, detail: String?, fraction: Double) {
        if isEbook {
            if let total = pageTotal, total > 0 {
                let page = min(total, max(1, Int((fraction * Double(total)).rounded(.up))))
                return ("Page \(page) of \(total)", "\(total - page) left", Double(page) / Double(total))
            }
            if let locatorPosition {
                return ("Page \(locatorPosition)", nil, fraction)
            }
            return ("Pages appear after first open", nil, fraction)
        }
        guard let duration, duration > 0 else { return (HearthFormat.clock(position), nil, fraction) }
        return (
            "\(HearthFormat.clock(position)) / \(HearthFormat.clock(duration))",
            "-" + HearthFormat.clock(max(duration - position, 0)),
            fraction
        )
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(book.title)
                .font(.hearthDisplay(prominent ? 22 : 17, weight: prominent ? .bold : .semibold))
                .foregroundStyle(hearth.text)
                .lineLimit(prominent ? 3 : 2)
                .multilineTextAlignment(.leading)
            if let byline {
                Text(byline)
                    .font(.hearthUI(prominent ? 14 : 12, weight: .medium))
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(sourceLabel)
                .font(.hearthUI(prominent ? 11 : 10, weight: .semibold))
                .foregroundStyle(hearth.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: coverHeight, maxHeight: coverHeight, alignment: .topLeading)
    }

    private var positionBar: some View {
        let reading = positionReading
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(reading.label)
                    .foregroundStyle(hearth.text)
                    .fixedSize()
                Spacer(minLength: 0)
                if let detail = reading.detail {
                    Text(detail)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize()
                }
            }
            Text(reading.label)
                .foregroundStyle(hearth.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.hearthUI(prominent ? 13 : 11, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, prominent ? 14 : 12)
        .frame(maxWidth: .infinity, minHeight: prominent ? 36 : 30)
        .background(alignment: .leading) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    hearth.bg.opacity(0.55)
                    tint.opacity(0.35)
                        .frame(width: geo.size.width * reading.fraction)
                }
            }
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(hearth.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private var heroActions: some View {
        if offersReadAndListen {
            HStack(spacing: 10) {
                if isEbook {
                    actionButton("Read", systemImage: "book", filled: true, action: read)
                    actionButton("Listen", systemImage: "play.fill", filled: false, action: listen)
                } else {
                    actionButton("Listen", systemImage: "play.fill", filled: true, action: listen)
                    actionButton("Read", systemImage: "book", filled: false, action: read)
                }
            }
        } else {
            EmberButton(title: continueTitle, systemImage: isEbook ? "book" : "play.fill", tint: tint) {
                engine.playback.play(book)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionButton(_ title: String, systemImage: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.hearthUI(15, weight: .semibold))
                Text(title)
                    .font(.hearthUI(16, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(filled ? HearthPalette.readableForeground(on: tint, dark: hearth.onEmber) : hearth.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background {
                if filled {
                    HearthChromeBackground(shape: .capsule, fill: tint, tint: tint)
                } else {
                    HearthChromeBackground(shape: .capsule, fill: hearth.bgElevated, stroke: hearth.hairline, tint: hearth.bgElevated)
                }
            }
        }
        .buttonStyle(PressableStyle())
    }

    private var continueTitle: String {
        if fraction > 0.001 { return "Continue" }
        if isEbook { return "Start reading" }
        return book.isPodcastEpisode ? "Play episode" : "Start listening"
    }

    private func listen() {
        if !isEbook {
            engine.playback.play(book)
        } else if let counterpart {
            engine.playback.play(counterpart)
        } else if let readAloudBook {
            engine.playback.playAlignedReadAloud(readAloudBook)
        }
    }

    private func read() {
        if isEbook {
            engine.playback.openEbook(book)
        } else if let counterpart {
            engine.playback.openEbook(counterpart)
        }
    }

    private var playButton: some View {
        Button {
            engine.playback.play(book)
        } label: {
            Image(systemName: isEbook ? "book.fill" : "play.fill")
                .font(.hearthUI(16, weight: .bold))
                .foregroundStyle(HearthPalette.readableForeground(on: tint, dark: hearth.onEmber))
                .frame(width: 44, height: 44)
                .background(Circle().fill(tint))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(isEbook ? "Read \(book.title)" : "Listen to \(book.title)")
    }

    private var backdrop: some View {
        ZStack {
            hearth.bgElevated
            CachedAsyncCoverImage(
                url: book.coverURL,
                fallbackColor: "Blue",
                headers: CachedAsyncCoverImage.authHeaders(for: book),
                book: book
            )
            .scaleEffect(1.4)
            .blur(radius: 40, opaque: true)
            hearth.bg.opacity(0.55)
            if prominent {
                EmberGlow(tint: tint, isBreathing: player.isPlaying, intensity: 0.45)
            }
            LinearGradient(
                colors: [tint.opacity(0.2), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private var accessibilitySummary: String {
        var parts = [book.title]
        if let byline { parts.append(byline) }
        parts.append("\(percent) percent")
        parts.append(positionReading.label)
        if let chapterTitle { parts.append(chapterTitle) }
        return parts.joined(separator: ", ")
    }
}
