@preconcurrency import AVFoundation
import Accelerate
import Foundation

struct LinkedBookFallbackAlignmentResult: Sendable {
    let anchors: [LinkedBookCalibrationAnchor]
    let acousticMatchCount: Int
}

@MainActor
final class LinkedBookLegacyAlignmentService {
    static let shared = LinkedBookLegacyAlignmentService()

    private let speechRenderer = LinkedBookSpeechRenderer()
    private let sampleFractions = [0.08, 0.29, 0.50, 0.71, 0.92]
    private let sampleDuration: TimeInterval = 22

    private init() {}

    func cancel() {
        speechRenderer.cancel()
    }

    func align(
        chunks: [EbookContextChunk],
        tracks: [AudioTrackInfo],
        chapters: [Chapter],
        language: String?,
        progress: @escaping @MainActor (_ sample: Int, _ total: Int, _ matches: Int) -> Void
    ) async throws -> LinkedBookFallbackAlignmentResult {
        let index = LinkedBookPassageIndex(chunks: chunks)
        guard !index.isEmpty else {
            throw LinkedBookQuickSyncError.emptyEbook
        }

        let timeline = tracks.compactMap { track -> LinkedBookLocalAudioTrack? in
            guard let url = URL(string: track.contentUrl), url.isFileURL else { return nil }
            return LinkedBookLocalAudioTrack(
                url: url,
                startOffset: track.startOffset,
                duration: track.duration
            )
        }
        let totalDuration = tracks.totalDuration
        guard !timeline.isEmpty, totalDuration > sampleDuration else {
            throw AudiobookTimelineError.noPlayableAudio
        }

        var anchors = structuralAnchors(
            chunks: chunks,
            chapters: chapters,
            duration: totalDuration
        )
        var acousticMatches = 0

        for (sampleIndex, audioProgress) in sampleFractions.enumerated() {
            try Task.checkCancellation()
            progress(sampleIndex + 1, sampleFractions.count, acousticMatches)

            let expectedProgress = interpolatedEbookProgress(
                for: audioProgress,
                anchors: anchors
            )
            let candidates = index.passages(
                near: expectedProgress,
                offsets: [-0.035, 0, 0.035]
            )
            guard candidates.count >= 2 else { continue }

            let center = min(
                max(totalDuration * audioProgress, sampleDuration / 2),
                totalDuration - sampleDuration / 2
            )
            let windowDuration = sampleDuration
            let audioSamples: [Float]
            do {
                audioSamples = try await Task.detached(priority: .utility) {
                    try LinkedBookAudioFingerprint.readWindow(
                        centeredAt: center,
                        duration: windowDuration,
                        tracks: timeline
                    )
                }.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            let audioFeatures = await Task.detached(priority: .utility) {
                LinkedBookAudioFingerprint.features(from: audioSamples)
            }.value
            guard audioFeatures.count >= 20 else { continue }

            var scored: [(passage: LinkedBookPassage, distance: Float)] = []
            for candidate in candidates {
                try Task.checkCancellation()
                let rendered: [Float]
                do {
                    rendered = try await speechRenderer.render(
                        candidate.text,
                        language: language
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
                let candidateFeatures = await Task.detached(priority: .utility) {
                    LinkedBookAudioFingerprint.features(from: rendered)
                }.value
                guard candidateFeatures.count >= 20 else { continue }
                let distance = await Task.detached(priority: .utility) {
                    LinkedBookAudioFingerprint.dtwDistance(
                        candidateFeatures,
                        audioFeatures
                    )
                }.value
                scored.append((candidate, distance))
            }

            scored.sort { $0.distance < $1.distance }
            guard let best = scored.first,
                let runnerUp = scored.dropFirst().first
            else {
                continue
            }
            let separation = runnerUp.distance - best.distance
            guard best.distance < 5.2,
                separation >= max(0.10, best.distance * 0.035)
            else {
                continue
            }

            acousticMatches += 1
            let confidence = min(
                0.92,
                0.66 + Double(separation / max(runnerUp.distance, 0.001))
            )
            anchors.append(
                LinkedBookCalibrationAnchor(
                    ebookProgress: best.passage.progress,
                    audioProgress: audioProgress,
                    quote: best.passage.quote,
                    href: best.passage.href,
                    confidence: confidence
                )
            )
        }

        return LinkedBookFallbackAlignmentResult(
            anchors: anchors,
            acousticMatchCount: acousticMatches
        )
    }

    private func structuralAnchors(
        chunks: [EbookContextChunk],
        chapters: [Chapter],
        duration: TimeInterval
    ) -> [LinkedBookCalibrationAnchor] {
        let titledChunks = chunks.filter {
            $0.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        guard titledChunks.count >= 2, chapters.count >= 2, duration > 0 else {
            return []
        }

        let orderedChapters = chapters.sorted { $0.start < $1.start }
        let matches = LinkedBookChapterMapper.matches(
            ebookTitles: titledChunks.compactMap(\.title),
            audiobookTitles: orderedChapters.map(\.title)
        )
        return matches.compactMap { match in
            let chunk = titledChunks[match.ebookIndex]
            let chapter = orderedChapters[match.audiobookIndex]
            let quote = LinkedBookPassageIndex.words(in: chunk.text)
                .prefix(14)
                .joined(separator: " ")
            guard !quote.isEmpty else { return nil }
            return LinkedBookCalibrationAnchor(
                ebookProgress: chunk.startProgress,
                audioProgress: min(max(chapter.start / duration, 0), 1),
                quote: quote,
                href: chunk.href,
                confidence: min(0.88, 0.55 + match.confidence * 0.3)
            )
        }
    }

    private func interpolatedEbookProgress(
        for audioProgress: Double,
        anchors: [LinkedBookCalibrationAnchor]
    ) -> Double {
        let points =
            ([LinkedBookCalibrationPoint(ebook: 0, audio: 0)]
            + anchors.map {
                LinkedBookCalibrationPoint(
                    ebook: $0.ebookProgress,
                    audio: $0.audioProgress
                )
            }
            + [LinkedBookCalibrationPoint(ebook: 1, audio: 1)]).sorted { $0.audio < $1.audio }

        guard let upperIndex = points.firstIndex(where: { $0.audio >= audioProgress }) else {
            return audioProgress
        }
        guard upperIndex > 0 else { return points[upperIndex].ebook }
        let lower = points[upperIndex - 1]
        let upper = points[upperIndex]
        let span = upper.audio - lower.audio
        guard span > 0.0001 else { return lower.ebook }
        let fraction = (audioProgress - lower.audio) / span
        return min(max(lower.ebook + fraction * (upper.ebook - lower.ebook), 0), 1)
    }
}

private struct LinkedBookCalibrationPoint {
    let ebook: Double
    let audio: Double
}

private struct LinkedBookPassage {
    let progress: Double
    let text: String
    let quote: String
    let href: String?
}

private struct LinkedBookPassageIndex {
    private struct IndexedChunk {
        let chunk: EbookContextChunk
        let words: [String]
    }

    private let chunks: [IndexedChunk]

    init(chunks: [EbookContextChunk]) {
        self.chunks = chunks.compactMap {
            let words = Self.words(in: $0.text)
            return words.isEmpty ? nil : IndexedChunk(chunk: $0, words: words)
        }
    }

    var isEmpty: Bool {
        chunks.isEmpty
    }

    func passages(near progress: Double, offsets: [Double]) -> [LinkedBookPassage] {
        var passages: [LinkedBookPassage] = []
        for offset in offsets {
            let target = min(max(progress + offset, 0), 1)
            guard let passage = passage(at: target),
                !passages.contains(where: { abs($0.progress - passage.progress) < 0.005 })
            else {
                continue
            }
            passages.append(passage)
        }
        return passages
    }

    static func words(in text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private func passage(at progress: Double) -> LinkedBookPassage? {
        let indexed =
            chunks.first {
                progress >= $0.chunk.startProgress && progress <= $0.chunk.endProgress
            }
            ?? chunks.min {
                distance(from: progress, to: $0.chunk) < distance(from: progress, to: $1.chunk)
            }
        guard let indexed else { return nil }

        let span = max(indexed.chunk.endProgress - indexed.chunk.startProgress, 0.0001)
        let localFraction = min(
            max((progress - indexed.chunk.startProgress) / span, 0),
            1
        )
        let center = Int(localFraction * Double(max(indexed.words.count - 1, 0)))
        let lower = max(0, center - 28)
        let upper = min(indexed.words.count, lower + 56)
        guard upper - lower >= 24 else { return nil }

        let anchorIndex = min(max(center, lower), upper - 1)
        let quoteLower = max(lower, anchorIndex - 6)
        let quoteUpper = min(upper, quoteLower + 14)
        let actualProgress =
            indexed.chunk.startProgress
            + Double(anchorIndex) / Double(max(indexed.words.count - 1, 1)) * span
        return LinkedBookPassage(
            progress: min(max(actualProgress, 0), 1),
            text: indexed.words[lower..<upper].joined(separator: " "),
            quote: indexed.words[quoteLower..<quoteUpper].joined(separator: " "),
            href: indexed.chunk.href
        )
    }

    private func distance(from progress: Double, to chunk: EbookContextChunk) -> Double {
        if progress < chunk.startProgress {
            return chunk.startProgress - progress
        }
        if progress > chunk.endProgress {
            return progress - chunk.endProgress
        }
        return 0
    }
}

private struct LinkedBookLocalAudioTrack: Sendable {
    let url: URL
    let startOffset: TimeInterval
    let duration: TimeInterval
}

enum LinkedBookAudioFingerprint {
    nonisolated private static let sampleRate = 16_000.0
    nonisolated private static let frameLength = 512
    nonisolated private static let analysisLength = 400
    nonisolated private static let hopLength = 160
    nonisolated private static let melBandCount = 24
    nonisolated private static let coefficientCount = 12

    nonisolated fileprivate static func readWindow(
        centeredAt center: TimeInterval,
        duration: TimeInterval,
        tracks: [LinkedBookLocalAudioTrack]
    ) throws -> [Float] {
        guard
            let track = tracks.first(where: {
                center >= $0.startOffset && center < $0.startOffset + $0.duration
            }) ?? tracks.last
        else {
            throw AudiobookTimelineError.noPlayableAudio
        }

        let localCenter = center - track.startOffset
        let localStart = min(
            max(localCenter - duration / 2, 0),
            max(track.duration - duration, 0)
        )
        let file = try AVAudioFile(
            forReading: track.url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let sourceRate = file.processingFormat.sampleRate
        let requestedFrames = AVAudioFrameCount(
            min(duration * sourceRate, Double(UInt32.max))
        )
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: requestedFrames
            )
        else {
            throw AudiobookTimelineError.noPlayableAudio
        }

        file.framePosition = AVAudioFramePosition(localStart * sourceRate)
        try file.read(into: buffer, frameCount: requestedFrames)
        let source = monoSamples(from: buffer)
        return resample(source, from: sourceRate, to: sampleRate)
    }

    nonisolated static func features(from samples: [Float]) -> [[Float]] {
        guard samples.count >= analysisLength else { return [] }
        let normalized = normalizeAmplitude(samples)
        let frameCount = 1 + (normalized.count - analysisLength) / hopLength
        let log2Length = vDSP_Length(log2(Float(frameLength)))
        guard let setup = vDSP_create_fftsetup(log2Length, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: analysisLength)
        vDSP_hann_window(&window, vDSP_Length(analysisLength), Int32(vDSP_HANN_NORM))
        var result: [[Float]] = []
        result.reserveCapacity(frameCount / 2)

        for frameIndex in 0..<frameCount {
            let start = frameIndex * hopLength
            var frame = [Float](repeating: 0, count: frameLength)
            for index in 0..<analysisLength {
                frame[index] = normalized[start + index] * window[index]
            }

            let energy =
                frame.prefix(analysisLength).reduce(Float.zero) {
                    $0 + $1 * $1
                } / Float(analysisLength)
            guard energy > 0.00002 else { continue }

            var real = [Float](repeating: 0, count: frameLength / 2)
            var imaginary = [Float](repeating: 0, count: frameLength / 2)
            var magnitudes = [Float](repeating: 0, count: frameLength / 2)
            frame.withUnsafeBufferPointer { framePointer in
                real.withUnsafeMutableBufferPointer { realPointer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                        var split = DSPSplitComplex(
                            realp: realPointer.baseAddress!,
                            imagp: imaginaryPointer.baseAddress!
                        )
                        framePointer.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self,
                            capacity: frameLength / 2
                        ) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(frameLength / 2))
                        }
                        vDSP_fft_zrip(
                            setup,
                            &split,
                            1,
                            log2Length,
                            FFTDirection(kFFTDirection_Forward)
                        )
                        vDSP_zvmags(
                            &split,
                            1,
                            &magnitudes,
                            1,
                            vDSP_Length(frameLength / 2)
                        )
                    }
                }
            }

            let melEnergies = melFilterBank(magnitudes)
            result.append(dct(logEnergies: melEnergies))
        }

        guard !result.isEmpty else { return [] }
        normalizeFeatures(&result)
        return stride(from: 0, to: result.count, by: 2).map { result[$0] }
    }

    nonisolated static func dtwDistance(
        _ lhs: [[Float]],
        _ rhs: [[Float]]
    ) -> Float {
        guard !lhs.isEmpty, !rhs.isEmpty else { return .greatestFiniteMagnitude }
        let maximumLength = max(lhs.count, rhs.count)
        let band = max(24, abs(lhs.count - rhs.count) + maximumLength / 3)
        let infinity = Float.greatestFiniteMagnitude / 4
        var previous = [Float](repeating: infinity, count: rhs.count + 1)
        previous[0] = 0

        for leftIndex in 1...lhs.count {
            var current = [Float](repeating: infinity, count: rhs.count + 1)
            let expectedRight = Int(
                Double(leftIndex) / Double(lhs.count) * Double(rhs.count)
            )
            let lower = max(1, expectedRight - band)
            let upper = min(rhs.count, expectedRight + band)
            guard lower <= upper else { continue }
            for rightIndex in lower...upper {
                let local = featureDistance(
                    lhs[leftIndex - 1],
                    rhs[rightIndex - 1]
                )
                current[rightIndex] =
                    local
                    + min(
                        previous[rightIndex],
                        current[rightIndex - 1],
                        previous[rightIndex - 1]
                    )
            }
            previous = current
        }
        return previous[rhs.count] / Float(lhs.count + rhs.count)
    }

    nonisolated static func resample(
        _ samples: [Float],
        from sourceRate: Double,
        to targetRate: Double
    ) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0 else { return [] }
        guard abs(sourceRate - targetRate) > 1 else { return samples }
        let outputCount = max(1, Int(Double(samples.count) * targetRate / sourceRate))
        var output = [Float](repeating: 0, count: outputCount)
        let scale = sourceRate / targetRate
        for outputIndex in output.indices {
            let sourcePosition = Double(outputIndex) * scale
            let lower = min(Int(sourcePosition), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            output[outputIndex] =
                samples[lower]
                + (samples[upper] - samples[lower]) * fraction
        }
        return output
    }

    nonisolated static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return [] }
        var samples = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                samples[frame] += channels[channel][frame] / Float(channelCount)
            }
        }
        return samples
    }

    private nonisolated static func normalizeAmplitude(_ samples: [Float]) -> [Float] {
        let mean = samples.reduce(Float.zero, +) / Float(samples.count)
        let centered = samples.map { $0 - mean }
        let peak = centered.reduce(Float.zero) { max($0, abs($1)) }
        guard peak > 0.0001 else { return centered }
        return centered.map { $0 / peak }
    }

    private nonisolated static func melFilterBank(_ spectrum: [Float]) -> [Float] {
        let minimumMel = hzToMel(80)
        let maximumMel = hzToMel(7_600)
        let points = (0..<(melBandCount + 2)).map {
            minimumMel + (maximumMel - minimumMel)
                * Float($0) / Float(melBandCount + 1)
        }
        let bins = points.map {
            min(
                max(Int(melToHz($0) / Float(sampleRate) * Float(frameLength)), 0),
                spectrum.count - 1
            )
        }

        return (0..<melBandCount).map { band in
            let left = bins[band]
            let center = max(bins[band + 1], left + 1)
            let right = max(bins[band + 2], center + 1)
            var energy: Float = 0
            if left < center {
                for bin in left..<min(center, spectrum.count) {
                    energy +=
                        spectrum[bin]
                        * Float(bin - left) / Float(center - left)
                }
            }
            if center < right, center < spectrum.count {
                for bin in center..<min(right, spectrum.count) {
                    energy +=
                        spectrum[bin]
                        * Float(right - bin) / Float(right - center)
                }
            }
            return log(max(energy, 0.000_000_1))
        }
    }

    private nonisolated static func dct(logEnergies: [Float]) -> [Float] {
        (1...coefficientCount).map { coefficient in
            var value: Float = 0
            for band in logEnergies.indices {
                value +=
                    logEnergies[band]
                    * cos(
                        Float.pi * Float(coefficient) * (Float(band) + 0.5)
                            / Float(logEnergies.count)
                    )
            }
            return value
        }
    }

    private nonisolated static func normalizeFeatures(_ features: inout [[Float]]) {
        for coefficient in 0..<coefficientCount {
            let mean =
                features.reduce(Float.zero) {
                    $0 + $1[coefficient]
                } / Float(features.count)
            let variance =
                features.reduce(Float.zero) {
                    let difference = $1[coefficient] - mean
                    return $0 + difference * difference
                } / Float(features.count)
            let standardDeviation = max(sqrt(variance), 0.001)
            for frame in features.indices {
                features[frame][coefficient] =
                    (features[frame][coefficient] - mean) / standardDeviation
            }
        }
    }

    private nonisolated static func featureDistance(
        _ lhs: [Float],
        _ rhs: [Float]
    ) -> Float {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return .greatestFiniteMagnitude }
        var sum: Float = 0
        for index in 0..<count {
            let difference = lhs[index] - rhs[index]
            sum += difference * difference
        }
        return sqrt(sum / Float(count))
    }

    private nonisolated static func hzToMel(_ hertz: Float) -> Float {
        2_595 * log10(1 + hertz / 700)
    }

    private nonisolated static func melToHz(_ mel: Float) -> Float {
        700 * (pow(10, mel / 2_595) - 1)
    }
}

