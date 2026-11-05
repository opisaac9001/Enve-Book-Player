#if os(iOS)
import Foundation
import StoryAlignCore

nonisolated struct PassageTrack: Sendable {
    let index: Int
    let url: URL
    let digest: String
    /// Decoded file duration used for the analysis grid.
    let duration: TimeInterval
    /// The player's offset for this track on the complete audiobook timeline.
    let bookOffset: TimeInterval
    var headers: [String: String] = [:]
    var networkSession: URLSession? = nil
}

/// A sentence timing in track presentation seconds, with observed original-word timings when the engine has them.
nonisolated struct PassageMatch: Equatable, Sendable {
    let sentenceIndex: Int
    let start: TimeInterval
    let end: TimeInterval
    let score: Float
    var words: [PassageWordTiming]? = nil
}

extension PassageMatch {
    init(_ match: CTCPassageMatch) {
        self.init(sentenceIndex: match.sentenceIndex, start: match.start, end: match.end, score: match.score)
    }
}

protocol PassageAlignmentEngine: Sendable {
    var id: String { get }
    var granularity: PassageGranularity { get }
    func analyze(window: CTCPassageWindow, previous: CTCPassageWindow?, track: PassageTrack) async throws -> [PassageMatch]
    /// Delay before the next inferred window, from the current thermal state and execution provider.
    func pacing() async -> Duration
    func release() async
}

enum PassagePacing {
    static func delay(accelerated: Bool) -> Duration {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .milliseconds(250)
        case .fair: accelerated ? .milliseconds(500) : .seconds(2)
        default: .seconds(2)
        }
    }
}

struct QuartzNetPassageEngine: PassageAlignmentEngine {
    let analyzer: CTCPassageAnalyzer

    var id: String { analyzer.modelIdentifier }
    var granularity: PassageGranularity { .sentence }

    func analyze(window: CTCPassageWindow, previous: CTCPassageWindow?, track: PassageTrack) async throws -> [PassageMatch] {
        if !track.url.isFileURL {
            let start = previous?.start ?? window.start
            let local = try await PassageAudioWindow.extract(track: track, start: start, end: window.end)
            defer { try? FileManager.default.removeItem(at: local) }
            let duration = window.end - start
            let grid = CTCPassageWindow.grid(trackDuration: duration)
            guard let current = grid.last else { return [] }
            let matches = try await analyzer.analyze(
                window: current, previous: grid.dropLast().last, audioURL: local,
                audioIdentity: "\(track.digest):\(start)", trackIndex: track.index, trackDuration: duration
            ).matches
            return matches.compactMap { match in
                guard window.owns(end: match.end + start) else { return nil }
                return PassageMatch(sentenceIndex: match.sentenceIndex, start: match.start + start, end: match.end + start, score: match.score)
            }
        }
        return try await analyzer.analyze(
            window: window, previous: previous, audioURL: track.url, audioIdentity: track.digest,
            trackIndex: track.index, trackDuration: track.duration
        ).matches.map(PassageMatch.init)
    }

    func pacing() async -> Duration {
        let provider = await analyzer.executionProvider
        return PassagePacing.delay(accelerated: provider == .coreMLNeuralEngine || provider == .coreMLAll)
    }

    func release() async {
        await analyzer.releaseModel()
    }
}

