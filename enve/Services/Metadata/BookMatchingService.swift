import Combine
import Foundation
import Logging

private struct IndexedLocalBook: Sendable {
    let book: Book
    let identity: CanonicalBookIdentity
}

private struct LocalIdentityCachePayload: Codable {
    let signature: UInt64
    let identitiesByUniqueId: [String: CanonicalBookIdentity]
    let updatedAt: Date
}

private func localIdentityCacheURL() -> URL {
    let caches =
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    return caches.appendingPathComponent("book_matching_identity_cache_v1.json")
}

private func identitySignature(for books: [Book]) -> UInt64 {
    var hasher = Hasher()
    hasher.combine(books.count)
    for book in books {
        hasher.combine(book.uniqueId)
        hasher.combine(book.title)
        hasher.combine(book.author ?? "")
        hasher.combine(Int(book.duration ?? 0))
        hasher.combine(book.series ?? "")
        hasher.combine(book.seriesNumber ?? -1)
    }
    return UInt64(bitPattern: Int64(hasher.finalize()))
}

private func loadIdentityCache(signature: UInt64) -> [String: CanonicalBookIdentity]? {
    let url = localIdentityCacheURL()
    guard let data = try? Data(contentsOf: url),
        let payload = try? JSONDecoder().decode(LocalIdentityCachePayload.self, from: data),
        payload.signature == signature
    else {
        return nil
    }
    return payload.identitiesByUniqueId
}

private func saveIdentityCache(signature: UInt64, identitiesByUniqueId: [String: CanonicalBookIdentity]) {
    let payload = LocalIdentityCachePayload(
        signature: signature,
        identitiesByUniqueId: identitiesByUniqueId,
        updatedAt: Date()
    )
    guard let data = try? JSONEncoder().encode(payload) else { return }
    try? data.write(to: localIdentityCacheURL(), options: [.atomic])
}

private func buildMatchResults(books: [Book], cloudRecords: [PlaybackStateRecord]) -> [BookMatchResult] {
    let signature = identitySignature(for: books)
    var identitiesByUniqueId = loadIdentityCache(signature: signature) ?? [:]
    identitiesByUniqueId.reserveCapacity(books.count)

    var didGenerateNewIdentity = false
    let indexedBooks = books.map { book in
        if let cachedIdentity = identitiesByUniqueId[book.uniqueId] {
            return IndexedLocalBook(book: book, identity: cachedIdentity)
        }

        let generatedIdentity = CanonicalBookIdentity(from: book)
        identitiesByUniqueId[book.uniqueId] = generatedIdentity
        didGenerateNewIdentity = true
        return IndexedLocalBook(book: book, identity: generatedIdentity)
    }

    if didGenerateNewIdentity || identitiesByUniqueId.count != books.count {
        saveIdentityCache(signature: signature, identitiesByUniqueId: identitiesByUniqueId)
    }

    let booksByNormalizedTitle = Dictionary(grouping: indexedBooks, by: { $0.identity.normalizedTitle })

    var results: [BookMatchResult] = []
    results.reserveCapacity(min(books.count, cloudRecords.count * 4))

    for cloudRecord in cloudRecords {
        let cloudIdentity = cloudRecord.toCanonicalIdentity()
        guard let candidates = booksByNormalizedTitle[cloudIdentity.normalizedTitle] else { continue }

        for candidate in candidates {
            let matchResult = candidate.identity.matches(cloudIdentity)
            if matchResult.isMatch {
                results.append(
                    BookMatchResult(
                        localBook: candidate.book,
                        cloudRecord: cloudRecord,
                        matchConfidence: matchResult.confidence
                    )
                )
            }
        }
    }

    return results
}

@MainActor
@Observable
final class BookMatchingService {
    static let shared = BookMatchingService()

    private(set) var isMatching = false
    private(set) var lastMatchDate: Date?
    private(set) var matchedBooksCount = 0

    @ObservationIgnored private let cloudKit = CloudKitProgressSync.shared
    @ObservationIgnored private let storageService = StorageService()

    private init() {}

