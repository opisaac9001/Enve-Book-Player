import Foundation

public struct CTCAlignmentProbeSentence: Codable, Sendable {
    public let chapterID: String
    public let chapter: String
    public let sentenceID: Int
    public let text: String
    public let start: Double
    public let end: Double
    public let meanLogProbability: Float
}

public struct CTCAlignmentProbeResult: Codable, Sendable {
    public let recognizedText: String
    public let anchorCount: Int
    public let firstChapter: String?
    public let audioSeconds: Double
    public let elapsedSeconds: Double
    public let frameCount: Int
    public let acceptedSentenceCount: Int
    public let sentenceRanges: [CTCAlignmentProbeSentence]
}

public extension StoryAligner {
    func probeCTC(epubURL: URL, audioURL: URL, modelDirectory: URL, sessionDirectory: URL, start: Double = 0, duration: Double = 30, executionProvider: QuartzNetExecutionProvider? = nil) async throws -> CTCAlignmentProbeResult {
        guard start.isFinite, start >= 0, duration.isFinite, (1...38).contains(duration) else {
            throw StoryAlignError("A CTC probe requires a valid audio position and a duration between 1 and 38 seconds.")
        }
        let request = try AlignmentRequest(epubURL: epubURL, audioBookURLs: [audioURL], sessionDir: sessionDirectory.path)
        let session = AlignmentSession(request: request, config: AlignmentConfig(concurrency: 1))
        let epub = try await EpubParser(session: session).parse(url: epubURL)
        let model = try QuartzNetModel(directory: modelDirectory, provider: executionProvider)
        let index = CTCTextIndex(chapters: epub.spineOrderedManifest, vocabulary: model.vocabulary)
        let began = Date()
        let samples = try await CTCAudioReader.read(url: audioURL, start: start, duration: duration)
        let emissions = try model.emissions(samples: samples)
        let decoded = CTCTextIndex.decode(emissions, blank: model.blank, space: model.space)
        let anchors = try index.anchors(for: decoded)
        let audioSeconds = Double(samples.count) / 16_000
        let audio = AudioFile(startTmeInterval: 0, endTmeInterval: start + audioSeconds, filePath: audioURL, index: 0)
        let matches = try CTCWindowMatcher.match(emissions: emissions, anchors: anchors, index: index, audio: audio, start: start, blank: model.blank)
        let sentenceRanges = try CTCWindowMatcher.ordered(matches).map { match in
            let sentence = match.candidate.sentence
            let chapter = epub.spineOrderedManifest[index.sentences[match.index].chapter]
            return CTCAlignmentProbeSentence(chapterID: chapter.id, chapter: chapter.name, sentenceID: sentence.sentenceId, text: sentence.xhtmlSentence, start: sentence.sentenceRange.start, end: sentence.sentenceRange.end, meanLogProbability: match.candidate.score)
        }
        let reverse = Dictionary(uniqueKeysWithValues: model.vocabulary.map { ($0.value, $0.key) })
        let chapter = anchors.first.flatMap { first in
            index.sentences.first { $0.range.contains(first.character) }.map { epub.spineOrderedManifest[$0.chapter].name }
        }
        return CTCAlignmentProbeResult(recognizedText: String(decoded.labels.compactMap { reverse[$0] }), anchorCount: anchors.count, firstChapter: chapter, audioSeconds: audioSeconds, elapsedSeconds: Date().timeIntervalSince(began), frameCount: emissions.frames, acceptedSentenceCount: sentenceRanges.count, sentenceRanges: sentenceRanges)
    }
}