@MainActor
private final class LinkedBookSpeechRenderer {
    private enum RenderingError: LocalizedError {
        case unavailable
        case busy

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "The system voice could not render this passage."
            case .busy:
                return "The system voice is already rendering another passage."
            }
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<[Float], Error>?
    private var samples: [Float] = []

    func render(_ text: String, language: String?) async throws -> [Float] {
        guard continuation == nil else { throw RenderingError.busy }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let language,
            let voice = AVSpeechSynthesisVoice(language: language)
        {
            utterance.voice = voice
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                samples = []
                synthesizer.write(utterance) { [weak self] buffer in
                    guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
                    let isFinished = pcmBuffer.frameLength == 0
                    let sampleRate = pcmBuffer.format.sampleRate
                    let copied =
                        isFinished
                        ? []
                        : LinkedBookAudioFingerprint.monoSamples(from: pcmBuffer)
                    Task { @MainActor [weak self] in
                        self?.consume(
                            copied,
                            sampleRate: sampleRate,
                            isFinished: isFinished
                        )
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
        finish(throwing: CancellationError())
    }

    private func consume(
        _ bufferSamples: [Float],
        sampleRate: Double,
        isFinished: Bool
    ) {
        guard continuation != nil else { return }
        if isFinished {
            guard !samples.isEmpty else {
                finish(throwing: RenderingError.unavailable)
                return
            }
            finish(returning: samples)
            return
        }
        samples.append(
            contentsOf: LinkedBookAudioFingerprint.resample(
                bufferSamples,
                from: sampleRate,
                to: 16_000
            )
        )
    }

    private func finish(returning renderedSamples: [Float]) {
        let pending = continuation
        continuation = nil
        samples = []
        pending?.resume(returning: renderedSamples)
    }

    private func finish(throwing error: Error) {
        let pending = continuation
        continuation = nil
        samples = []
        pending?.resume(throwing: error)
    }
}