    func matchAndUpdateProgress(books: [Book], autoUpdate: Bool = false) async -> [BookMatchResult] {
        guard !isMatching else {
            AppLogger.network.warning("Already matching, skipping")
            return []
        }

        isMatching = true
        defer { isMatching = false }

        let audiobooks = books.filter { $0.mediaType == .audiobook }
        AppLogger.network.info("Starting match for \(audiobooks.count) local audiobooks...")

        do {
            let cloudRecords = try await cloudKit.fetchAllRecords()

            if cloudRecords.isEmpty {
                AppLogger.network.info("No cloud records found - this may be the first device")
                return []
            }

            AppLogger.network.info("Found \(cloudRecords.count) cloud records")

            let results = buildMatchResults(books: audiobooks, cloudRecords: cloudRecords)

            for (index, result) in results.enumerated() {
                let hasLocalProgress = BookProgressStore.shared.loadProgress(for: result.localBook) != nil

                if autoUpdate {
                    await updateLocalProgressIfNeeded(book: result.localBook, cloudRecord: result.cloudRecord)
                } else if !hasLocalProgress {
                    await updateLocalProgressIfNeeded(book: result.localBook, cloudRecord: result.cloudRecord)
                }

                if index > 0 && index.isMultiple(of: 50) {
                    await Task.yield()
                }
            }

            matchedBooksCount = results.count
            lastMatchDate = Date()

            AppLogger.network.info("Matched \(results.count) books")

            return results

        } catch {
            AppLogger.network.error("Failed to match books: \(error)")
            return []
        }
    }

    func findCloudProgress(for book: Book) async -> PlaybackStateRecord? {
        guard book.mediaType == .audiobook else { return nil }
        let identity = CanonicalBookIdentity(from: book)
        let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)

        AppLogger.network.debug("Looking for cloud progress bookId=\(diagnosticID)")

        do {
            if let record = try await cloudKit.fetchProgress(for: identity, bypassCache: true) {
                AppLogger.network.debug("Found cloud progress=\(Int(record.playbackPosition))s bookId=\(diagnosticID)")
                return record
            }

            AppLogger.network.info("No exact match, trying fuzzy match...")

            cloudKit.invalidateCache()
            let allRecords = try await cloudKit.fetchAllRecords()

            if let match = findBestMatch(for: identity, in: allRecords) {
                AppLogger.network.debug("Found fuzzy progress=\(Int(match.playbackPosition))s bookId=\(diagnosticID)")
                return match
            }

            AppLogger.network.debug("No cloud progress found bookId=\(diagnosticID)")
            return nil

        } catch {
            AppLogger.network.error("Error finding cloud progress: \(error)")
            return nil
        }
    }

    private struct MatchCandidate {
        let book: Book
        let confidence: Double
    }

    private func findMatchingBooks(cloudIdentity: CanonicalBookIdentity, in books: [Book]) -> [MatchCandidate] {
        var matches: [MatchCandidate] = []

        for book in books {
            let localIdentity = CanonicalBookIdentity(from: book)
            let matchResult = localIdentity.matches(cloudIdentity)

            if matchResult.isMatch {
                matches.append(MatchCandidate(book: book, confidence: matchResult.confidence))
            }
        }

        matches.sort { $0.confidence > $1.confidence }

        return matches
    }

    private func findBestMatch(for identity: CanonicalBookIdentity, in records: [PlaybackStateRecord]) -> PlaybackStateRecord? {
        var bestMatch: (record: PlaybackStateRecord, confidence: Double)?

        for record in records {
            let recordIdentity = record.toCanonicalIdentity()
            let matchResult = identity.matches(recordIdentity)

            if matchResult.isMatch {
                if bestMatch == nil || matchResult.confidence > bestMatch!.confidence {
                    bestMatch = (record, matchResult.confidence)
                }
            }
        }

        return bestMatch?.record
    }

    private func updateLocalProgressIfNeeded(book: Book, cloudRecord: PlaybackStateRecord) async {
        let localProgress = BookProgressStore.shared.loadProgress(for: book)
        let localPosition = localProgress?.progress ?? 0
        let localTimestamp = localProgress.map { Date(timeIntervalSince1970: $0.lastUpdated) } ?? Date.distantPast

        let cloudIsNewer = cloudRecord.lastUpdated > localTimestamp
        let significantDifference = abs(cloudRecord.playbackPosition - localPosition) > 5.0

        if cloudIsNewer && significantDifference {
            AppLogger.network.debug(
                "Updating local progress bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(Int(localPosition))s -> \(Int(cloudRecord.playbackPosition))s"
            )

            BookProgressStore.shared.saveProgress(
                for: book,
                progress: cloudRecord.playbackPosition,
                duration: cloudRecord.duration > 0 ? Double(cloudRecord.duration) : (book.duration ?? 0)
            )

            BookProgressStore.shared.saveRecentlyPlayed(book)
        }
    }
}

struct BookMatchResult {
    let localBook: Book
    let cloudRecord: PlaybackStateRecord
    let matchConfidence: Double

    var shouldUpdateLocal: Bool {
        matchConfidence >= 0.7
    }

    var displayConfidence: String {
        switch matchConfidence {
        case 1.0: return "Exact Match"
        case 0.7..<1.0: return "High Confidence"
        case 0.5..<0.7: return "Medium Confidence"
        default: return "Low Confidence"
        }
    }
}
