import Foundation
import Logging
import UIKit

@MainActor
@Observable
final class LinkedBookQuickSyncService {
    static let shared = LinkedBookQuickSyncService()

    enum Method: String, Equatable {
        case appleTranscription
        case acousticFingerprint
        case chapterLandmarks
        case proportional

        var displayName: String {
            switch self {
            case .appleTranscription:
                return "Apple on-device transcription"
            case .acousticFingerprint:
                return "On-device audio matching"
            case .chapterLandmarks:
                return "Chapter landmarks"
            case .proportional:
                return "Approximate progress"
            }
        }
    }

    struct State: Equatable {
        let ebookStableId: String
        let audiobookStableId: String
        var stage: String
        var progress: Double
        var matchedSamples: Int
        var sampleCount: Int
        var isComplete: Bool
        var error: String?
        var method: Method?
    }

    private(set) var state: State?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var didDisableIdleTimer = false

    private let sampleFractions = [0.04, 0.11, 0.19, 0.28, 0.38, 0.49, 0.60, 0.71, 0.81, 0.90, 0.96]
    private let sampleDuration: TimeInterval = 24

    private init() {}

    func isRunning(ebook: Book, audiobook: Book) -> Bool {
        guard let state else { return false }
        return state.ebookStableId == ebook.stableId
            && state.audiobookStableId == audiobook.stableId
            && !state.isComplete
            && state.error == nil
    }

    func needsAudiobookDownload(_ audiobook: Book) -> Bool {
        LocalStorageManager.shared.localAudiobookFilesIfExists(for: audiobook)?.isEmpty != false
    }

    func start(ebook: Book, audiobook: Book) {
        guard task == nil else { return }

        state = State(
            ebookStableId: ebook.stableId,
            audiobookStableId: audiobook.stableId,
            stage: "Preparing",
            progress: 0,
            matchedSamples: 0,
            sampleCount: sampleFractions.count,
            isComplete: false,
            error: nil,
            method: nil
        )
        beginExecutionProtection()

        task = Task { [weak self] in
            guard let self else { return }
            defer {
                task = nil
                endExecutionProtection()
            }
            do {
                try await run(ebook: ebook, audiobook: audiobook)
            } catch is CancellationError {
                state = nil
            } catch {
                state?.stage = "Quick Sync failed"
                state?.error = error.localizedDescription
            }
        }
    }

    func cancel() {
        LinkedBookLegacyAlignmentService.shared.cancel()
        task?.cancel()
        task = nil
        state = nil
    }

    func dismissResult() {
        guard task == nil else { return }
        state = nil
    }

    private func beginExecutionProtection() {
        guard !UIApplication.shared.isIdleTimerDisabled else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        didDisableIdleTimer = true
    }

    private func endExecutionProtection() {
        guard didDisableIdleTimer else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        didDisableIdleTimer = false
    }

