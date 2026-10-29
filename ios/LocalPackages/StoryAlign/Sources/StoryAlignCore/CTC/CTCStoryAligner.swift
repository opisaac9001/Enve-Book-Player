import CryptoKit
import Foundation

public struct CTCAlignmentConfiguration: Sendable {
    public let modelDirectory: URL
    public let chunkDuration: TimeInterval
    public let overlapDuration: TimeInterval
    public let executionProvider: QuartzNetExecutionProvider?

    public init(modelDirectory: URL, chunkDuration: TimeInterval = 38, overlapDuration: TimeInterval = 8, executionProvider: QuartzNetExecutionProvider? = nil) {
        self.modelDirectory = modelDirectory
        self.chunkDuration = chunkDuration
        self.overlapDuration = overlapDuration
        self.executionProvider = executionProvider
    }
}

private struct CTCCheckpoint: Codable, Sendable {
    let identity: String
    let emissions: CTCEmissions
}

private enum CTCPreparedWindow: Sendable {
    case checkpoint(CTCEmissions)
    case samples([Float])
}

private struct CTCAudioWindow: Sendable {
    let start: Double
    let duration: Double
    let checkpointURL: URL

    func load(audioURL: URL, identity: String, secondsPerFrame: Double) async throws -> CTCPreparedWindow {
        try Task.checkCancellation()
        if let data = try? Data(contentsOf: checkpointURL),
           let checkpoint = try? PropertyListDecoder().decode(CTCCheckpoint.self, from: data),
           checkpoint.identity == identity, checkpoint.emissions.classes == 29,
           checkpoint.emissions.frames > 0,
           checkpoint.emissions.frames <= Int(ceil(duration / secondsPerFrame)) + 2,
           checkpoint.emissions.secondsPerFrame == secondsPerFrame,
           checkpoint.emissions.values.count == checkpoint.emissions.frames * 29,
           checkpoint.emissions.values.allSatisfy({ $0.isFinite }) {
            return .checkpoint(checkpoint.emissions)
        }
        return .samples(try await CTCAudioReader.read(url: audioURL, start: start, duration: duration))
    }
}

struct CTCSentenceCandidate {
    let sentence: AlignedSentence
    let score: Float
}


enum CTCWindowMatcher {
    static func match(emissions: CTCEmissions, anchors: [CTCTextAnchor], index: CTCTextIndex, audio: AudioFile, start: Double, blank: Int) throws -> [Int: CTCSentenceCandidate] {
        guard let first = anchors.first, let last = anchors.last, last.character > first.character else { return [:] }
        let slope = Double(last.frame - first.frame) / Double(last.character - first.character)
        guard slope > 0.5 && slope < 25 else { return [:] }
        var candidates: [Int: CTCSentenceCandidate] = [:]
        for (sentenceIndex, sentence) in index.sentences.enumerated() {
            guard sentence.range.count >= 3,
                  sentence.range.lowerBound >= first.character - 200,
                  sentence.range.upperBound <= last.character + 210 else { continue }
            let estimatedStart = Double(first.frame) + Double(sentence.range.lowerBound - first.character) * slope
            let estimatedEnd = Double(first.frame) + Double(sentence.range.upperBound - first.character) * slope
            guard estimatedStart >= -25, estimatedEnd <= Double(emissions.frames) + 25 else { continue }
            let lower = max(0, Int(floor(estimatedStart)) - 150)
            let upper = min(emissions.frames, Int(ceil(estimatedEnd)) + 150)
            guard upper > lower else { continue }
            let target = Array(index.labels[sentence.range])
            guard let aligned = try CTCForcedAligner.align(emissions.slice(lower..<upper), labels: target, blank: blank),
                  let firstCharacter = aligned.first, let lastCharacter = aligned.last else { continue }
            let score = aligned.reduce(Float.zero) { $0 + $1.meanLogProbability } / Float(aligned.count)
            let supported = aligned.filter { $0.meanLogProbability > -3 }.count
            guard score > -2.5, supported * 4 >= aligned.count * 3,
                  zip(aligned, aligned.dropFirst()).allSatisfy({ $1.startFrame - $0.endFrame < 150 }) else { continue }
            let begin = max(0, start + Double(lower + firstCharacter.startFrame) * emissions.secondsPerFrame - 0.28)
            let end = min(audio.duration, start + Double(lower + lastCharacter.endFrame) * emissions.secondsPerFrame - 0.12)
            guard end > begin + 0.04,
                  Double(target.count) / (end - begin) < 60,
                  Double(target.count) / (end - begin) > 1 else { continue }
            let range = SentenceRange(id: sentence.sentence, start: begin, end: end, audioFile: audio, timeStamps: [])
            let result = AlignedSentence(xhtmlSentence: sentence.text, sentenceId: sentence.sentence, sentenceRange: range, matchText: nil, matchOffset: nil, matchType: nil)
            candidates[sentenceIndex] = CTCSentenceCandidate(sentence: result, score: score)
        }
        return candidates
    }

