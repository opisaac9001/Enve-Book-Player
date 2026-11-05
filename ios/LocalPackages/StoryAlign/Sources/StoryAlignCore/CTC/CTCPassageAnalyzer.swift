import CryptoKit
import Foundation

public struct CTCPassageSentence: Codable, Sendable, Hashable {
    public let chapter: Int
    public let sentence: Int
    public let href: String
    public let text: String
    public let chapterProgression: Double
    public let totalProgression: Double
}

public struct CTCPassageMatch: Codable, Sendable, Hashable {
    public let sentenceIndex: Int
    public let start: Double
    public let end: Double
    public let score: Float

    public init(sentenceIndex: Int, start: Double, end: Double, score: Float) {
        self.sentenceIndex = sentenceIndex
        self.start = start
        self.end = end
        self.score = score
    }
}

public struct CTCPassageWindowResult: Sendable {
    public let trackIndex: Int
    public let window: CTCPassageWindow
    public let matches: [CTCPassageMatch]
    public let anchorCount: Int
    public let inferredWindows: Int
    public let executionProvider: QuartzNetExecutionProvider

    /// Local acceptance: an unambiguous anchor region with at least three ordered sentences.
    public var isAccepted: Bool { matches.count >= 3 }
}

/// A fixed analysis grid per track. A window owns the sentences that end inside `ownedEnds`; because it is
/// analyzed joined with its predecessor, any such sentence lies wholly inside the analyzed audio, and
/// adjacent windows tile the track so each sentence is finalized exactly once.
public struct CTCPassageWindow: Codable, Sendable, Hashable, Comparable {
    static let seamMargin = 0.25

    public let index: Int
    public let start: Double
    public let end: Double
    public let ownedEndStart: Double
    public let ownedEndLimit: Double

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.index < rhs.index }

    public static func grid(trackDuration: Double, chunk: Double = 38, overlap: Double = 8) -> [CTCPassageWindow] {
        guard trackDuration.isFinite, trackDuration > 0.1 else { return [] }
        let step = chunk - overlap
        var windows: [CTCPassageWindow] = []
        var start = 0.0
        var ownedStart = 0.0
        while start < trackDuration {
            let end = min(trackDuration, start + chunk)
            if end - start < 0.1 { break }
            let isLast = end >= trackDuration
            let ownedLimit = isLast ? .greatestFiniteMagnitude : end - seamMargin
            windows.append(CTCPassageWindow(index: windows.count, start: start, end: end, ownedEndStart: ownedStart, ownedEndLimit: ownedLimit))
            if isLast { break }
            ownedStart = ownedLimit
            start += step
        }
        return windows
    }

    /// The window that owns a sentence ending at `time`.
    public static func owner(ofEnd time: Double, in grid: [CTCPassageWindow]) -> CTCPassageWindow? {
        grid.first { $0.owns(end: time) } ?? grid.first
    }

    public func owns(end: Double) -> Bool {
        end >= ownedEndStart && end < ownedEndLimit
    }
}

