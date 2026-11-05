import CryptoKit
import Foundation
import Logging

nonisolated enum PassageGranularity: String, Codable, Sendable {
    case sentence
    case word
}

/// Durable identity of an original EPUB sentence under `PassageMappingSet.currentSegmentation`.
nonisolated struct PassageSentenceKey: Codable, Hashable, Comparable, Sendable {
    let chapter: Int
    let sentence: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.chapter == rhs.chapter ? lhs.sentence < rhs.sentence : lhs.chapter < rhs.chapter
    }
}

/// One segmented sentence of the original EPUB. `chapterProgression` counts UTF-16 units of the
/// concatenated segmented chapter text, the unit the reader's DOM uses.
nonisolated struct PassageSentence: Codable, Equatable, Sendable {
    let key: PassageSentenceKey
    let href: String
    let text: String
    let chapterProgression: Double
    let totalProgression: Double
}

nonisolated struct PassageMapping: Codable, Equatable, Sendable {
    let key: PassageSentenceKey
    let href: String
    let text: String
    let before: String
    let after: String
    let chapterProgression: Double
    let totalProgression: Double
    let trackIndex: Int
    /// Track-local presentation seconds; independent of playback rate.
    let start: TimeInterval
    let end: TimeInterval
    let granularity: PassageGranularity
    let engine: String
    /// Engine-specific evidence. Scores from different engines are not comparable probabilities.
    let score: Double
    /// Observed timings of original words, present only when every word passed `PassageWordTiming.validated`.
    var words: [PassageWordTiming]? = nil

    var locatorJSON: String {
        Self.locatorJSON(href: href, chapterProgression: chapterProgression, totalProgression: totalProgression, highlight: text, before: before, after: after)
    }

    /// The printed word with in-sentence context, so a repeated word resolves to this occurrence.
    func locatorJSON(for word: PassageWordTiming) -> String? {
        locatorJSON(location: word.location, length: word.length)
    }

    func locatorJSON(location: Int, length: Int) -> String? {
        guard let range = PassageWordTiming(location: location, length: length, start: 0, end: 0).range(in: text) else { return nil }
        let prefix = String(text[..<range.lowerBound])
        let suffix = String(text[range.upperBound...])
        return Self.locatorJSON(
            href: href, chapterProgression: chapterProgression, totalProgression: totalProgression, highlight: String(text[range]),
            before: prefix.isEmpty ? before : String(prefix.suffix(64)), after: suffix.isEmpty ? after : String(suffix.prefix(64))
        )
    }

    /// The word being spoken at a track time; nil in the silence between words.
    func word(at time: TimeInterval) -> PassageWordTiming? {
        guard let words else { return nil }
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0, time < words[low - 1].end else { return nil }
        return words[low - 1]
    }

    private static func locatorJSON(href: String, chapterProgression: Double, totalProgression: Double, highlight: String, before: String, after: String) -> String {
        let object: [String: Any] = [
            "href": href,
            "type": "application/xhtml+xml",
            "locations": ["progression": chapterProgression, "totalProgression": totalProgression],
            "text": ["highlight": highlight, "before": before, "after": after],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// An observed spoken word: a UTF-16 range of the mapping's printed text and track-local seconds.
nonisolated struct PassageWordTiming: Codable, Equatable, Sendable {
    let location: Int
    let length: Int
    let start: TimeInterval
    let end: TimeInterval

    static let tolerance: TimeInterval = 0.05

    func range(in text: String) -> Range<String.Index>? {
        let utf16 = text.utf16
        // Subtraction, not `location + length`: decoded values can be anything up to Int.max.
        guard location >= 0, length > 0, location <= utf16.count, length <= utf16.count - location,
            let lower = utf16.index(utf16.startIndex, offsetBy: location, limitedBy: utf16.endIndex),
            let upper = utf16.index(lower, offsetBy: length, limitedBy: utf16.endIndex),
            Self.isCharacterBoundary(lower, in: text), Self.isCharacterBoundary(upper, in: text)
        else { return nil }
        return lower..<upper
    }

    /// All or nothing: every word must be exactly one printed word of `text`; one invalid word leaves the mapping
    /// with its sentence highlight only.
    static func validated(_ words: [PassageWordTiming], in text: String, start: TimeInterval, end: TimeInterval) -> [PassageWordTiming]? {
        guard !words.isEmpty else { return nil }
        let printed = Set(lexicalWords(in: text).map { [$0.location, $0.length] })
        var previous: PassageWordTiming?
        for word in words {
            guard word.start.isFinite, word.end.isFinite, word.end > word.start,
                word.start >= start - tolerance, word.end <= end + tolerance,
                printed.contains([word.location, word.length]), word.range(in: text) != nil
            else { return nil }
            if let previous {
                guard word.location >= previous.location + previous.length, word.start >= previous.end - tolerance else { return nil }
            }
            previous = word
        }
        return words
    }

    /// Printed words by Unicode word boundaries, as UTF-16 ranges. Apostrophes inside a word and a single hyphen
    /// joining two words keep one target ("don’t", "well-known"); dashes, slashes and quotes separate words.
    static func lexicalWords(in text: String) -> [(location: Int, length: Int)] {
        var words: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            guard text[range].contains(where: { $0.isLetter || $0.isNumber }) else { return }
            if let last = words.last, ["-", "\u{2010}", "\u{2011}"].contains(String(text[last.upperBound..<range.lowerBound])) {
                words[words.count - 1] = last.lowerBound..<range.upperBound
            } else {
                words.append(range)
            }
        }
        return words.map { range in
            let location = text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
            return (location, text.utf16.distance(from: range.lowerBound, to: range.upperBound))
        }
    }

    private static func isCharacterBoundary(_ index: String.Index, in text: String) -> Bool {
        guard index.samePosition(in: text.unicodeScalars) != nil else { return false }
        return index == text.endIndex || text.rangeOfComposedCharacterSequence(at: index).lowerBound == index
    }
}

nonisolated struct PassageCoverage: Codable, Equatable, Sendable {
    let trackIndex: Int
    var start: TimeInterval
    var end: TimeInterval
}

nonisolated struct PassageWindowRecord: Codable, Hashable, Sendable {
    let trackIndex: Int
    let windowIndex: Int
    let engine: String
    let accepted: Bool
}

/// One analyzed window. It replaces the mappings whose sentence ends inside `ownedEnds` and, when accepted,
/// establishes `coverage`: audio where every spoken sentence the window could finalize has been decided.
nonisolated struct PassageWindowUpdate: Sendable {
    let trackIndex: Int
    let windowIndex: Int
    let ownedEnds: Range<TimeInterval>
    let engine: String
    let mappings: [PassageMapping]

    var isAccepted: Bool { mappings.count >= 3 }

    var coverage: ClosedRange<TimeInterval>? {
        guard isAccepted, let first = mappings.map(\.start).min(), let last = mappings.map(\.end).max() else { return nil }
        let lower = min(ownedEnds.lowerBound, first)
        let upper = min(ownedEnds.upperBound, last + PassageMappingSet.pauseTolerance)
        return lower...max(lower, upper)
    }
}

nonisolated enum PassageAudioResolution: Equatable, Sendable {
    case matched(PassageMapping)
    /// A short silence between two mapped sentences inside accepted coverage; not an exact position.
    case pause(previous: PassageMapping, next: PassageMapping)
    /// Inside analyzed coverage, but this audio has no accepted sentence.
    case gap
    case unprepared

    var mapping: PassageMapping? {
        if case .matched(let mapping) = self { return mapping }
        return nil
    }

    /// The sentence to open for a listening handoff: the current sentence, or the next one after a pause.
    var handoffMapping: PassageMapping? {
        switch self {
        case .matched(let mapping): mapping
        case .pause(_, let next): next
        case .gap, .unprepared: nil
        }
    }
}

nonisolated enum PassageTextResolution: Equatable, Sendable {
    case matched(PassageMapping)
    /// The sentence sits between adjacent mapped narration and is not spoken (a heading or footnote).
    case notSpoken(PassageSentence)
    case ambiguous
    case unprepared(PassageSentence?)
}

/// The original-EPUB text reference in a Readium locator, when it quotes printed text.
nonisolated struct PassageLocatorQuote: Equatable, Sendable {
    let href: String
    let highlight: String
    let progression: Double?
    let totalProgression: Double?

    init?(locatorJSON: String?) {
        guard let data = locatorJSON?.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let href = object["href"] as? String, !href.isEmpty,
            let highlight = (object["text"] as? [String: Any])?["highlight"] as? String,
            !highlight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let locations = object["locations"] as? [String: Any]
        self.href = href
        self.highlight = highlight
        progression = (locations?["progression"] as? NSNumber)?.doubleValue
        totalProgression = (locations?["totalProgression"] as? NSNumber)?.doubleValue
    }
}

nonisolated struct PassageMediaIdentity: Codable, Hashable, Sendable {
    let ebookStableId: String
    let audiobookStableId: String
    /// Content digest of the original EPUB the mapping was prepared from.
    let readingRevision: String
    /// Ordered content digests of the audiobook tracks.
    let trackRevisions: [String]
}

nonisolated struct PassageMappingSet: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let currentSegmentation = "storyalign-xhtml-sentences-v1"
    static let currentTimingConvention = "avfoundation-track-presentation-seconds-v1"
    static let pauseTolerance: TimeInterval = 2

    var schemaVersion = Self.currentSchemaVersion
    var segmentation = Self.currentSegmentation
    var timingConvention = Self.currentTimingConvention
    var identity: PassageMediaIdentity
    var revision = 0
    private(set) var mappings: [PassageMapping] = []
    private(set) var coverage: [PassageCoverage] = []
    private(set) var windows: [PassageWindowRecord] = []

    init(identity: PassageMediaIdentity) {
        self.identity = identity
    }

    var isCurrentFormat: Bool {
        schemaVersion == Self.currentSchemaVersion && segmentation == Self.currentSegmentation
            && timingConvention == Self.currentTimingConvention
    }

    func hasAttempted(trackIndex: Int, windowIndex: Int, engine: String) -> Bool {
        windows.contains { $0.trackIndex == trackIndex && $0.windowIndex == windowIndex && $0.engine == engine }
    }

    /// Carries forward only data still valid for `newIdentity`: a different EPUB invalidates every locator,
    /// and a replaced track invalidates just that track's timings.
    func rebased(to newIdentity: PassageMediaIdentity) -> PassageMappingSet? {
        guard identity.ebookStableId == newIdentity.ebookStableId,
            identity.audiobookStableId == newIdentity.audiobookStableId,
            identity.readingRevision == newIdentity.readingRevision
        else { return nil }
        guard identity != newIdentity else { return self }
        let unchanged = Set(newIdentity.trackRevisions.indices.filter {
            identity.trackRevisions.indices.contains($0) && identity.trackRevisions[$0] == newIdentity.trackRevisions[$0]
        })
        var result = self
        result.identity = newIdentity
        result.mappings.removeAll { !unchanged.contains($0.trackIndex) }
        result.coverage.removeAll { !unchanged.contains($0.trackIndex) }
        result.windows.removeAll { !unchanged.contains($0.trackIndex) }
        result.revision += 1
        return result
    }

    /// Applies one analyzed window. Attempting a window is recorded separately from establishing coverage.
    mutating func merge(_ update: PassageWindowUpdate) {
        setWindow(update, accepted: false)
        revision += 1
        guard update.isAccepted else { return }

        let owned: (PassageMapping) -> Bool = {
            $0.trackIndex == update.trackIndex && update.ownedEnds.contains($0.end)
        }
        var combined = mappings.filter { !owned($0) }
        let existingKeys = Set(combined.map(\.key))
        let incoming = update.mappings
            .filter { owned($0) && !existingKeys.contains($0.key) && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var added = 0
        var previousIncoming: PassageSentenceKey?
        for mapping in incoming {
            if let previousIncoming, !(previousIncoming < mapping.key) { continue }
            let position = combined.firstIndex { Self.audioOrder(mapping, $0) } ?? combined.endIndex
            // A conflict with independently accepted neighbors needs reacquisition, not silent replacement.
            if position > combined.startIndex, !(combined[combined.index(before: position)].key < mapping.key) { continue }
            if position < combined.endIndex, !(mapping.key < combined[position].key) { continue }
            combined.insert(mapping, at: position)
            previousIncoming = mapping.key
            added += 1
        }
        guard added >= 3, let interval = update.coverage else { return }
        mappings = combined
        setWindow(update, accepted: true)
        addCoverage(PassageCoverage(trackIndex: update.trackIndex, start: interval.lowerBound, end: interval.upperBound))
    }

    /// Runs on every read-along tick, so it searches the audio-ordered mappings in place instead of copying a track.
    func resolve(trackIndex: Int, time: TimeInterval) -> PassageAudioResolution {
        let first = boundary { $0.trackIndex >= trackIndex }
        let end = boundary { $0.trackIndex > trackIndex }
        let low = boundary { $0.trackIndex > trackIndex || ($0.trackIndex == trackIndex && $0.start > time) }
        if low > first, time <= mappings[low - 1].end { return .matched(mappings[low - 1]) }
        guard isCovered(trackIndex: trackIndex, time: time) else { return .unprepared }
        guard low > first, low < end else { return .gap }
        let previous = mappings[low - 1]
        let next = mappings[low]
        return next.start - previous.end <= Self.pauseTolerance ? .pause(previous: previous, next: next) : .gap
    }

    /// The first index whose mapping is past the predicate's boundary in audio order.
    private func boundary(_ isPast: (PassageMapping) -> Bool) -> Int {
        var low = 0
        var high = mappings.count
        while low < high {
            let middle = (low + high) / 2
            if isPast(mappings[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    func mapping(for key: PassageSentenceKey) -> PassageMapping? {
        mappings.first { $0.key == key }
    }

    func isCovered(trackIndex: Int, time: TimeInterval) -> Bool {
        coverage.contains { $0.trackIndex == trackIndex && time >= $0.start && time <= $0.end }
    }

    /// Resolves visible or selected reader text against the segmented original EPUB.
    func resolve(href: String, quote: String, chapterProgression: Double?, sentences: [PassageSentence]) -> PassageTextResolution {
        let query = Self.normalized(quote)
        guard query.count >= 3 else { return .unprepared(nil) }
        let probe = String(query.prefix(32))
        let candidates = sentences.filter { sentence in
            guard Self.hrefMatches(sentence.href, href) else { return false }
            let text = Self.normalized(sentence.text)
            guard text.count >= 3 else { return false }
            return text.contains(probe) || query.hasPrefix(String(text.prefix(32)))
        }
        guard let target = Self.disambiguate(candidates, progression: chapterProgression) else {
            return candidates.isEmpty ? .unprepared(nil) : .ambiguous
        }
        if let mapping = mapping(for: target.key) { return .matched(mapping) }
        let ordered = mappings.sorted { $0.key < $1.key }
        if let next = ordered.firstIndex(where: { target.key < $0.key }), next > 0 {
            let before = ordered[next - 1]
            let after = ordered[next]
            if before.trackIndex == after.trackIndex, after.start - before.end <= Self.pauseTolerance + 1 {
                return .notSpoken(target)
            }
        }
        return .unprepared(target)
    }

    private static func disambiguate(_ candidates: [PassageSentence], progression: Double?) -> PassageSentence? {
        guard candidates.count > 1 else { return candidates.first }
        guard let progression else { return nil }
        let ranked = candidates.sorted { abs($0.chapterProgression - progression) < abs($1.chapterProgression - progression) }
        let best = abs(ranked[0].chapterProgression - progression)
        let runnerUp = abs(ranked[1].chapterProgression - progression)
        return runnerUp - best > 0.05 ? ranked[0] : nil
    }

    private mutating func setWindow(_ update: PassageWindowUpdate, accepted: Bool) {
        windows.removeAll {
            $0.trackIndex == update.trackIndex && $0.windowIndex == update.windowIndex && $0.engine == update.engine
        }
        windows.append(PassageWindowRecord(trackIndex: update.trackIndex, windowIndex: update.windowIndex, engine: update.engine, accepted: accepted))
    }

    private mutating func addCoverage(_ interval: PassageCoverage) {
        var merged = interval
        var others: [PassageCoverage] = []
        for existing in coverage {
            if existing.trackIndex == merged.trackIndex, existing.start <= merged.end, merged.start <= existing.end {
                merged.start = min(merged.start, existing.start)
                merged.end = max(merged.end, existing.end)
            } else {
                others.append(existing)
            }
        }
        others.append(merged)
        coverage = others.sorted { $0.trackIndex == $1.trackIndex ? $0.start < $1.start : $0.trackIndex < $1.trackIndex }
    }

    private static func audioOrder(_ lhs: PassageMapping, _ rhs: PassageMapping) -> Bool {
        lhs.trackIndex == rhs.trackIndex ? lhs.start < rhs.start : lhs.trackIndex < rhs.trackIndex
    }

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func hrefMatches(_ lhs: String, _ rhs: String) -> Bool {
        func normalize(_ href: String) -> String {
            let path = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? href
            return (path.removingPercentEncoding ?? path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        }
        let a = normalize(lhs)
        let b = normalize(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasSuffix("/" + b) || b.hasSuffix("/" + a)
    }
}

/// Profile-owned persistence for passage mappings and reusable acoustic checkpoints.
/// Mapping files are replaced atomically; an interrupted write leaves the previous readable version.
@MainActor
@Observable
final class PassageAlignmentStore {
    static let acousticLimitBytes: Int64 = 512 * 1_024 * 1_024

    private(set) var changeCount = 0
    @ObservationIgnored private var sets: [String: PassageMappingSet] = [:]
    @ObservationIgnored private var textIndexes: [String: [PassageSentence]] = [:]
    @ObservationIgnored private let commits = PerBookSerialQueue()
    @ObservationIgnored private var isRetired = false
    /// Bumped by every removal; a load or commit that started earlier must not repopulate the cache or disk.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var writes: [UUID: Task<Bool, Never>] = [:]
    /// Writes are refused while every pair is being removed, so none can start after the drain.
    @ObservationIgnored private var isRemoving = false
    /// Windows merged since each pair's file was last written. The cached set stays authoritative meanwhile; a lost
    /// merge only re-matches its window from the saved acoustic checkpoint.
    @ObservationIgnored private var unsaved: [String: (windows: Int, since: ContinuousClock.Instant)] = [:]
    @ObservationIgnored var windowsPerSave = 10
    @ObservationIgnored let root: URL
    @ObservationIgnored let acousticDirectory: URL

    init(root: URL) {
        self.root = root
        acousticDirectory = root.appendingPathComponent("acoustic", isDirectory: true)
    }

    /// Role-ordered and hashed: local stable IDs can embed long file paths that exceed filename limits.
    nonisolated static func pairKey(ebookStableId: String, audiobookStableId: String) -> String {
        let digest = SHA256.hash(data: Data("ebook:\(ebookStableId)\u{1F}audiobook:\(audiobookStableId)".utf8))
        return digest.prefix(20).map { String(format: "%02x", $0) }.joined()
    }

    private func directory(pairKey: String) -> URL {
        root.appendingPathComponent("pairs", isDirectory: true).appendingPathComponent(pairKey, isDirectory: true)
    }

    private func mappingURL(pairKey: String) -> URL {
        directory(pairKey: pairKey).appendingPathComponent("mapping.json")
    }

    private func textIndexURL(pairKey: String, readingRevision: String) -> URL {
        directory(pairKey: pairKey).appendingPathComponent("text-\(readingRevision.prefix(16)).json")
    }

    /// The readable mapping for exactly this media identity, or nil when absent, invalid or in an unknown schema.
    func mappingSet(for identity: PassageMediaIdentity) async -> PassageMappingSet? {
        let key = Self.pairKey(ebookStableId: identity.ebookStableId, audiobookStableId: identity.audiobookStableId)
        if let cached = sets[key], let rebased = cached.rebased(to: identity) {
            sets[key] = rebased
            return rebased
        }
        let url = mappingURL(pairKey: key)
        let started = epoch
        let stored = await Task.detached(priority: .userInitiated) { () -> PassageMappingSet? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(PassageMappingSet.self, from: data)
        }.value
        guard !isRetired, !isRemoving, started == epoch, let stored, stored.isCurrentFormat, let rebased = stored.rebased(to: identity) else { return nil }
        if let current = sets[key], current.identity == identity { return current }
        sets[key] = rebased
        return rebased
    }

    /// Signals observers that verification or another external input may change resolution results.
    func noteExternalChange() {
        changeCount += 1
    }

    func hasStoredMapping(ebookStableId: String, audiobookStableId: String) -> Bool {
        FileManager.default.fileExists(atPath: mappingURL(pairKey: Self.pairKey(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId)).path)
    }

    func cachedMappingSet(ebookStableId: String, audiobookStableId: String) -> PassageMappingSet? {
        sets[Self.pairKey(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId)]
    }

    /// Serialized per pair. Nil when retirement or a removal superseded it. The file is rewritten for a pair's first
    /// window and then every `windowsPerSave` windows or five minutes; a due write that fails throws, leaving the
    /// previously merged set readable.
    func commit(_ update: PassageWindowUpdate, identity: PassageMediaIdentity) async throws -> PassageMappingSet? {
        let key = Self.pairKey(ebookStableId: identity.ebookStableId, audiobookStableId: identity.audiobookStableId)
        let started = epoch
        var result: PassageMappingSet?
        var failed = false
        await commits.enqueue(bookId: "passage|\(key)") { [self] in
            guard !isRetired, started == epoch else { return }
            var set = await mappingSet(for: identity) ?? PassageMappingSet(identity: identity)
            guard !isRetired, !isRemoving, started == epoch else { return }
            set.merge(update)
            let url = mappingURL(pairKey: key)
            let pending = unsaved[key]
            let due = !FileManager.default.fileExists(atPath: url.path)
                || (pending?.windows ?? 0) + 1 >= windowsPerSave
                || pending.map { ContinuousClock.now - $0.since >= .seconds(300) } == true
            if due {
                guard await write(set, to: url) else {
                    failed = true
                    return
                }
                guard !isRetired, started == epoch else { return }
                unsaved[key] = nil
            } else {
                unsaved[key] = ((pending?.windows ?? 0) + 1, pending?.since ?? .now)
            }
            sets[key] = set
            changeCount += 1
            result = set
        }
        if failed { throw CocoaError(.fileWriteUnknown) }
        return result
    }

    /// Writes every pair merged since its last save: on backgrounding, when a session closes and on retirement.
    func flush() async {
        for key in Array(unsaved.keys) {
            let started = epoch
            await commits.enqueue(bookId: "passage|\(key)") { [self] in
                guard unsaved[key] != nil, let set = sets[key], !isRetired, started == epoch else { return }
                if await write(set, to: mappingURL(pairKey: key)), started == epoch { unsaved[key] = nil }
            }
        }
    }

    func saveTextIndex(_ sentences: [PassageSentence], identity: PassageMediaIdentity) async {
        let key = Self.pairKey(ebookStableId: identity.ebookStableId, audiobookStableId: identity.audiobookStableId)
        let url = textIndexURL(pairKey: key, readingRevision: identity.readingRevision)
        let started = epoch
        guard await write(sentences, to: url), !isRetired, started == epoch else { return }
        textIndexes[url.path] = sentences
    }

    func textIndex(for identity: PassageMediaIdentity) async -> [PassageSentence]? {
        let key = Self.pairKey(ebookStableId: identity.ebookStableId, audiobookStableId: identity.audiobookStableId)
        let url = textIndexURL(pairKey: key, readingRevision: identity.readingRevision)
        if let cached = textIndexes[url.path] { return cached }
        let started = epoch
        let loaded = await Task.detached(priority: .userInitiated) { () -> [PassageSentence]? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode([PassageSentence].self, from: data)
        }.value
        guard !isRetired, !isRemoving, started == epoch, let loaded else { return nil }
        textIndexes[url.path] = loaded
        return loaded
    }

    /// Removes one pair's mappings, leaving books, progress and other pairs untouched.
    func removePair(ebookStableId: String, audiobookStableId: String) async {
        let key = Self.pairKey(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId)
        let directory = directory(pairKey: key)
        epoch += 1
        await commits.enqueue(bookId: "passage|\(key)") { [self] in
            await drainWrites()
            sets[key] = nil
            unsaved[key] = nil
            textIndexes = textIndexes.filter { !$0.key.hasPrefix(directory.path) }
            await Task.detached { try? FileManager.default.removeItem(at: directory) }.value
            changeCount += 1
        }
    }

    /// Removes every pair's mappings and sentence index. Analysis checkpoints and media identities are kept.
    func removeAll() async {
        let pairs = root.appendingPathComponent("pairs", isDirectory: true)
        epoch += 1
        isRemoving = true
        sets.removeAll()
        unsaved.removeAll()
        textIndexes.removeAll()
        await drainWrites()
        await Task.detached { try? FileManager.default.removeItem(at: pairs) }.value
        // A load that started during removal may have read the old files.
        epoch += 1
        sets.removeAll()
        textIndexes.removeAll()
        isRemoving = false
        changeCount += 1
    }

    func storageBytes() async -> (mappings: Int64, acoustic: Int64) {
        let root = root
        let acoustic = acousticDirectory
        return await Task.detached(priority: .utility) {
            let acousticBytes = Self.directorySize(acoustic)
            return (Self.directorySize(root) - acousticBytes, acousticBytes)
        }.value
    }

    /// Keeps the directory itself: a running analyzer writes its next checkpoint there.
    func clearAcousticCheckpoints() async {
        let acoustic = acousticDirectory
        await Task.detached {
            let files = (try? FileManager.default.contentsOfDirectory(at: acoustic, includingPropertiesForKeys: nil)) ?? []
            for file in files { try? FileManager.default.removeItem(at: file) }
        }.value
        changeCount += 1
    }

    #if os(iOS)
    // Preparation is iOS-only; tvOS has no important-usage capacity key.
    nonisolated func availableCapacity() async -> Int64? {
        let volume = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return await Task.detached(priority: .utility) {
            (try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        }.value
    }
    #endif

    /// Evicts least-recently-used acoustic windows until the profile is under its limit.
    /// Returns false when pinned files alone exceed the limit, which pauses new preparation.
    func enforceAcousticLimit(pinned: Set<String> = [], limit: Int64 = PassageAlignmentStore.acousticLimitBytes) async -> Bool {
        let directory = acousticDirectory
        return await Task.detached(priority: .utility) {
            Self.evict(directory: directory, pinned: pinned, limit: limit)
        }.value
    }

    /// After retirement returns no write is still running, so deleting the profile cannot be undone by a late save.
    func retire() async {
        await flush()
        isRetired = true
        epoch += 1
        await commits.retire()
        await drainWrites()
        sets.removeAll()
        textIndexes.removeAll()
    }

    private func drainWrites() async {
        for write in Array(writes.values) { _ = await write.value }
    }

    private func write<Value: Encodable & Sendable>(_ value: Value, to url: URL) async -> Bool {
        guard !isRetired, !isRemoving else { return false }
        let id = UUID()
        let task = Task.detached(priority: .utility) { () -> Bool in
            do {
                let data = try JSONEncoder().encode(value)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutable = url
                try? mutable.setResourceValues(values)
                return true
            } catch {
                return false
            }
        }
        writes[id] = task
        let succeeded = await task.value
        writes[id] = nil
        if !succeeded { AppLogger.general.warning("[PassageAlignment] Could not save prepared passages") }
        return succeeded
    }

    nonisolated static func evict(directory: URL, pinned: Set<String>, limit: Int64) -> Bool {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return true }
        var entries = files.compactMap { url -> (url: URL, size: Int64, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let size = values.fileSize else { return nil }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return true }
        entries.sort { $0.date < $1.date }
        for entry in entries where !pinned.contains(entry.url.lastPathComponent) {
            guard total > limit else { break }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
        return total <= limit
    }

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
