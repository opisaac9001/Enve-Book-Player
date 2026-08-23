import Combine
import SwiftUI

struct CompletionCenterScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var snapshot = JournalCompletionSnapshot.empty
    @State private var loaded = false

    private static let refreshSignal: AnyPublisher<Void, Never> = Publishers.Merge(
        NotificationCenter.default.publisher(for: .bookStoreDidChange).map { _ in () },
        NotificationCenter.default.publisher(for: .bookProgressDidChange).map { _ in () }
    )
    .throttle(for: .seconds(2), scheduler: DispatchQueue.main, latest: true)
    .eraseToAnyPublisher()

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    JournalScreenHeader(overline: "Reading milestones", title: "Finish Line")
                        .padding(.horizontal, 24)

                    if !snapshot.almostFinished.isEmpty {
                        almostFinished
                    }

                    if !snapshot.recentlyFinished.isEmpty {
                        recentlyFinished
                    }

                    if loaded && snapshot.almostFinished.isEmpty && snapshot.recentlyFinished.isEmpty {
                        JournalQuietNote(text: "Books nearing the end, and every finish after them, will gather here.")
                            .padding(.horizontal, 24)
                            .padding(.top, 20)
                    }
                }
                .hearthReadableFrame(width: geo.size.width, maximum: HearthAdaptive.wideReadableWidth)
                .padding(.bottom, mantelInset + 16)
            }
            .scrollIndicators(.hidden)
        }
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
        .onReceive(Self.refreshSignal) { _ in
            Task { await load() }
        }
    }

    private var almostFinished: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Almost Finished")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(snapshot.almostFinished, id: \.stableId) { book in
                        NavigationLink {
                            BookDetailScreen(book: book)
                        } label: {
                            CompletionCoverCard(book: book)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var recentlyFinished: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Recently Finished")
            LazyVStack(spacing: 0) {
                ForEach(snapshot.recentlyFinished) { entry in
                    NavigationLink {
                        BookDetailScreen(book: entry.book)
                    } label: {
                        CompletionHistoryRow(entry: entry)
                    }
                    .buttonStyle(PressableStyle())

                    if entry.id != snapshot.recentlyFinished.last?.id {
                        Rectangle()
                            .fill(hearth.hairline)
                            .frame(height: 1)
                            .padding(.leading, 86)
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func load() async {
        snapshot = await engine.journal.completionSnapshot()
        loaded = true
    }
}

private struct CompletionCoverCard: View {
    let book: Book

    @Environment(\.hearth) private var hearth

    private let width: CGFloat = 118

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            ShelfCoverCell(book: book, width: width)
            Text(book.title)
                .font(.hearthUI(13, weight: .semibold))
                .foregroundStyle(hearth.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(progressLine)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .center)
        .accessibilityElement(children: .combine)
    }

    private var progressLine: String {
        let progress = JournalEngine.completionProgress(for: book)
        if book.mediaType != .ebook, let duration = book.duration, duration > 0 {
            return HearthFormat.remaining(max(0, duration - book.currentTime))
        }
        return "\(Int((progress * 100).rounded()))% read"
    }
}

private struct CompletionHistoryRow: View {
    let entry: JournalCompletionEntry

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 14) {
            CoverTile(book: entry.book, width: 54, showsProgress: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.book.title)
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                Text(authorLine)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(entry.completedAt, format: .dateTime.month(.abbreviated).day())
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.book.title), finished \(entry.completedAt.formatted(date: .abbreviated, time: .omitted))")
    }

    private var authorLine: String {
        let author = entry.book.author?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let author, !author.isEmpty { return author }
        return entry.book.mediaType.displayName
    }
}
