import SwiftUI

struct JournalReadingStatsScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var model = JournalReadingStatsModel()
    @State private var loaded = false
    @State private var countsByPages = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                JournalScreenHeader(overline: "The reading ledger", title: "Reading")

                if !loaded {
                    JournalLoadingNote(text: "Counting the pages…")
                } else if model.snapshot.totalSecondsRead <= 0 {
                    JournalQuietNote(text: "No reading on the record yet. An open book starts the count.")
                } else {
                    allTime
                    levelCard
                    statGrid
                    profileCard
                    honorsCard
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
        JournalCard("All-time reading") {
            JournalAllTimeFigure(seconds: model.snapshot.totalSecondsRead)
            Text(allTimeCaption)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
    }

    private var allTimeCaption: String {
        var caption = "\(JournalStatsFormat.hours(model.snapshot.totalHoursRead)) all told"
        if model.totalPages > 0 {
            caption += " · \(model.totalPages.formatted()) pages, give or take"
        }
        return caption
    }

    private var levelCard: some View {
        let leveling = JournalLeveling.level(for: model.totalXP)
        return JournalCard("Standing") {
            JournalLevelCard(
                level: leveling.level,
                rank: JournalLeveling.readingRank(for: leveling.level),
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
                JournalStatTile(value: "\(model.snapshot.totalSessions)", label: "Sittings")
                JournalStatTile(value: "\(model.snapshot.streak.current)", label: "Nights running")
                if let wpm = model.averageWordsPerMinute {
                    JournalStatTile(value: "\(wpm) wpm", label: "Usual pace")
                } else {
                    JournalStatTile(value: "\(model.snapshot.streak.longest)", label: "Longest run")
                }
            }
        }
    }

    private var profileCard: some View {
        JournalCard("Reader profile") {
            VStack(spacing: 14) {
                JournalMeterRow(label: "Consistency", detail: "\(model.consistencyScore)", fraction: Double(model.consistencyScore) / 100)
                JournalMeterRow(label: "Finisher", detail: "\(model.finisherScore)", fraction: Double(model.finisherScore) / 100)
                JournalMeterRow(label: "Explorer", detail: "\(model.explorerScore)", fraction: Double(model.explorerScore) / 100)
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

    private var topBooksCard: some View {
        JournalCard("The books that held you") {
            HStack(spacing: 8) {
                HearthChip(title: "Hours", isSelected: !countsByPages) { countsByPages = false }
                HearthChip(title: "Pages", isSelected: countsByPages) { countsByPages = true }
            }
            let books = Array((countsByPages ? model.topBooksByPages : model.topBooksByHours).prefix(8))
            if books.isEmpty {
                JournalQuietNote(text: "Time in a book will place it here.")
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
                                Text(
                                    countsByPages
                                        ? "\(entry.pages.formatted()) pp"
                                        : JournalStatsFormat.hours(entry.hours)
                                )
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
