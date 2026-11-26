#if os(iOS)
import SwiftUI

enum HearthClubDestination: Identifiable {
    case all, club(String)

    var id: String {
        switch self {
        case .all: "all"
        case .club(let id): id
        }
    }
}

struct HearthClubBooks: View {
    let store: ClubsStore
    let session: ProfileSession
    let open: (HearthClubDestination) -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        if store.account != nil {
            let current = store.clubSummaries.filter { $0.currentTitle != nil }
            if current.isEmpty {
                ShelfHeader(title: "Book Clubs", actionTitle: "All clubs") { open(.all) }
            } else {
                shelf(current)
            }
        }
    }

    private func shelf(_ clubs: [ClubSummary]) -> some View {
        let width: CGFloat = 104
        let ratio = max(1.45, clubs.compactMap { linkedBook(for: $0)?.hearthCoverRatio }.max() ?? 0)
        return VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Book Club Books", actionTitle: "All clubs") { open(.all) }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(clubs) { club in
                        Button {
                            open(.club(club.id))
                        } label: {
                            VStack(spacing: 6) {
                                cover(for: club, width: width, ratio: ratio)
                                Text(club.currentTitle ?? "")
                                    .font(.hearthDisplay(14, weight: .medium))
                                    .foregroundStyle(hearth.text)
                                    .lineLimit(2)
                                Text(club.name)
                                    .font(.hearthUI(12))
                                    .foregroundStyle(hearth.textSecondary)
                                    .lineLimit(2)
                                if let next = club.nextCheckpoint {
                                    VStack(spacing: 2) {
                                        Text(next.label)
                                            .font(.hearthUI(12, weight: .semibold))
                                            .foregroundStyle(hearth.ember)
                                            .lineLimit(2)
                                            .accessibilityLabel("Next checkpoint, \(next.label)")
                                        if let dueAt = next.dueAt {
                                            Text("Due \(dueAt, format: .dateTime.month(.abbreviated).day())")
                                                .font(.hearthUI(11))
                                                .foregroundStyle(hearth.textSecondary)
                                        }
                                    }
                                    .padding(.top, 3)
                                }
                            }
                            .multilineTextAlignment(.center)
                            .frame(width: width)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("clubs-hearth-book-\(club.id)")
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("hearth-book-club-books")
    }

    @ViewBuilder
    private func cover(for club: ClubSummary, width: CGFloat, ratio: CGFloat) -> some View {
        if let book = linkedBook(for: club) {
            ShelfCoverCell(book: book, width: width, cellRatio: ratio, showsProgress: false)
                .accessibilityHidden(true)
        } else {
            VStack(spacing: 9) {
                Image(systemName: "book.closed")
                    .font(.hearthUI(25))
                    .foregroundStyle(hearth.ember)
                if let author = club.currentAuthor, !author.isEmpty {
                    Text(author)
                        .font(.hearthUI(11, weight: .medium))
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(2)
                }
            }
            .padding(8)
            .frame(width: width, height: width * 1.45)
            .background(hearth.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(hearth.hairline)
            }
            .frame(width: width, height: width * ratio, alignment: .bottom)
            .accessibilityHidden(true)
        }
    }

    private func linkedBook(for club: ClubSummary) -> Book? {
        guard let readID = club.currentReadID, let copy = store.copy(for: readID) else { return nil }
        return session.appState.bookInMemory(uniqueId: copy.bookID)
    }
}
#endif
