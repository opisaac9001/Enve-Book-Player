import Foundation
import Observation

@MainActor
@Observable
final class AdminGrimmoryModel {
    let connection: ServerConnection

    var currentUser: GrimmoryUser?
    var libraries: [GrimmoryLibrarySummary] = []
    var shelves: [GrimmoryShelf] = []
    var readingSessions: [GrimmoryReadingSessionEntry] = []
    var recentBooks: [GrimmoryRecentBook] = []
    var users: [GrimmoryManagedUser] = []
    var magicShelves: [GrimmoryMagicShelf] = []

    var isAuthorized = false
    var isLoading = false
    var hasLoaded = false
    var error: String?
    var successMessage: String?

    init(connection: ServerConnection) {
        self.connection = connection
    }

    private var provider: BookloreProvider? {
        AppState.shared.getProvider(connection.id) as? BookloreProvider
    }

    func refreshAll() async {
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
            _ = try await provider.validateConnection()
            isAuthorized = true
        } catch {
            self.error = "The server would not say who you are. Check the sign-in and try again."
            isAuthorized = false
            return
        }

        currentUser = (try? await provider.fetchCurrentUser()) ?? currentUser
        if let libs = try? await provider.fetchLibraries() {
            libraries = libs.map { GrimmoryLibrarySummary(id: $0.id, name: $0.name, type: $0.type) }
        }
        shelves = (try? await provider.fetchGrimmoryShelves()) ?? shelves
        readingSessions = (try? await provider.fetchReadingSessions(limit: 20)) ?? readingSessions
        recentBooks = (try? await provider.fetchRecentBooks(limit: 10)) ?? recentBooks
        if currentUser?.isAdmin == true {
            await adminFetchUsers(provider: provider)
        }
        magicShelves = (try? await provider.fetchMagicShelves()) ?? magicShelves
    }

    private func adminFetchUsers(provider: BookloreProvider) async {
        guard let fetched = try? await provider.fetchUsers() else { return }
        var enriched: [GrimmoryManagedUser] = []
        enriched.reserveCapacity(fetched.count)

        for user in fetched {
            enriched.append((try? await provider.fetchUser(id: user.id)) ?? user)
        }
        users = enriched
    }

    private func adminSyncCollections(provider: BookloreProvider) async {
        guard let refreshed = try? await provider.fetchCollections(libraryId: nil) else { return }
        LibraryCatalogCoordinator.shared.commitServerCollectionSnapshot(refreshed, from: provider)
    }

    func createUser(_ request: GrimmoryCreateUserRequest) async {
        guard let provider else { return }
        do {
            try await provider.createUser(request)
            successMessage = "\(request.username) now has an account."
            await adminFetchUsers(provider: provider)
        } catch {
            self.error = "The account could not be created: \(error.localizedDescription)"
        }
    }

    func updateUser(id: Int, request: GrimmoryUpdateUserRequest) async {
        guard let provider else { return }
        do {
            try await provider.updateUser(id: id, request: request)
            successMessage = "The account was updated."
            await adminFetchUsers(provider: provider)
        } catch {
            self.error = "The account could not be updated: \(error.localizedDescription)"
        }
    }

    func deleteUser(id: Int) async {
        guard let provider else { return }
        do {
            try await provider.deleteUser(id: id)
            successMessage = "The account was removed."
            await adminFetchUsers(provider: provider)
        } catch {
            self.error = "The account could not be removed: \(error.localizedDescription)"
        }
    }

    func fetchUser(id: Int) async throws -> GrimmoryManagedUser {
        guard let provider else { throw ProviderError.notImplemented }
        return try await provider.fetchUser(id: id)
    }

    func changeUserPassword(userId: Int, newPassword: String) async {
        guard let provider else { return }
        do {
            try await provider.changeUserPassword(userId: userId, newPassword: newPassword)
            successMessage = "The password was changed."
        } catch {
            self.error = "The password could not be changed: \(error.localizedDescription)"
        }
    }

    func createShelf(name: String, icon: String?, isPublic: Bool) async {
        guard let provider else { return }
        do {
            _ = try await provider.createShelf(name: name, icon: icon, isPublic: isPublic)
            successMessage = "“\(name)” is on the wall."
            shelves = (try? await provider.fetchGrimmoryShelves()) ?? shelves
            await adminSyncCollections(provider: provider)
        } catch {
            self.error = "The shelf could not be created: \(error.localizedDescription)"
        }
    }

    func updateShelf(id: Int, name: String, icon: String?, isPublic: Bool) async {
        guard let provider else { return }
        do {
            try await provider.updateShelf(id: id, name: name, icon: icon, isPublic: isPublic)
            successMessage = "The shelf was updated."
            shelves = (try? await provider.fetchGrimmoryShelves()) ?? shelves
            await adminSyncCollections(provider: provider)
        } catch {
            self.error = "The shelf could not be updated: \(error.localizedDescription)"
        }
    }

    func deleteShelf(id: Int) async {
        guard let provider else { return }
        do {
            try await provider.deleteShelf(id: id)
            successMessage = "The shelf was taken down."
            shelves = (try? await provider.fetchGrimmoryShelves()) ?? shelves
            await adminSyncCollections(provider: provider)
        } catch {
            self.error = "The shelf could not be deleted: \(error.localizedDescription)"
        }
    }

    func saveMagicShelf(_ shelf: GrimmoryMagicShelf) async {
        guard let provider else { return }
        do {
            _ = try await provider.saveMagicShelf(shelf)
            successMessage = "“\(shelf.name)” will gather its own books."
            magicShelves = (try? await provider.fetchMagicShelves()) ?? magicShelves
            await adminSyncCollections(provider: provider)
        } catch {
            self.error = "The magic shelf could not be saved: \(error.localizedDescription)"
        }
    }

    func deleteMagicShelf(id: Int) async {
        guard let provider else { return }
        do {
            try await provider.deleteMagicShelf(id: id)
            successMessage = "The magic shelf was dispelled."
            magicShelves = (try? await provider.fetchMagicShelves()) ?? magicShelves
            await adminSyncCollections(provider: provider)
        } catch {
            self.error = "The magic shelf could not be deleted: \(error.localizedDescription)"
        }
    }
}