    private func run(ebook: Book, audiobook: Book) async throws {
        if needsAudiobookDownload(audiobook) {
            state?.stage = "Downloading audiobook"
            await UnifiedDownloadService.shared.download(book: audiobook)
            try await awaitAudiobookDownload(audiobook)
        }

        try Task.checkCancellation()
        state?.stage = "Reading ebook text"
        state?.progress = 0.04
        try await EbookContextService.shared.prepareContext(for: ebook)
        guard let context = EbookContextStore.shared.loadContext(bookStableId: ebook.stableId),
            !context.chunks.isEmpty
        else {
            throw LinkedBookQuickSyncError.emptyEbook
        }

        let index = LinkedBookTextIndex(chunks: context.chunks)
        guard !index.tokens.isEmpty else {
            throw LinkedBookQuickSyncError.emptyEbook
        }

        let tracks = try await AudiobookAudioTimelineResolver.shared.localTracks(for: audiobook)
        let duration = tracks.totalDuration
        guard duration > sampleDuration else {
            throw AudiobookTimelineError.noPlayableAudio
        }

        if #available(iOS 26.0, *) {
            do {
                state?.method = .appleTranscription
                let anchors = try await appleTranscriptionAnchors(
                    ebook: ebook,
                    audiobook: audiobook,
                    index: index,
                    duration: duration
                )
                if anchors.count >= 4 {
                    finish(
                        ebook: ebook,
                        audiobook: audiobook,
                        anchors: anchors,
                        method: .appleTranscription
                    )
                    return
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLogger.general.info(
                    "Apple Quick Sync unavailable; using compatibility sync: \(error.localizedDescription)"
                )
            }
        }

        try Task.checkCancellation()
        state?.stage = "Preparing compatibility sync"
        state?.progress = 0.1
        state?.method = .acousticFingerprint
        let fallback = try await LinkedBookLegacyAlignmentService.shared.align(
            chunks: context.chunks,
            tracks: tracks,
            chapters: audiobook.chapters ?? [],
            language: ebook.language ?? audiobook.language
        ) { [weak self] sample, total, matches in
            guard let self else { return }
            state?.stage = "Matching audio sample \(sample) of \(total)"
            state?.progress = 0.12 + 0.8 * Double(sample - 1) / Double(total)
            state?.sampleCount = total
            state?.matchedSamples = matches
        }

        let anchors = monotonicAnchors(fallback.anchors)
        let method: Method
        if anchors.count >= 2, fallback.acousticMatchCount > 0 {
            method = .acousticFingerprint
        } else if anchors.count >= 2 {
            method = .chapterLandmarks
        } else {
            method = .proportional
        }
        finish(
            ebook: ebook,
            audiobook: audiobook,
            anchors: anchors,
            method: method
        )
    }

    @available(iOS 26.0, *)
    private func appleTranscriptionAnchors(
        ebook: Book,
        audiobook: Book,
        index: LinkedBookTextIndex,
        duration: TimeInterval
    ) async throws -> [LinkedBookCalibrationAnchor] {
        var anchors: [LinkedBookCalibrationAnchor] = []
        for (sampleIndex, fraction) in sampleFractions.enumerated() {
            try Task.checkCancellation()
            state?.stage = "Listening to sample \(sampleIndex + 1) of \(sampleFractions.count)"
            state?.progress = 0.08 + 0.84 * Double(sampleIndex) / Double(sampleFractions.count)

            let center = min(max(duration * fraction, sampleDuration / 2), duration - sampleDuration / 2)
            let start = center - sampleDuration / 2
            let end = center + sampleDuration / 2
            let sampleSegments = try await AudiobookTranscriptionService.shared.transcribeWindow(
                for: audiobook,
                startTime: start,
                endTime: end
            )
            let orderedSegments = sampleSegments.sorted { $0.startTime < $1.startTime }
            let sampleText =
                orderedSegments
                .map(\.text)
                .joined(separator: " ")

            if let match = LinkedBookSparseMatcher.match(
                transcript: sampleText,
                expectedProgress: fraction,
                in: index
            ) {
                let audioTime =
                    orderedSegments.isEmpty
                    ? center
                    : orderedSegments.reduce(0) {
                        $0 + ($1.startTime + $1.endTime) / 2
                    } / Double(orderedSegments.count)
                anchors.append(
                    LinkedBookCalibrationAnchor(
                        ebookProgress: match.ebookProgress,
                        audioProgress: min(max(audioTime / duration, 0), 1),
                        quote: match.quote,
                        href: match.href,
                        confidence: match.confidence
                    )
                )
                state?.matchedSamples = monotonicAnchors(anchors).count
            }
        }
        return monotonicAnchors(anchors)
    }

    private func finish(
        ebook: Book,
        audiobook: Book,
        anchors: [LinkedBookCalibrationAnchor],
        method: Method
    ) {
        if anchors.count >= 2 {
            LinkedBookProgressCoordinator.shared.installCalibration(
                ebookStableId: ebook.stableId,
                audiobookStableId: audiobook.stableId,
                anchors: anchors
            )
        }

        state?.stage = "Quick Sync ready"
        state?.progress = 1
        state?.matchedSamples = anchors.count
        state?.isComplete = true
        state?.method = method
        AppLogger.general.info(
            "Quick Sync completed with \(method.displayName) and \(anchors.count) anchors"
        )
    }