/// Matches recognized, timed words to original sentences. Sentence boundaries are the observed first and last
/// words; a printed word is timed only by recognizer runs that cover nothing else, next to another timed word.
/// A run spanning several printed words times none of them.
nonisolated struct PassageWordMatcher: Sendable {
    struct PrintedWord: Equatable, Sendable {
        let location: Int
        let length: Int
        let tokens: Range<Int>
    }

    private let tokens: [(word: String, sentence: Int)]
    private let sentenceTokenRanges: [Range<Int>]
    private let printedWords: [[PrintedWord]]
    private let positions: [String: [Int]]

    init(sentences: [String]) {
        var tokens: [(word: String, sentence: Int)] = []
        var ranges: [Range<Int>] = []
        var printed: [[PrintedWord]] = []
        for (index, sentence) in sentences.enumerated() {
            let start = tokens.count
            var words: [PrintedWord] = []
            for (location, length, chunk) in Self.printedWords(sentence) {
                let chunkTokens = Self.words(chunk)
                guard !chunkTokens.isEmpty else { continue }
                let first = tokens.count
                tokens.append(contentsOf: chunkTokens.map { ($0, index) })
                words.append(PrintedWord(location: location, length: length, tokens: first..<tokens.count))
            }
            ranges.append(start..<tokens.count)
            printed.append(words)
        }
        self.tokens = tokens
        sentenceTokenRanges = ranges
        printedWords = printed
        positions = Dictionary(grouping: tokens.indices, by: { tokens[$0].word })
    }

    /// Comparison tokens: case, diacritics and punctuation are ignored, so "Café's" and "cafe s" agree.
    static func words(_ text: String) -> [String] {
        PassageMappingSet.normalized(text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil))
            .split(separator: " ").map(String.init)
    }

    /// The lexical word targets of a printed sentence, with their text.
    static func printedWords(_ text: String) -> [(location: Int, length: Int, text: String)] {
        PassageWordTiming.lexicalWords(in: text).compactMap { word in
            PassageWordTiming(location: word.location, length: word.length, start: 0, end: 0).range(in: text).map {
                (word.location, word.length, String(text[$0]))
            }
        }
    }

    func match(_ recognized: [TranscribedWord], owns: (TimeInterval) -> Bool) -> [PassageMatch] {
        let query = recognized.enumerated().flatMap { run, word in Self.words(word.text).map { (word: $0, timing: word, run: run) } }
        guard query.count >= 8 else { return [] }
        var votes: [Int: Int] = [:]
        for (offset, item) in query.enumerated() where item.word.count >= 4 {
            guard let found = positions[item.word], found.count <= 20 else { continue }
            for position in found { votes[(position - offset) / 8, default: 0] += 1 }
        }
        guard let best = votes.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }), best.value >= 4 else { return [] }
        let competing = votes.filter { abs($0.key - best.key) > 2 }.map(\.value).max() ?? 0
        guard competing * 4 < best.value * 3 else { return [] }

        let lower = max(0, best.key * 8 - 24)
        let upper = min(tokens.count, best.key * 8 + query.count + 48)
        guard upper > lower else { return [] }
        let candidate = Array(tokens[lower..<upper])
        var table = Array(repeating: Array(repeating: 0, count: candidate.count + 1), count: query.count + 1)
        for q in 1...query.count {
            for c in 1...candidate.count {
                table[q][c] = query[q - 1].word == candidate[c - 1].word
                    ? table[q - 1][c - 1] + 1
                    : max(table[q - 1][c], table[q][c - 1])
            }
        }
        // Token index -> query index of the recognized token paired with it.
        var pairs: [Int: Int] = [:]
        var q = query.count
        var c = candidate.count
        while q > 0, c > 0 {
            if query[q - 1].word == candidate[c - 1].word {
                pairs[lower + c - 1] = q - 1
                q -= 1
                c -= 1
            } else if table[q - 1][c] >= table[q][c - 1] {
                q -= 1
            } else {
                c -= 1
            }
        }
        var pairedToken: [Int: Int] = [:]
        for (token, queryIndex) in pairs { pairedToken[queryIndex] = token }
        let runTokens = Dictionary(grouping: query.indices, by: { query[$0].run })

        let sentences = Set(candidate.map(\.sentence)).sorted()
        return sentences.compactMap { sentence -> PassageMatch? in
            let range = sentenceTokenRanges[sentence]
            guard range.count >= 2, let first = pairs[range.lowerBound].map({ query[$0].timing }),
                let last = pairs[range.upperBound - 1].map({ query[$0].timing })
            else { return nil }
            let matched = range.filter { pairs[$0] != nil }.count
            guard matched * 10 >= range.count * 6, last.end > first.start, owns(last.end) else { return nil }
            let words = wordTimings(sentence: sentence, pairs: pairs, pairedToken: pairedToken, runTokens: runTokens, query: query)
            return PassageMatch(
                sentenceIndex: sentence, start: first.start, end: last.end, score: Float(matched) / Float(range.count),
                words: words.isEmpty ? nil : words
            )
        }
    }

    private func wordTimings(
        sentence: Int, pairs: [Int: Int], pairedToken: [Int: Int], runTokens: [Int: [Int]],
        query: [(word: String, timing: TranscribedWord, run: Int)]
    ) -> [PassageWordTiming] {
        let printed = printedWords[sentence]
        let timed: [PassageWordTiming?] = printed.map { word in
            let queryIndices = word.tokens.compactMap { pairs[$0] }
            guard queryIndices.count == word.tokens.count else { return nil }
            let runs = Set(queryIndices.map { query[$0].run })
            // A run that also covers another printed word only times the group, never this word alone.
            for run in runs {
                guard runTokens[run]?.allSatisfy({ pairedToken[$0].map(word.tokens.contains) == true }) == true else { return nil }
            }
            let timings = runs.compactMap { runTokens[$0]?.first.map { query[$0].timing } }
            guard let start = timings.map(\.start).min(), let end = timings.map(\.end).max(), end > start else { return nil }
            return PassageWordTiming(location: word.location, length: word.length, start: start, end: end)
        }
        return timed.indices.compactMap { index in
            guard let word = timed[index] else { return nil }
            let hasNeighbor = (index > 0 && timed[index - 1] != nil) || (index + 1 < timed.count && timed[index + 1] != nil)
            return hasNeighbor ? word : nil
        }
    }
}