    static func ordered(_ candidates: [Int: CTCSentenceCandidate]) throws -> [(index: Int, candidate: CTCSentenceCandidate)] {
        try CTCSentenceChain.ordered(candidates)
    }

}

public extension StoryAligner {
    func alignStory(session: AlignmentSession, ctcConfiguration: CTCAlignmentConfiguration) async throws -> AlignmentResult {
        guard session.config.granularity == .sentence, session.config.granularityExpansion == nil else {
            throw StoryAlignError("QuartzNet currently supports sentence-level alignment without granularity expansion.")
        }
        guard ctcConfiguration.chunkDuration.isFinite, (10...38).contains(ctcConfiguration.chunkDuration),
              ctcConfiguration.overlapDuration.isFinite, (2...12).contains(ctcConfiguration.overlapDuration),
              ctcConfiguration.overlapDuration < ctcConfiguration.chunkDuration / 2 else {
            throw StoryAlignError("Invalid QuartzNet audio window configuration.")
        }
        let epub = try await EpubParser(session: session).parse(url: session.request.epubURL)
        let audiobook = try await AudioFileProcessor(session: session).processOriginalAudio(audioURLs: session.request.audioBookURLs, epub: epub)
        session.progressTracker.updateProgress(for: .model, event: .start, total: 1)
        let model = try QuartzNetModel(directory: ctcConfiguration.modelDirectory, provider: ctcConfiguration.executionProvider)
        session.logger.log(.info, "QuartzNet selected \(model.executionProvider.rawValue) execution provider")
        session.progressTracker.updateProgress(for: .model, event: .end)
        let chapters = try selectedChapters(epub: epub, config: session.config)
        let index = CTCTextIndex(chapters: chapters, vocabulary: model.vocabulary)
        guard index.labels.count >= 20, !audiobook.audioFiles.isEmpty else {
            throw StoryAlignError("The ebook or audiobook does not contain enough readable content for alignment.")
        }
        let identity = try checkpointIdentity(session: session, configuration: ctcConfiguration)
        let cache = session.request.sessionDir.appendingPathComponent("ctc-emissions", isDirectory: true).appendingPathComponent(identity, isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var candidates: [Int: CTCSentenceCandidate] = [:]
        let totalSeconds = audiobook.audioFiles.reduce(0) { $0 + $1.duration }
        session.progressTracker.updateProgress(for: .transcribe, event: .start, total: Int(ceil(totalSeconds)))
        var completedSeconds = 0.0
        for audio in audiobook.audioFiles {
            var windows: [CTCAudioWindow] = []
            var start = 0.0
            while start < audio.duration {
                let duration = min(ctcConfiguration.chunkDuration, audio.duration - start)
                if duration < 0.1 { break }
                let key = "\(audio.index)-\(Int((start * 16_000).rounded())).plist"
                windows.append(CTCAudioWindow(start: start, duration: duration, checkpointURL: cache.appendingPathComponent(key)))
                start += ctcConfiguration.chunkDuration - ctcConfiguration.overlapDuration
            }
            var previousWindow: CTCEmissionWindow?
            let secondsPerFrame = model.secondsPerFrame
            try await CTCDecodeAhead.forEach(inputs: windows, load: { window in
                try await window.load(audioURL: audio.filePath, identity: identity, secondsPerFrame: secondsPerFrame)
            }, consume: { window, prepared in
                try Task.checkCancellation()
                let emissions: CTCEmissions
                let inferred: Bool
                switch prepared {
                case .checkpoint(let cached):
                    emissions = cached
                    inferred = false
                case .samples(let samples):
                    if samples.count <= 512 { return }
                    let providerBeforeInference = model.executionProvider
                    emissions = try model.emissions(samples: samples)
                    if model.executionProvider != providerBeforeInference {
                        session.logger.log(.info, "QuartzNet switched to CPU after accelerated inference failed")
                    }
                    inferred = true
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .binary
                    try encoder.encode(CTCCheckpoint(identity: identity, emissions: emissions)).write(to: window.checkpointURL, options: .atomic)
                }
                let currentWindow = CTCEmissionWindow(start: window.start, emissions: emissions)
                let alignmentWindow = try previousWindow.map { try $0.joining(currentWindow) } ?? currentWindow
                let decoded = CTCTextIndex.decode(alignmentWindow.emissions, blank: model.blank, space: model.space)
                let anchors = try index.anchors(for: decoded)
                let matches = try CTCWindowMatcher.match(emissions: alignmentWindow.emissions, anchors: anchors, index: index, audio: audio, start: alignmentWindow.start, blank: model.blank)
                for (sentenceIndex, candidate) in matches {
                    if let existing = candidates[sentenceIndex], existing.score >= candidate.score { continue }
                    candidates[sentenceIndex] = candidate
                }
                previousWindow = currentWindow
                let next = window.start + ctcConfiguration.chunkDuration - ctcConfiguration.overlapDuration
                session.progressTracker.updateProgress(for: .transcribe, increment: Int(max(0, min(audio.duration, next) - window.start)))
                if inferred {
                    #if os(iOS)
                    let delay: Duration
                    switch ProcessInfo.processInfo.thermalState {
                    case .nominal: delay = .milliseconds(250)
                    case .fair: delay = model.executionProvider == .coreMLNeuralEngine ? .milliseconds(500) : .seconds(2)
                    case .serious, .critical: delay = .seconds(2)
                    @unknown default: delay = .seconds(2)
                    }
                    try await Task.sleep(for: delay)
                    #endif
                }
            })
            completedSeconds += audio.duration
            session.logger.log(.info, "QuartzNet analyzed \(Int(completedSeconds)) of \(Int(totalSeconds)) audio seconds; \(candidates.count) sentence candidates")
        }
        session.progressTracker.updateProgress(for: .transcribe, event: .end)
        session.progressTracker.updateProgress(for: .align, event: .start, total: index.sentences.count)
        var byChapter: [Int: [AlignedSentence]] = [:]
        for match in try CTCWindowMatcher.ordered(candidates) {
            byChapter[index.sentences[match.index].chapter, default: []].append(match.candidate.sentence)
        }
        let accepted = byChapter.values.reduce(0) { $0 + $1.count }
        let quality = CTCAlignmentQuality(
            eligibleSentenceCount: index.sentences.filter { $0.range.count >= 3 }.count,
            acceptedSentenceCount: accepted,
            audioCoverage: min(1, byChapter.values.flatMap { $0 }.reduce(0) { $0 + $1.sentenceRange.duration } / totalSeconds)
        )
        guard quality.isUsable else {
            throw StoryAlignError("QuartzNet matched \(accepted) of \(quality.eligibleSentenceCount) sentences (\(Int(quality.coverage * 100))%). At least 70% is required. Check that the audio and text are the same edition and language.")
        }
        let alignedChapters = chapters.enumerated().map { chapter, item in
            AlignedChapter(manifestItem: item, alignedSentences: byChapter[chapter] ?? [])
        }
        session.progressTracker.updateProgress(for: .align, increment: accepted)
        session.progressTracker.updateProgress(for: .align, event: .end)
        session.logger.log(.info, "QuartzNet accepted \(accepted) of \(index.sentences.count) ebook sentences")
        try await EpubXmlUpdater(session: session).update(epub: epub, audioBook: audiobook, alignedChapters: alignedChapters, includeUnalignedSentences: true)
        try Task.checkCancellation()
        let metadataURL = epub.unzippedURL.appendingPathComponent("META-INF/enve-ctc-quality.json")
        try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(quality).write(to: metadataURL, options: .atomic)
        let output = session.request.sessionDir.appendingPathComponent(session.request.epubURL.deletingPathExtension().lastPathComponent + "_narrated.epub")
        try EpubExporter(session: session).export(eBook: epub, to: output)
        return AlignmentResult(alignedEpubURL: output, report: nil, ctcQuality: quality)
    }

    private func selectedChapters(epub: EpubDocument, config: AlignmentConfig) throws -> [EpubManifestItem] {
        let items = epub.spineOrderedManifest
        let start = config.startManifestItemId.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let end = config.endManifestItemId.flatMap { id in items.firstIndex { $0.id == id } } ?? (items.count - 1)
        guard start <= end, items.indices.contains(start), items.indices.contains(end) else {
            throw StoryAlignError("No readable EPUB chapters were selected.")
        }
        return Array(items[start...end])
    }

    private func checkpointIdentity(session: AlignmentSession, configuration: CTCAlignmentConfiguration) throws -> String {
        var components = ["ctc-original-audio-v3", QuartzNetModelPackage.identifier, "frontend-signal-pts-v2", "\(configuration.chunkDuration)", "\(configuration.overlapDuration)"]
        for url in session.request.audioBookURLs {
            components.append(try QuartzNetModelPackage.digest(url))
        }
        return SHA256.hash(data: Data(components.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
