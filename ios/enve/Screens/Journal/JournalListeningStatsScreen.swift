import SwiftUI

struct JournalListeningStatsScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var model = JournalListeningStatsModel()
    @State private var loaded = false
    @State private var countsByBooks = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                JournalScreenHeader(overline: "The listening ledger", title: "Listening")

                if !loaded {
                    JournalLoadingNote(text: "Tallying the hours…")
                } else if model.snapshot.totalSeconds <= 0 {
                    JournalQuietNote(text: "Nothing on the record yet. The first hour opens the ledger.")
                } else {
                    allTime
                    levelCard
                    statGrid
                    profileCard
                    honorsCard
                    topAuthorsCard
                    topBooksCard
                    if !model.recentSessions.isEmpty {
                        recentCard
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .refreshable { await model.refresh() }
        .task {
            await model.refresh()
            loaded = true
        }
        .onAppear { model.startLiveUpdates() }
        .onDisappear { model.stopLiveUpdates() }
    }

    private var allTime: some View {
        JournalCard("All-time listening") {
            JournalAllTimeFigure(seconds: model.snapshot.totalSeconds)
            Text("\(JournalStatsFormat.hours(model.snapshot.totalHours)) all told")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
    }

    private var levelCard: some View {
        let leveling = JournalLeveling.level(for: model.totalXP)
        return JournalCard("Standing") {
            JournalLevelCard(
                level: leveling.level,
                rank: JournalLeveling.listeningRank(for: leveling.level),
                totalXP: model.totalXP,
                xpIntoLevel: leveling.xpIntoLevel,
                xpForNextLevel: leveling.xpForNextLevel,
                progress: leveling.progress
            )
        }
    }

    private var statGrid: some View {
        JournalCard {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 18) {
                JournalStatTile(value: JournalStatsFormat.hours(model.weeklyHours()), label: "This week")
                JournalStatTile(value: JournalStatsFormat.hours(model.monthlyHours()), label: "This month")
                JournalStatTile(value: "\(model.booksFinished)", label: "Books finished")
                JournalStatTile(value: "\(model.snapshot.totalSessions)", label: "Sessions")
                JournalStatTile(value: "\(model.snapshot.streak.current)", label: "Nights running")
                JournalStatTile(value: "\(model.snapshot.streak.longest)", label: "Longest run")
            }
        }
    }

    private var profileCard: some View {
        JournalCard("Reader profile") {
            VStack(spacing: 14) {
                JournalMeterRow(label: "Consistency", detail: "\(model.consistencyScore)", fraction: Double(model.consistencyScore) / 100)
                JournalMeterRow(label: "Finisher", detail: "\(model.finisherScore)", fraction: Double(model.finisherScore) / 100)
                JournalMeterRow(label: "Curator", detail: "\(model.curatorScore)", fraction: Double(model.curatorScore) / 100)
            }
        }
    }

    private var honorsCard: some View {
        JournalCard("Honors") {
            if model.badges.isEmpty {
                JournalQuietNote(text: "The first hour earns the first honor.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(model.badges) { badge in
                        JournalBadgeChip(badge: badge)
                    }
                }
            }
        }
    }

    private var topAuthorsCard: some View {
        JournalCard("The authors you return to") {
            HStack(spacing: 8) {
                HearthChip(title: "Hours", isSelected: !countsByBooks) { countsByBooks = false }
                HearthChip(title: "Books", isSelected: countsByBooks) { countsByBooks = true }
            }
            let authors = Array(model.topAuthors.prefix(8))
            if authors.isEmpty {
                JournalQuietNote(text: "No authors on the record yet.")
            } else {
                let peak = max(
                    countsByBooks ? Double(authors.map(\.books).max() ?? 0) : authors.map(\.hours).max() ?? 0,
                    0.001
                )
                VStack(spacing: 14) {
                    ForEach(Array(authors.enumerated()), id: \.offset) { index, author in
                        JournalMeterRow(
                            rank: index + 1,
                            label: author.name,
                            detail: countsByBooks
                                ? "\(author.books) \(author.books == 1 ? "book" : "books")"
                                : JournalStatsFormat.hours(author.hours),
                            fraction: (countsByBooks ? Double(author.books) : author.hours) / peak
                        )
                    }
                }
            }
        }
    }

    private var topBooksCard: some View {
        JournalCard("Most kept company") {
            let books = Array(model.topBooks.prefix(8))
            if books.isEmpty {
                JournalQuietNote(text: "Time with a book will place it here.")
            } else {
                VStack(spacing: 14) {
                    ForEach(books) { entry in
                        NavigationLink {
                            BookDetailScreen(book: entry.book)
                        } label: {
                            HStack(spacing: 12) {
                                CoverTile(book: entry.book, width: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.book.title)
                                        .font(.hearthUI(15, weight: .medium))
                                        .foregroundStyle(hearth.text)
                                        .lineLimit(1)
                                    Text(entry.authorName)
                                        .font(.hearthCaption)
                                        .foregroundStyle(hearth.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(JournalStatsFormat.hours(entry.hours))
                                    .font(.hearthUI(13, weight: .semibold))
                                    .foregroundStyle(hearth.textSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
        }
    }

    private var recentCard: some View {
        JournalCard("Lately") {
            VStack(spacing: 14) {
                ForEach(model.recentSessions) { session in
                    JournalSessionRow(session: session, title: model.bookLookup[session.bookId]?.title)
                }
            }
        }
    }
}