#if !targetEnvironment(macCatalyst)
/// Apple Speech engine. Constructed only inside an iOS 26 availability check; its Speech types never load
/// through the shared path on older systems.
@available(iOS 26.0, *)
struct AppleSpeechPassageEngine: PassageAlignmentEngine {
    let id: String
    let locale: Locale
    let matcher: PassageWordMatcher
    var granularity: PassageGranularity { .sentence }

    static func make(sentences: [CTCPassageSentence], language: String?) async throws -> AppleSpeechPassageEngine {
        let locale = try await AudiobookTranscriptionService.shared.supportedLocale(language: language)
        return AppleSpeechPassageEngine(
            id: "apple-speech-\(locale.identifier(.bcp47))", locale: locale,
            matcher: PassageWordMatcher(sentences: sentences.map(\.text))
        )
    }

    func analyze(window: CTCPassageWindow, previous: CTCPassageWindow?, track: PassageTrack) async throws -> [PassageMatch] {
        // Eight seconds of leading context lets a sentence that began before the window be finalized here.
        let start = max(0, window.start - 8)
        if !track.url.isFileURL {
            let local = try await PassageAudioWindow.extract(track: track, start: start, end: window.end)
            defer { try? FileManager.default.removeItem(at: local) }
            let words = try await AudiobookTranscriptionService.shared.transcribeWords(
                trackURL: local, ownerID: "passage-\(track.digest.prefix(12))", startTime: 0, endTime: window.end - start, locale: locale
            ).map { TranscribedWord(text: $0.text, start: $0.start + start, end: $0.end + start) }
            return matcher.match(words) { window.owns(end: $0) }
        }
        let words = try await AudiobookTranscriptionService.shared.transcribeWords(
            trackURL: track.url, ownerID: "passage-\(track.digest.prefix(12))", startTime: start, endTime: window.end, locale: locale
        )
        return matcher.match(words) { window.owns(end: $0) }
    }

    func pacing() async -> Duration {
        PassagePacing.delay(accelerated: true)
    }

    func release() async {}
}
#endif

nonisolated enum PassageEngineKind: String, Sendable {
    case quartzNet
    case appleSpeech

    var title: String {
        switch self {
        case .quartzNet: "QuartzNet"
        case .appleSpeech: "Apple Speech"
        }
    }
}

nonisolated enum PassageUnavailableReason: Equatable, Sendable {
    case unsupportedSystem
    case unsupportedHardware
    case unsupportedLanguage
    case unsupportedFormat
    case missingMedia
    case modelDownloadRequired
    case permissionDenied
    case lowStorage
    case busy
    case pausedForPower
    case pausedForTemperature
    case backgroundUnavailable
    case generationDisabled
    case preparationFailed

    /// Reasons that only change after the user acts, so background look-ahead must not keep retrying them.
    var needsUserAction: Bool {
        switch self {
        case .busy, .pausedForPower, .pausedForTemperature, .backgroundUnavailable, .lowStorage: false
        default: true
        }
    }

    var message: String {
        switch self {
        case .unsupportedSystem: "Preparing with Apple Speech requires iOS 26 or later. Prepared passages still work."
        case .unsupportedHardware: "This device cannot prepare passages. Prepared passages still work."
        case .unsupportedLanguage: "No on-device alignment engine supports this book's language. Approximate sync remains available."
        case .unsupportedFormat: "Passage preparation needs a downloaded EPUB."
        case .missingMedia: "Download the ebook, then download or play its linked audiobook to prepare passages."
        case .modelDownloadRequired: "Download the 77 MB English alignment model to prepare passages."
        case .permissionDenied: "Speech Recognition permission is off. Prepared passages still work."
        case .lowStorage: "Not enough storage to prepare more passages. Clear analysis data in StoryAlign settings."
        case .busy: "Another alignment is running. Preparation will continue when it finishes."
        case .pausedForPower: "Preparation is paused in Low Power Mode. Prepared passages still work."
        case .pausedForTemperature: "Preparation is paused until the device cools down."
        case .backgroundUnavailable: "Preparation pauses while Enve is in the background and resumes when you return."
        case .generationDisabled: "Passage preparation is turned off in StoryAlign settings."
        case .preparationFailed: "Enve couldn't start preparing passages for this book."
        }
    }
}
#endif
