import Foundation
import Observation

enum AdminKavitaRange: String, CaseIterable, Identifiable {
    case month = "30 days"
    case quarter = "90 days"
    case year = "Year"

    var id: String { rawValue }

    var days: Int {
        switch self {
        case .month: 30
        case .quarter: 90
        case .year: 365
        }
    }
}

@MainActor
@Observable
final class AdminKavitaModel {
    let connection: ServerConnection

    private(set) var account: KavitaProvider.Account?
    private(set) var profileBar: KavitaProvider.ProfileBar?
    private(set) var totals: KavitaProvider.ReadTotals?
    private(set) var pace: KavitaProvider.ReadingPace?
    private(set) var totalReads: Int?
    private(set) var dailySeconds: [String: TimeInterval] = [:]
    private(set) var weekdays: [KavitaProvider.IntCount] = []
    private(set) var hours: [KavitaProvider.IntCount] = []
    private(set) var genres: [KavitaProvider.StringCount] = []
    private(set) var authors: [KavitaProvider.FavoriteAuthor] = []
    private(set) var recentHistory: [KavitaProvider.HistoryEntry] = []

    private(set) var range: AdminKavitaRange = .year
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var statsUnavailable = false
    var error: String?

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(connection: ServerConnection) {
        self.connection = connection
    }

    var provider: KavitaProvider? {
        AppState.shared.getProvider(connection.id) as? KavitaProvider
    }

    var streak: Int { JournalStats.streak(dailySeconds) }

    var activeDays: Int { dailySeconds.values.filter { $0 > 0 }.count }

    var favoriteWeekday: String? {
        guard let best = weekdays.max(by: { $0.count < $1.count }), best.count > 0 else { return nil }
        let symbols = Calendar.current.weekdaySymbols
        let index = ((best.value % 7) + 7) % 7
        return symbols.indices.contains(index) ? symbols[index] : nil
    }

    var peakHour: String? {
        let calendar = Calendar.current
        guard let best = hours.max(by: { $0.count < $1.count }), best.count > 0,
            let date = calendar.date(byAdding: .hour, value: best.value, to: calendar.startOfDay(for: .now))
        else {
            return nil
        }
        return date.formatted(.dateTime.hour())
    }

    func select(range newRange: AdminKavitaRange) {
        guard newRange != range else { return }
        range = newRange
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    func refresh() async {
        loadTask?.cancel()
        let task = Task { await load() }
        loadTask = task
        await task.value
    }

    private func load() async {
        guard let provider else {
            error = "This source has no live connection. Open it from its source page first."
            hasLoaded = true
            return
        }

        isLoading = true
        error = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            account = try await provider.fetchAccount()
        } catch KavitaProvider.InsightsError.unavailable {
            statsUnavailable = true
            return
        } catch {
            self.error = "Kavita would not say who you are. Check the sign-in and try again."
            return
        }
        guard let userId = account?.id, !Task.isCancelled else { return }

        let days = range.days
        do {
            profileBar = try await provider.fetchProfileBar(userId: userId, days: days)
            statsUnavailable = false
        } catch KavitaProvider.InsightsError.unavailable {
            statsUnavailable = true
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Kavita would not share your statistics: \(error.localizedDescription)"
            return
        }

        async let totalsTask = provider.fetchReadTotals(userId: userId)
        async let bookPaceTask = provider.fetchReadingPace(userId: userId, days: days, booksOnly: true)
        async let comicPaceTask = provider.fetchReadingPace(userId: userId, days: days, booksOnly: false)
        async let readsTask = provider.fetchTotalReads(userId: userId)
        let loadedTotals = try? await totalsTask
        let bookPace = try? await bookPaceTask
        let comicPace = try? await comicPaceTask
        let reads = try? await readsTask
        guard !Task.isCancelled else { return }
        totals = loadedTotals
        pace = (bookPace ?? .zero).merged(with: comicPace ?? .zero)
        totalReads = reads

        let year = Calendar.current.component(.year, from: .now)
        async let activityTask = provider.fetchReadingActivity(userId: userId, year: year)
        async let weekdayTask = provider.fetchDayBreakdown(userId: userId)
        async let hourTask = provider.fetchHourBreakdown(userId: userId, days: days)
        async let genreTask = provider.fetchGenreBreakdown(userId: userId, days: days)
        async let authorTask = provider.fetchFavoriteAuthors(userId: userId, days: days)
        async let historyTask = provider.fetchReadingHistory(page: 1, pageSize: 10, days: days)
        let activity = try? await activityTask
        let weekday = try? await weekdayTask
        let hour = try? await hourTask
        let genre = try? await genreTask
        let author = try? await authorTask
        let history = try? await historyTask
        guard !Task.isCancelled else { return }
        dailySeconds = activity ?? [:]
        weekdays = weekday ?? []
        hours = hour ?? []
        genres = genre ?? []
        authors = (author ?? []).sorted { $0.totalChaptersRead > $1.totalChaptersRead }
        recentHistory = history ?? []
    }
}