    private func awaitAudiobookDownload(_ book: Book) async throws {
        let deadline = Date().addingTimeInterval(3600)
        while Date() < deadline {
            try Task.checkCancellation()
            if LocalStorageManager.shared.localAudiobookFilesIfExists(for: book)?.isEmpty == false {
                return
            }
            let failed =
                UnifiedDownloadService.shared.tasks
                .first(where: { $0.bookId == book.downloadKey })
                .map { $0.status == .failed } ?? false
            if failed {
                throw LinkedBookQuickSyncError.downloadFailed
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw LinkedBookQuickSyncError.downloadTimeout
    }

    private func monotonicAnchors(
        _ anchors: [LinkedBookCalibrationAnchor]
    ) -> [LinkedBookCalibrationAnchor] {
        let ordered = anchors.sorted { $0.audioProgress < $1.audioProgress }
        guard !ordered.isEmpty else { return [] }

        var scores = ordered.map(\.confidence)
        var lengths = Array(repeating: 1, count: ordered.count)
        var predecessors = [Int?](repeating: nil, count: ordered.count)
        for upper in ordered.indices {
            for lower in ordered.indices where lower < upper {
                guard ordered[upper].ebookProgress > ordered[lower].ebookProgress + 0.002 else {
                    continue
                }
                let candidateScore = scores[lower] + ordered[upper].confidence
                let candidateLength = lengths[lower] + 1
                if candidateScore > scores[upper]
                    || (abs(candidateScore - scores[upper]) < 0.0001
                        && candidateLength > lengths[upper])
                {
                    scores[upper] = candidateScore
                    lengths[upper] = candidateLength
                    predecessors[upper] = lower
                }
            }
        }

        var cursor = ordered.indices.max {
            if abs(scores[$0] - scores[$1]) > 0.0001 {
                return scores[$0] < scores[$1]
            }
            return lengths[$0] < lengths[$1]
        }
        var result: [LinkedBookCalibrationAnchor] = []
        while let index = cursor {
            result.append(ordered[index])
            cursor = predecessors[index]
        }
        return result.reversed()
    }
}

private struct LinkedBookTextIndex {
    struct Token {
        let value: String
        let chunkIndex: Int
        let localIndex: Int
    }

    let chunks: [EbookContextChunk]
    let wordsByChunk: [[String]]
    let tokens: [Token]
    let positionsByWord: [String: [Int]]

    init(chunks: [EbookContextChunk]) {
        self.chunks = chunks
        wordsByChunk = chunks.map { LinkedBookSparseMatcher.words(in: $0.text) }

        var builtTokens: [Token] = []
        for (chunkIndex, words) in wordsByChunk.enumerated() {
            builtTokens.append(
                contentsOf: words.enumerated().map {
                    Token(value: $0.element, chunkIndex: chunkIndex, localIndex: $0.offset)
                }
            )
        }
        tokens = builtTokens
        positionsByWord = Dictionary(grouping: builtTokens.indices, by: { builtTokens[$0].value })
    }
}

private enum LinkedBookSparseMatcher {
    struct Match {
        let ebookProgress: Double
        let quote: String
        let href: String?
        let confidence: Double
    }

    static func match(
        transcript: String,
        expectedProgress: Double,
        in index: LinkedBookTextIndex
    ) -> Match? {
        let query = words(in: transcript)
        guard query.count >= 8 else { return nil }

        var votes: [Int: Int] = [:]
        for (queryIndex, word) in query.enumerated() {
            guard word.count >= 4,
                let positions = index.positionsByWord[word],
                positions.count <= 20
            else { continue }
            for position in positions {
                let estimatedStart = position - queryIndex
                votes[estimatedStart / 4, default: 0] += 1
            }
        }

        let expectedStart = Int(expectedProgress * Double(max(index.tokens.count - query.count, 0)))
        var candidateStarts =
            votes
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return abs(lhs.key * 4 - expectedStart) < abs(rhs.key * 4 - expectedStart)
                }
                return lhs.value > rhs.value
            }
            .prefix(30)
            .map { $0.key * 4 }
        candidateStarts.append(expectedStart)

        let scored = Set(candidateStarts).compactMap { start -> ScoredMatch? in
            score(query: query, candidateStart: start, index: index)
        }.sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.0001 {
                return lhs.score > rhs.score
            }
            return abs(lhs.centerProgress - expectedProgress) < abs(rhs.centerProgress - expectedProgress)
        }