/// Reusable QuartzNet passage analysis. Holds one model session and one text index for a book so
/// windows can be analyzed in any order without rebuilding either.
public actor CTCPassageAnalyzer {
    public nonisolated let sentences: [CTCPassageSentence]
    public nonisolated let modelIdentifier = QuartzNetModelPackage.identifier
    private let index: CTCTextIndex
    private let modelDirectory: URL
    private let preferredProvider: QuartzNetExecutionProvider?
    private let checkpointDirectory: URL
    private var model: QuartzNetModel?
    /// Each window is joined with its predecessor, which was usually analyzed just before it.
    private var recent: [(identity: String, emissions: CTCEmissions)] = []
    private static let checkpointVersion = "ctc-passage-v2"

    public init(epubURL: URL, modelDirectory: URL, workingDirectory: URL, checkpointDirectory: URL, executionProvider: QuartzNetExecutionProvider? = nil) async throws {
        guard QuartzNetModelPackage.isSupported else {
            throw StoryAlignError("QuartzNet alignment is unavailable on this platform.")
        }
        let parsed = try await Self.parse(epubURL: epubURL, workingDirectory: workingDirectory)
        let model = try QuartzNetModel(directory: modelDirectory, provider: executionProvider)
        let index = CTCTextIndex(chapters: parsed.chapters, vocabulary: model.vocabulary)
        guard index.labels.count >= 20 else {
            throw StoryAlignError("The ebook does not contain enough readable content for alignment.")
        }
        self.sentences = parsed.sentences
        self.index = index
        self.model = model
        self.modelDirectory = modelDirectory
        self.preferredProvider = executionProvider
        self.checkpointDirectory = checkpointDirectory
        try FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)
    }

    public var executionProvider: QuartzNetExecutionProvider? { model?.executionProvider }

    /// Drops the native session under memory pressure; the next window recreates it.
    public func releaseModel() {
        model = nil
        recent.removeAll()
    }

    /// Analyzes one grid window joined with its predecessor so sentences crossing the seam are complete.
    /// `audioIdentity` must be a verified content identity for the track; it keys reusable acoustic checkpoints.
    public func analyze(window: CTCPassageWindow, previous: CTCPassageWindow?, audioURL: URL, audioIdentity: String, trackIndex: Int, trackDuration: Double) async throws -> CTCPassageWindowResult {
        try Task.checkCancellation()
        let model = try loadedModel()
        var inferred = 0
        let current = try await emissions(for: window, audioURL: audioURL, audioIdentity: audioIdentity, trackIndex: trackIndex, model: model, inferred: &inferred)
        guard let current else {
            return CTCPassageWindowResult(trackIndex: trackIndex, window: window, matches: [], anchorCount: 0, inferredWindows: inferred, executionProvider: model.executionProvider)
        }
        var earlier: CTCEmissionWindow?
        if let previous, previous.end > window.start,
           let emissions = try await emissions(for: previous, audioURL: audioURL, audioIdentity: audioIdentity, trackIndex: trackIndex, model: model, inferred: &inferred) {
            earlier = CTCEmissionWindow(start: previous.start, emissions: emissions)
        }
        try Task.checkCancellation()
        let audio = AudioFile(startTmeInterval: 0, endTmeInterval: trackDuration, filePath: audioURL, index: trackIndex)
        let finalized = try Self.finalizedMatches(window: window, previous: earlier, current: CTCEmissionWindow(start: window.start, emissions: current), index: index, audio: audio, blank: model.blank, space: model.space)
        return CTCPassageWindowResult(trackIndex: trackIndex, window: window, matches: finalized.matches, anchorCount: finalized.anchorCount, inferredWindows: inferred, executionProvider: model.executionProvider)
    }

    /// Matches sentences over the window joined with its predecessor, keeping only chain-ordered sentences
    /// this window owns that lie wholly inside the analyzed audio.
    static func finalizedMatches(window: CTCPassageWindow, previous: CTCEmissionWindow?, current: CTCEmissionWindow, index: CTCTextIndex, audio: AudioFile, blank: Int, space: Int?) throws -> (matches: [CTCPassageMatch], anchorCount: Int) {
        let joined = try previous.map { try $0.joining(current) } ?? current
        let decoded = CTCTextIndex.decode(joined.emissions, blank: blank, space: space)
        let anchors = try index.anchors(for: decoded)
        let candidates = try CTCWindowMatcher.match(emissions: joined.emissions, anchors: anchors, index: index, audio: audio, start: joined.start, blank: blank)
        let joinedEnd = joined.start + Double(joined.emissions.frames) * joined.emissions.secondsPerFrame
        let trackDuration = audio.duration
        let matches = try CTCSentenceChain.ordered(candidates).compactMap { item -> CTCPassageMatch? in
            let range = item.candidate.sentence.sentenceRange
            guard window.owns(end: range.end), range.start >= joined.start,
                  range.end <= min(joinedEnd, trackDuration) + 0.05
            else { return nil }
            return CTCPassageMatch(sentenceIndex: item.index, start: range.start, end: range.end, score: item.candidate.score)
        }
        return (matches, anchors.count)
    }

    private func loadedModel() throws -> QuartzNetModel {
        if let model { return model }
        let created = try QuartzNetModel(directory: modelDirectory, provider: preferredProvider)
        model = created
        return created
    }

    /// One Float32 blob: a property list of individual numbers was more than twice the size and slow to decode.
    private struct Checkpoint: Codable {
        let identity: String
        let frames: Int
        let classes: Int
        let secondsPerFrame: Double
        let values: Data

        init(identity: String, emissions: CTCEmissions) {
            self.identity = identity
            frames = emissions.frames
            classes = emissions.classes
            secondsPerFrame = emissions.secondsPerFrame
            values = emissions.values.withUnsafeBufferPointer { Data(buffer: $0) }
        }

        var emissions: CTCEmissions? {
            let stride = MemoryLayout<Float>.stride
            guard values.count % stride == 0 else { return nil }
            let floats = [Float](unsafeUninitializedCapacity: values.count / stride) { buffer, count in
                count = values.copyBytes(to: buffer) / stride
            }
            return CTCEmissions(values: floats, frames: frames, classes: classes, secondsPerFrame: secondsPerFrame)
        }
    }

    private func remember(_ emissions: CTCEmissions, identity: String) {
        recent.removeAll { $0.identity == identity }
        recent.append((identity, emissions))
        if recent.count > 2 { recent.removeFirst() }
    }

    private func emissions(for window: CTCPassageWindow, audioURL: URL, audioIdentity: String, trackIndex: Int, model: QuartzNetModel, inferred: inout Int) async throws -> CTCEmissions? {
        let identity = [Self.checkpointVersion, QuartzNetModelPackage.identifier, audioIdentity, "\(trackIndex)", "\(window.start)", "\(window.end)"].joined(separator: "|")
        if let cached = recent.first(where: { $0.identity == identity }) { return cached.emissions }
        let key = SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let url = checkpointDirectory.appendingPathComponent("\(key).plist")
        if let data = try? Data(contentsOf: url),
           let checkpoint = try? PropertyListDecoder().decode(Checkpoint.self, from: data),
           checkpoint.identity == identity, let stored = checkpoint.emissions,
           Self.isValid(stored, duration: window.end - window.start, secondsPerFrame: model.secondsPerFrame) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            remember(stored, identity: identity)
            return stored
        }
        let samples = try await CTCAudioReader.read(url: audioURL, start: window.start, duration: window.end - window.start)
        guard samples.count > 512 else { return nil }
        try Task.checkCancellation()
        let emissions = try model.emissions(samples: samples)
        inferred += 1
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(Checkpoint(identity: identity, emissions: emissions)).write(to: url, options: .atomic)
        remember(emissions, identity: identity)
        return emissions
    }

    static func isValid(_ emissions: CTCEmissions, duration: Double, secondsPerFrame: Double) -> Bool {
        emissions.classes == 29 && emissions.frames > 0
            && emissions.frames <= Int(ceil(duration / secondsPerFrame)) + 2
            && emissions.secondsPerFrame == secondsPerFrame
            && emissions.values.count == emissions.frames * 29
            && emissions.values.allSatisfy { $0.isFinite }
    }

    /// The segmented original sentences in the same order and identity the analyzer uses, without a model.
    public static func sentences(epubURL: URL, workingDirectory: URL) async throws -> [CTCPassageSentence] {
        try await parse(epubURL: epubURL, workingDirectory: workingDirectory).sentences
    }

    private static func parse(epubURL: URL, workingDirectory: URL) async throws -> (chapters: [EpubManifestItem], sentences: [CTCPassageSentence]) {
        let parseDirectory = workingDirectory.appendingPathComponent("epub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parseDirectory) }
        let request = try AlignmentRequest(epubURL: epubURL, audioBookURLs: [], sessionDir: parseDirectory.path)
        let session = AlignmentSession(request: request, config: AlignmentConfig(concurrency: 1))
        let epub = try await EpubParser(session: session).parse(url: epubURL)
        let chapters = epub.spineOrderedManifest
        return (chapters, sentences(chapters: chapters, root: epub.unzippedURL))
    }

    /// Readium's reflowable positions are proportional to resource length (one per 1024 bytes), so
    /// totalProgression follows that scale. Chapter offsets count UTF-16 units like the reader DOM.
    static func sentences(chapters: [EpubManifestItem], root: URL) -> [CTCPassageSentence] {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let positions = chapters.map { max(1, Int(ceil(Double($0.xmlData?.count ?? 0) / 1024))) }
        let totalPositions = Double(max(1, positions.reduce(0, +)))
        var result: [CTCPassageSentence] = []
        var startPosition = 0
        for (chapterIndex, chapter) in chapters.enumerated() {
            let path = chapter.filePath?.resolvingSymlinksInPath().standardizedFileURL.path ?? chapter.href
            let href = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : chapter.href
            let total = max(1, chapter.xhtmlSentences.reduce(0) { $0 + $1.utf16.count })
            var offset = 0
            for (sentenceIndex, text) in chapter.xhtmlSentences.enumerated() {
                let chapterProgression = min(1, Double(offset) / Double(total))
                offset += text.utf16.count
                let position = Double(startPosition) + chapterProgression * Double(positions[chapterIndex])
                result.append(CTCPassageSentence(
                    chapter: chapterIndex, sentence: sentenceIndex, href: href, text: text,
                    chapterProgression: chapterProgression, totalProgression: min(1, position / totalPositions)
                ))
            }
            startPosition += positions[chapterIndex]
        }
        return result
    }
}