@MainActor
@Observable
final class AdminGrimmoryStatsModel {
    let connection: ServerConnection

    var isLoading = false
    var hasLoaded = false
    var error: String?

    var totalBooks = 0
    var booksFinished = 0
    var booksInProgress = 0
    var booksNotStarted = 0
    var booksAbandoned = 0

    var totalReadingSeconds = 0
    var sessionsCount = 0
    var averageSessionSeconds = 0

    var favoriteAuthors: [(author: String, count: Int)] = []
    var readingTrend: [AdminGrimmoryDailyReading] = []
    var recentSessions: [GrimmoryReadingSessionEntry] = []
    var topBooks: [GrimmoryRecentBook] = []

    var weeklyReadingSeconds = 0
    var monthlyReadingSeconds = 0
    var currentStreak = 0

    struct AdminGrimmoryDailyReading: Identifiable {
        let id: String
        let date: Date
        let minutes: Int
        let sessions: Int
    }

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func loadStats() async {
        guard let provider = AppState.shared.getProvider(connection.id) as? BookloreProvider else {
            error = "This source has no live connection."
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
            _ = try await provider.validateConnection()
        } catch {
            self.error = "The server would not say who you are."
            return
        }

        let allBooks = (try? await provider.fetchAllBooksForStats()) ?? []
        let sessions = (try? await provider.fetchReadingSessions(limit: 200)) ?? []

        adminComputeBookStats(from: allBooks)
        adminComputeSessionStats(from: sessions)
        adminComputeAuthorStats(from: allBooks)
        adminComputeReadingTrend(from: sessions)
        adminComputeStreak(from: sessions)
        recentSessions = Array(sessions.prefix(10))
        topBooks =
            allBooks
            .filter { ($0.readProgress ?? 0) > 0 }
            .sorted { ($0.readProgress ?? 0) > ($1.readProgress ?? 0) }
            .prefix(6)
            .map { $0 }
    }

