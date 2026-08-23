import SwiftUI

struct AdminKavitaHistoryScreen: View {
    let model: AdminKavitaModel

    @Environment(\.hearth) private var hearth

    @State private var entries: [KavitaProvider.HistoryEntry] = []
    @State private var page = 1
    @State private var exhausted = false
    @State private var isLoading = false
    @State private var unavailable = false

    private static let pageSize = 40

    var body: some View {
        AdminSubScreen(overline: model.connection.name, title: "Reading history") {
            if unavailable {
                AdminEmptyText("This Kavita server doesn't keep a session history.")
            } else if entries.isEmpty {
                AdminEmptyText(isLoading ? "Turning back the pages…" : "No reading sessions in this window.")
            } else {
                SourcesCard {
                    Overline("Sessions")
                    HStack(alignment: .top) {
                        AdminStat(value: "\(entries.count)", label: "Loaded")
                        AdminStat(value: AdminFormat.hours(totalSeconds), label: "Time")
                        AdminStat(value: totalPages.formatted(), label: "Pages")
                    }
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        SourcesCard {
                            row(entry)
                        }
                        .onAppear {
                            guard entry.id == entries.last?.id else { return }
                            Task { await loadMore() }
                        }
                    }
                }
                if isLoading {
                    AdminLoadingRow("Turning the page…")
                }
            }
        }
        .task {
            guard entries.isEmpty, !unavailable else { return }
            await loadMore()
        }
    }

    private var totalSeconds: Double {
        entries.reduce(0) { $0 + Double($1.durationSeconds) }
    }

    private var totalPages: Int {
        entries.reduce(0) { $0 + $1.pagesRead }
    }

    private func row(_ entry: KavitaProvider.HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.seriesName ?? "Series #\(entry.seriesId)")
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(AdminFormat.hours(Double(entry.durationSeconds)))
                    .font(.hearthUI(13, weight: .semibold))
                    .foregroundStyle(hearth.ember)
            }
            HStack(spacing: 6) {
                if let day = entry.day {
                    Text(day.formatted(.dateTime.day().month(.abbreviated).year()))
                }
                if let library = entry.libraryName, !library.isEmpty {
                    Text("· \(library)")
                }
            }
            .font(.hearthCaption)
            .foregroundStyle(hearth.textSecondary)
            .lineLimit(1)
            HStack(spacing: 6) {
                if entry.pagesRead > 0 { AdminTag(text: "\(entry.pagesRead) pages") }
                if entry.wordsRead > 0 { AdminTag(text: "\(entry.wordsRead.formatted()) words") }
            }
        }
    }

    private func loadMore() async {
        guard let provider = model.provider, !isLoading, !exhausted else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await provider.fetchReadingHistory(page: page, pageSize: Self.pageSize, days: model.range.days)
            let known = Set(entries.map(\.id))
            let fresh = fetched.filter { !known.contains($0.id) }
            entries.append(contentsOf: fresh)
            exhausted = fetched.count < Self.pageSize || fresh.isEmpty
            page += 1
        } catch KavitaProvider.InsightsError.unavailable {
            unavailable = true
            exhausted = true
        } catch {
            exhausted = true
        }
    }
}