        guard let best = scored.first else { return nil }
        let runnerUp = scored.dropFirst().first {
            abs($0.centerToken - best.centerToken) > query.count
        }
        let margin = best.score - (runnerUp?.score ?? 0)
        guard best.score >= 0.38,
            margin >= 0.025 || best.score >= 0.58
        else {
            return nil
        }

        let token = index.tokens[best.centerToken]
        let chunk = index.chunks[token.chunkIndex]
        let chunkWords = index.wordsByChunk[token.chunkIndex]
        let quoteStart = max(0, token.localIndex - 5)
        let quoteEnd = min(chunkWords.count, quoteStart + 12)
        guard quoteEnd > quoteStart else { return nil }

        let localFraction = Double(token.localIndex) / Double(max(chunkWords.count - 1, 1))
        let ebookProgress = min(
            max(
                chunk.startProgress + localFraction * (chunk.endProgress - chunk.startProgress),
                0
            ),
            1
        )
        let confidence = min(1, best.score + min(max(margin, 0), 0.15))
        return Match(
            ebookProgress: ebookProgress,
            quote: chunkWords[quoteStart..<quoteEnd].joined(separator: " "),
            href: chunk.href,
            confidence: confidence
        )
    }

    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private struct ScoredMatch {
        let score: Double
        let centerToken: Int
        let centerProgress: Double
    }

    private static func score(
        query: [String],
        candidateStart: Int,
        index: LinkedBookTextIndex
    ) -> ScoredMatch? {
        let lower = max(0, candidateStart - 12)
        let upper = min(index.tokens.count, candidateStart + query.count + 24)
        guard upper > lower else { return nil }
        let candidate = index.tokens[lower..<upper].map(\.value)

        var table = Array(
            repeating: Array(repeating: 0, count: candidate.count + 1),
            count: query.count + 1
        )
        for queryIndex in 1...query.count {
            for candidateIndex in 1...candidate.count {
                if query[queryIndex - 1] == candidate[candidateIndex - 1] {
                    table[queryIndex][candidateIndex] = table[queryIndex - 1][candidateIndex - 1] + 1
                } else {
                    table[queryIndex][candidateIndex] = max(
                        table[queryIndex - 1][candidateIndex],
                        table[queryIndex][candidateIndex - 1]
                    )
                }
            }
        }

        let matchedCount = table[query.count][candidate.count]
        guard matchedCount > 0 else { return nil }

        var queryIndex = query.count
        var candidateIndex = candidate.count
        var matchedPositions: [Int] = []
        while queryIndex > 0, candidateIndex > 0 {
            if query[queryIndex - 1] == candidate[candidateIndex - 1] {
                matchedPositions.append(lower + candidateIndex - 1)
                queryIndex -= 1
                candidateIndex -= 1
            } else if table[queryIndex - 1][candidateIndex] >= table[queryIndex][candidateIndex - 1] {
                queryIndex -= 1
            } else {
                candidateIndex -= 1
            }
        }

        guard !matchedPositions.isEmpty else { return nil }
        let centerToken = matchedPositions[matchedPositions.count / 2]
        return ScoredMatch(
            score: Double(matchedCount) / Double(query.count),
            centerToken: centerToken,
            centerProgress: Double(centerToken) / Double(max(index.tokens.count - 1, 1))
        )
    }
}