    private func adminComputeBookStats(from books: [GrimmoryRecentBook]) {
        totalBooks = books.count
        booksFinished = books.filter { adminIsFinished($0) }.count
        booksAbandoned = books.filter { $0.readStatus?.lowercased() == "abandoned" }.count
        booksInProgress = books.filter { adminIsInProgress($0) }.count
        booksNotStarted = books.filter { adminIsNotStarted($0) }.count
    }

    private func adminComputeSessionStats(from sessions: [GrimmoryReadingSessionEntry]) {
        sessionsCount = sessions.count
        totalReadingSeconds = sessions.reduce(0) { $0 + ($1.durationSeconds ?? 0) }
        averageSessionSeconds = sessionsCount > 0 ? totalReadingSeconds / sessionsCount : 0

        let calendar = Calendar.current
        let now = Date()
        weeklyReadingSeconds = sessions.filter {
            guard let date = adminParseDate($0.startTime) else { return false }
            return calendar.dateComponents([.day], from: date, to: now).day ?? 999 < 7
        }.reduce(0) { $0 + ($1.durationSeconds ?? 0) }
        monthlyReadingSeconds = sessions.filter {
            guard let date = adminParseDate($0.startTime) else { return false }
            return calendar.dateComponents([.day], from: date, to: now).day ?? 999 < 30
        }.reduce(0) { $0 + ($1.durationSeconds ?? 0) }
    }

    private func adminComputeAuthorStats(from books: [GrimmoryRecentBook]) {
        var counts: [String: Int] = [:]
        for book in books {
            if let author = book.author, !author.isEmpty {
                counts[author, default: 0] += 1
            }
        }
        favoriteAuthors =
            counts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { (author: $0.key, count: $0.value) }
    }

    private func adminComputeReadingTrend(from sessions: [GrimmoryReadingSessionEntry]) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var dailyMap: [String: (minutes: Int, sessions: Int, date: Date)] = [:]
        for offset in 0..<30 {
            guard let day = calendar.date(byAdding: .day, value: -29 + offset, to: today) else { continue }
            dailyMap[formatter.string(from: day)] = (0, 0, day)
        }
        for session in sessions {
            guard let date = adminParseDate(session.startTime) else { continue }
            let key = formatter.string(from: calendar.startOfDay(for: date))
            if var entry = dailyMap[key] {
                entry.minutes += (session.durationSeconds ?? 0) / 60
                entry.sessions += 1
                dailyMap[key] = entry
            }
        }
        readingTrend = dailyMap.sorted { $0.key < $1.key }.map { key, value in
            AdminGrimmoryDailyReading(id: key, date: value.date, minutes: value.minutes, sessions: value.sessions)
        }
    }

    private func adminComputeStreak(from sessions: [GrimmoryReadingSessionEntry]) {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var activeDays = Set<String>()
        for session in sessions {
            if let date = adminParseDate(session.startTime) {
                activeDays.insert(formatter.string(from: calendar.startOfDay(for: date)))
            }
        }

        var streak = 0
        var day = calendar.startOfDay(for: Date())
        while activeDays.contains(formatter.string(from: day)) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        currentStreak = streak
    }

    private func adminIsFinished(_ book: GrimmoryRecentBook) -> Bool {
        let status = book.readStatus?.lowercased() ?? ""
        return status == "read" || status == "completed" || status == "finished" || (book.readProgress ?? 0) >= 99
    }

    private func adminIsInProgress(_ book: GrimmoryRecentBook) -> Bool {
        let status = book.readStatus?.lowercased() ?? ""
        if adminIsFinished(book) || status == "abandoned" { return false }
        return (book.readProgress ?? 0) > 0 || status == "reading" || status == "in_progress"
    }

    private func adminIsNotStarted(_ book: GrimmoryRecentBook) -> Bool {
        let status = book.readStatus?.lowercased() ?? ""
        return (book.readProgress ?? 0) == 0
            && !["reading", "in_progress", "read", "completed", "finished", "abandoned"].contains(status)
    }

    private func adminParseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
