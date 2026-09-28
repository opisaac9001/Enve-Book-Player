import Combine
import Foundation
import Logging

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

    func findCloudProgress(for book: Book) async -> PlaybackStateRecord? {
        guard book.mediaType == .audiobook else { return nil }
        let identity = CanonicalBookIdentity(from: book)
        let contentHash = CloudBookContentIdentity.hash(for: book)
        let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)

        AppLogger.network.debug("Looking for cloud progress bookId=\(diagnosticID)")

        do {
            if let record = try await cloudKit.fetchProgress(
                for: identity,
                contentHash: contentHash,
                bypassCache: true
            ) {
                AppLogger.network.debug("Found cloud progress=\(Int(record.playbackPosition))s bookId=\(diagnosticID)")
                return record
            }

            AppLogger.network.info("No exact match, trying fuzzy match...")

            let allRecords = try await cloudKit.fetchAllRecords()

            if let contentHash,
                let match = allRecords
                    .filter({ $0.domain == .audiobook && $0.contentHash == contentHash })
                    .max(by: { $0.lastUpdated < $1.lastUpdated })
            {
                AppLogger.network.debug("Found content-hash progress=\(Int(match.playbackPosition))s bookId=\(diagnosticID)")
                return match
            }

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

    private func findBestMatch(for identity: CanonicalBookIdentity, in records: [PlaybackStateRecord]) -> PlaybackStateRecord? {
        var bestMatch: (record: PlaybackStateRecord, confidence: Double)?

        for record in records {
            guard record.domain == .audiobook else { continue }
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
}
