import Foundation
import Logging

class DiscoverService {

    static let shared = DiscoverService()
    private let discoverRegion = "us"

    private var cachedSections: [String: [DiscoverBook]] = [:]
    private var cacheTimestamps: [String: Date] = [:]
    private let cacheExpiration: TimeInterval = 3600

    private init() {}

    func fetchTrending() async throws -> [DiscoverBook] {
        if let cached = getCached(key: "trending") { return cached }

        let currentYear = Calendar.current.component(.year, from: Date())
        let queries = ["bestseller audiobook", "popular audiobook \(currentYear)", "audiobook thriller", "audiobook fiction"]
        var allBooks: [DiscoverBook] = []
        var lastError: Error?

        for query in queries {
            do {
                let audibleBooks = try await searchAudibleAudiobooks(term: query, limit: 12)
                allBooks.append(contentsOf: audibleBooks)
            } catch {
                lastError = error
                AppLogger.network.error("Trending query '\(query)' failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        if allBooks.isEmpty, let lastError {
            throw lastError
        }

        let unique = deduplicateBooks(allBooks).shuffled()
        let result = Array(unique.prefix(20))
        setCached(key: "trending", books: result)
        return result
    }

    func fetchBestsellers() async throws -> [DiscoverBook] {
        if let cached = getCached(key: "bestsellers") { return cached }

        let queries = [
            "James Patterson audiobook",
            "Stephen King audiobook",
            "Colleen Hoover audiobook",
            "Brandon Sanderson audiobook",
            "Rebecca Yarros audiobook",
        ]
        var allBooks: [DiscoverBook] = []
        var lastError: Error?

        for query in queries {
            do {
                let audibleBooks = try await searchAudibleAudiobooks(term: query, limit: 10)
                allBooks.append(contentsOf: audibleBooks)
            } catch {
                lastError = error
                AppLogger.network.error("Bestseller query '\(query)' failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        if allBooks.isEmpty, let lastError {
            throw lastError
        }

        let unique = deduplicateBooks(allBooks)
        let sorted = unique.sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
        let result = Array(sorted.prefix(20))
        setCached(key: "bestsellers", books: result)
        return result
    }

    func fetchNewReleases() async throws -> [DiscoverBook] {
        if let cached = getCached(key: "newReleases") { return cached }

        let currentYear = Calendar.current.component(.year, from: Date())
        let lastYear = currentYear - 1
        let queries = [
            "new audiobook \(currentYear)",
            "new release audiobook",
            "audiobook mystery \(lastYear)",
            "audiobook romance \(lastYear)",
            "audiobook science fiction \(lastYear)",
        ]
        var allBooks: [DiscoverBook] = []
        var lastError: Error?

        for query in queries {
            do {
                let audibleBooks = try await searchAudibleAudiobooks(term: query, limit: 12)
                allBooks.append(contentsOf: audibleBooks)
            } catch {
                lastError = error
                AppLogger.network.error("New releases query '\(query)' failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        if allBooks.isEmpty, let lastError {
            throw lastError
        }

        let unique = deduplicateBooks(allBooks)
        let sorted = unique.sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
        let result = Array(sorted.prefix(20))
        setCached(key: "newReleases", books: result)
        return result
    }

    func clearCache() {
        cachedSections.removeAll()
        cacheTimestamps.removeAll()
    }

    private func searchAudibleAudiobooks(term: String, limit: Int) async throws -> [DiscoverBook] {
        let results = try await AudibleService.shared.simpleSearch(
            query: term,
            numResults: min(50, max(1, limit)),
            countryCode: discoverRegion
        )

        return results.compactMap { result in
            let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let author = result.authors.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown Author"
            guard !title.isEmpty else { return nil }

            return DiscoverBook(
                id: "audible-\(result.asin)",
                title: title,
                author: author,
                narrator: result.narrators.first,
                artworkURL: result.coverUrl ?? "",
                description: result.description?.strippingHTMLTags(),
                releaseDate: parseAudibleDate(result.releaseDate),
                genre: nil,
                duration: TimeInterval(result.duration),
                price: nil,
                currency: nil,
                storeURL: nil,
                previewURL: nil,
                collectionId: stableCollectionId(from: result.asin)
            )
        }
    }

    private func parseAudibleDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: raw) { return date }

        let ymd = DateFormatter()
        ymd.locale = Locale(identifier: "en_US_POSIX")
        ymd.dateFormat = "yyyy-MM-dd"
        if let date = ymd.date(from: raw) { return date }

        let mdY = DateFormatter()
        mdY.locale = Locale(identifier: "en_US_POSIX")
        mdY.dateFormat = "MMM d, yyyy"
        return mdY.date(from: raw)
    }

    private func stableCollectionId(from key: String) -> Int {
        var value: Int64 = 5381
        for scalar in key.unicodeScalars {
            value = ((value << 5) &+ value) &+ Int64(scalar.value)
        }
        return Int(abs(value % 2_000_000_000))
    }

    private func getCached(key: String) -> [DiscoverBook]? {
        guard let timestamp = cacheTimestamps[key],
            Date().timeIntervalSince(timestamp) < cacheExpiration,
            let books = cachedSections[key]
        else {
            return nil
        }
        return books
    }

    private func setCached(key: String, books: [DiscoverBook]) {
        cachedSections[key] = books
        cacheTimestamps[key] = Date()
    }

    private func deduplicateBooks(_ books: [DiscoverBook]) -> [DiscoverBook] {
        var seen = Set<Int>()
        return books.filter { book in
            guard !seen.contains(book.collectionId) else { return false }
            seen.insert(book.collectionId)
            return true
        }
    }

}

extension String {
    func strippingHTMLTags() -> String {
        return
            self
            .replacingOccurrences(of: "<br\\s*/?>|<br>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#xa0;", with: " ")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
