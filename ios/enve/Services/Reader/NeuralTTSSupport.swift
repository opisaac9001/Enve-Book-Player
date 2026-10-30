import AVFoundation
import CryptoKit
import Foundation
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared

#if !targetEnvironment(macCatalyst)
import FluidAudio
#endif

enum NeuralTTSError: LocalizedError {
    case emptyAudio
    case invalidAudio
    case notReady
    case unsupportedOS

    var errorDescription: String? {
        switch self {
        case .emptyAudio: "The on-device voice produced no audio."
        case .invalidAudio: "The on-device voice produced invalid audio."
        case .notReady: "The on-device voice is not ready."
        case .unsupportedOS: "Kokoro requires iOS 26.6 or later on iOS 26."
        }
    }
}

enum NeuralTTSStorage {
    nonisolated static func excludeModelsFromBackup() {
        #if !targetEnvironment(macCatalyst)
        guard var root = try? TtsCacheDirectory.ensure() else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        #endif
    }
}

struct SpokenTextSlice {
    let original: String
    let spoken: String
    let startOffset: Int

    init(original: String, startOffset: Int = 0) {
        self.original = original
        self.startOffset = startOffset
        let start = original.index(original.startIndex, offsetBy: startOffset)
        spoken = String(original[start...])
    }

    func originalRange(for spokenRange: Range<String.Index>) -> Range<String.Index> {
        let lowerOffset = spoken.distance(from: spoken.startIndex, to: spokenRange.lowerBound)
        let upperOffset = spoken.distance(from: spoken.startIndex, to: spokenRange.upperBound)
        let lower = original.index(original.startIndex, offsetBy: startOffset + lowerOffset)
        let upper = original.index(original.startIndex, offsetBy: startOffset + upperOffset)
        return lower..<upper
    }

    func sentenceRange(containing spokenRange: Range<String.Index>) -> Range<String.Index> {
        var matchingRange: Range<String.Index>?
        spoken.enumerateSubstrings(
            in: spoken.startIndex..<spoken.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, stop in
            guard range.contains(spokenRange.lowerBound) else { return }
            matchingRange = range
            stop = true
        }

        guard var range = matchingRange else { return spokenRange }
        while range.lowerBound < range.upperBound, spoken[range.lowerBound].isWhitespace {
            range = spoken.index(after: range.lowerBound)..<range.upperBound
        }
        while range.lowerBound < range.upperBound {
            let last = spoken.index(before: range.upperBound)
            guard spoken[last].isWhitespace else { break }
            range = range.lowerBound..<last
        }
        return range
    }
}

@MainActor
final class EbookTTSStartAnchor {
    private var fragment: String?
    private var remainingSearches = 0

    func prepare(fragment: String?) {
        self.fragment =
            fragment?
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .nilIfEmpty
        remainingSearches = self.fragment == nil ? 0 : 256
    }

    func slice(for text: String) -> SpokenTextSlice? {
        guard let fragment else { return SpokenTextSlice(original: text) }

        let words = fragment.split(separator: " ").prefix(10)
        guard !words.isEmpty else {
            self.fragment = nil
            remainingSearches = 0
            return SpokenTextSlice(original: text)
        }
        let pattern =
            words
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
        guard let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
            ),
            let range = Range(match.range, in: text)
        else {
            remainingSearches -= 1
            if remainingSearches > 0 {
                return nil
            }
            self.fragment = nil
            return SpokenTextSlice(original: text)
        }
        self.fragment = nil
        remainingSearches = 0
        return SpokenTextSlice(
            original: text,
            startOffset: text.distance(from: text.startIndex, to: range.lowerBound)
        )
    }
}

@MainActor
final class AnchoredAVTTSEngine: NSObject, @preconcurrency TTSEngine, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var currentRate: Float {
        didSet {
            guard currentRate != oldValue else { return }
            respeakRemainderAtCurrentRate()
        }
    }
    private let anchor: EbookTTSStartAnchor
    private let synthesizer = AVSpeechSynthesizer()
    private var playback: Playback?

    nonisolated(unsafe) let availableVoices: [TTSVoice]

    init(rate: Float, anchor: EbookTTSStartAnchor) {
        currentRate = rate
        self.anchor = anchor
        availableVoices = RateAwareAVTTSEngineDelegate.supportedVoices()
        super.init()
        synthesizer.delegate = self
    }

    nonisolated func voiceWithIdentifier(_ identifier: String) -> TTSVoice? {
        availableVoices.first { $0.identifier == identifier }
    }

    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, ReadiumNavigator.TTSError> {
        guard !Task.isCancelled else { return .success(()) }
        guard let slice = anchor.slice(for: utterance.text) else {
            return .success(())
        }
        return await speak(utterance, slice: slice, onSpeakRange: onSpeakRange)
    }

    func speak(
        _ utterance: TTSUtterance,
        slice: SpokenTextSlice,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, ReadiumNavigator.TTSError> {
        let voice: AVSpeechSynthesisVoice? =
            switch utterance.voiceOrLanguage {
            case let .left(voice): AVSpeechSynthesisVoice(identifier: voice.identifier)
            case let .right(language): AVSpeechSynthesisVoice(language: language.code.bcp47)
            }
        return await speak(slice, voice: voice, delay: utterance.delay, onSpeakRange: onSpeakRange)
    }

    func speak(
        _ slice: SpokenTextSlice,
        voice: AVSpeechSynthesisVoice?,
        delay: TimeInterval,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, ReadiumNavigator.TTSError> {
        guard !slice.spoken.isEmpty else { return .success(()) }
        let id = UUID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Readium's cancellation of the previous utterance reaches us asynchronously, so it can still be playing.
                supersedeCurrentPlayback()
                let speech = makeSpeech(slice.spoken, voice: voice, delay: delay)
                playback = Playback(
                    id: id,
                    slice: slice,
                    speech: speech,
                    voice: voice,
                    onSpeakRange: onSpeakRange,
                    continuation: continuation
                )
                synthesizer.speak(speech)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id: id)
            }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        nonisolated(unsafe) let utterance = utterance
        Task { @MainActor [weak self] in
            self?.didSpeak(characterRange, of: utterance)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        nonisolated(unsafe) let utterance = utterance
        Task { @MainActor [weak self] in
            self?.didEnd(utterance)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        nonisolated(unsafe) let utterance = utterance
        Task { @MainActor [weak self] in
            self?.didEnd(utterance)
        }
    }

    nonisolated static func appleSpeechRate(for rate: Float) -> Float {
        let minimum = AVSpeechUtteranceMinimumSpeechRate
        let maximum = AVSpeechUtteranceMaximumSpeechRate
        let standard = AVSpeechUtteranceDefaultSpeechRate
        guard rate.isFinite else { return standard }
        let mapped =
            rate >= 1
            ? standard + (rate - 1) / 2 * (maximum - standard)
            : minimum + (rate - 0.5) / 0.5 * (standard - minimum)
        return min(max(mapped, minimum), maximum)
    }

    private func makeSpeech(_ text: String, voice: AVSpeechSynthesisVoice?, delay: TimeInterval) -> AVSpeechUtterance {
        let speech = AVSpeechUtterance(string: text)
        speech.preUtteranceDelay = delay
        speech.rate = Self.appleSpeechRate(for: currentRate)
        speech.voice = voice
        return speech
    }

    private func didSpeak(_ characterRange: NSRange, of utterance: AVSpeechUtterance) {
        guard let playback, playback.speech === utterance,
            let range = Range(characterRange, in: playback.speech.speechString)
        else { return }
        let spokenRange = playback.spokenRange(forSpeechRange: range)
        playback.lastSpokenOffset = playback.slice.spoken.distance(
            from: playback.slice.spoken.startIndex,
            to: spokenRange.lowerBound
        )
        let sentenceRange = playback.slice.sentenceRange(containing: spokenRange)
        playback.onSpeakRange(playback.slice.originalRange(for: sentenceRange))
    }

    private func didEnd(_ utterance: AVSpeechUtterance) {
        guard let playback, playback.speech === utterance else { return }
        finish(id: playback.id)
    }

    // AVSpeechUtterance rates are fixed once queued, so the unspoken remainder is re-queued at the new rate.
    private func respeakRemainderAtCurrentRate() {
        guard let playback, synthesizer.isSpeaking, !synthesizer.isPaused else { return }
        let remainder = String(playback.slice.spoken.dropFirst(playback.lastSpokenOffset))
        guard !remainder.isEmpty else { return }
        let speech = makeSpeech(remainder, voice: playback.voice, delay: 0)
        playback.speech = speech
        playback.speechStartOffset = playback.lastSpokenOffset
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(speech)
    }

    private func supersedeCurrentPlayback() {
        guard let playback else { return }
        synthesizer.stopSpeaking(at: .immediate)
        finish(id: playback.id)
    }

    private func cancel(id: UUID) {
        guard playback?.id == id else { return }
        synthesizer.stopSpeaking(at: .immediate)
        finish(id: id)
    }

    private func finish(id: UUID) {
        guard let playback, playback.id == id else { return }
        self.playback = nil
        playback.continuation.resume(returning: .success(()))
    }

    private final class Playback {
        let id: UUID
        let slice: SpokenTextSlice
        let voice: AVSpeechSynthesisVoice?
        let onSpeakRange: (Range<String.Index>) -> Void
        let continuation: CheckedContinuation<Result<Void, ReadiumNavigator.TTSError>, Never>
        var speech: AVSpeechUtterance
        var speechStartOffset = 0
        var lastSpokenOffset = 0

        init(
            id: UUID,
            slice: SpokenTextSlice,
            speech: AVSpeechUtterance,
            voice: AVSpeechSynthesisVoice?,
            onSpeakRange: @escaping (Range<String.Index>) -> Void,
            continuation: CheckedContinuation<Result<Void, ReadiumNavigator.TTSError>, Never>
        ) {
            self.id = id
            self.slice = slice
            self.speech = speech
            self.voice = voice
            self.onSpeakRange = onSpeakRange
            self.continuation = continuation
        }

        func spokenRange(forSpeechRange range: Range<String.Index>) -> Range<String.Index> {
            let text = speech.speechString
            let lower = speechStartOffset + text.distance(from: text.startIndex, to: range.lowerBound)
            let upper = speechStartOffset + text.distance(from: text.startIndex, to: range.upperBound)
            let spoken = slice.spoken
            return spoken.index(spoken.startIndex, offsetBy: lower)..<spoken.index(spoken.startIndex, offsetBy: upper)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

@MainActor
final class PreparedTTSEngine<Engine: TTSEngine & Sendable>: @preconcurrency TTSEngine, @unchecked Sendable {
    nonisolated(unsafe) let availableVoices: [TTSVoice]
    private let engine: Engine
    private let preparation: Task<Void, Never>?
    private var requestID: UUID?

    init(engine: Engine, preparation: Task<Void, Never>?) {
        self.engine = engine
        self.preparation = preparation
        availableVoices = engine.availableVoices
    }

    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, ReadiumNavigator.TTSError> {
        let id = UUID()
        requestID = id
        defer { if requestID == id { requestID = nil } }
        await preparation?.value
        guard !Task.isCancelled, requestID == id else { return .success(()) }
        let callback: @MainActor @Sendable (Range<String.Index>) -> Void = { [weak self] range in
            guard self?.requestID == id else { return }
            onSpeakRange(range)
        }
        return await engine.speak(utterance) { @Sendable range in
            Task { @MainActor in callback(range) }
        }
    }
}

@MainActor
final class NeuralTTSAudioPlayer {
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var playbackID: UUID?
    private var playbackContinuation: CheckedContinuation<Result<Void, ReadiumNavigator.TTSError>, Never>?
    private var progressTask: Task<Void, Never>?

    init(sampleRate: Double) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
    }

    func play(
        _ samples: [Float],
        text: String,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, ReadiumNavigator.TTSError> {
        guard !samples.isEmpty else {
            return .failure(.other(NeuralTTSError.emptyAudio))
        }

        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData![0].update(from: samples, count: samples.count)

        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
        } catch {
            return .failure(.other(error))
        }

        let id = UUID()
        playbackID = id
        return await withCheckedContinuation { continuation in
            guard !Task.isCancelled else {
                playbackID = nil
                continuation.resume(returning: .success(()))
                return
            }

            playbackContinuation = continuation
            // The completion handler runs on an AVAudioEngine render thread and must not inherit MainActor isolation.
            playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.finishPlayback(id: id)
                }
            }
            playerNode.play()
            startProgress(
                id: id,
                text: text,
                duration: Double(samples.count) / format.sampleRate,
                onSpeakRange: onSpeakRange
            )
        }
    }

    func cancel() {
        guard playbackID != nil else { return }
        playerNode.stop()
        progressTask?.cancel()
        progressTask = nil
        playbackID = nil
        let continuation = playbackContinuation
        playbackContinuation = nil
        continuation?.resume(returning: .success(()))
    }

    private func finishPlayback(id: UUID) {
        guard playbackID == id else { return }
        progressTask?.cancel()
        progressTask = nil
        playbackID = nil
        let continuation = playbackContinuation
        playbackContinuation = nil
        continuation?.resume(returning: .success(()))
    }

    private func startProgress(
        id: UUID,
        text: String,
        duration: Double,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) {
        let sentences = Self.sentenceRanges(in: text)
        guard !sentences.isEmpty else { return }
        let characterCount = max(1, text.count)

        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let startedAt = clock.now
            for sentence in sentences {
                guard !Task.isCancelled, self?.playbackID == id else { return }
                let offset = text.distance(from: text.startIndex, to: sentence.lowerBound)
                let target = duration * Double(offset) / Double(characterCount)
                let elapsedDuration = startedAt.duration(to: clock.now).components
                let elapsed =
                    Double(elapsedDuration.seconds)
                    + Double(elapsedDuration.attoseconds) / 1e18
                if target > elapsed {
                    try? await Task.sleep(for: .seconds(target - elapsed))
                }
                guard !Task.isCancelled, self?.playbackID == id else { return }
                onSpeakRange(sentence)
            }
        }
    }

    private static func sentenceRanges(in text: String) -> [Range<String.Index>] {
        var sentences: [Range<String.Index>] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            sentences.append(range)
        }
        return sentences.isEmpty && !text.isEmpty
            ? [text.startIndex..<text.endIndex]
            : sentences
    }
}

struct NeuralTTSAudioCache: Sendable {
    private nonisolated static let maximumSize = 256 * 1_024 * 1_024
    private let namespace: String

    nonisolated init(namespace: String) {
        self.namespace = namespace
    }

    nonisolated func key(_ components: String...) -> String {
        SHA256.hash(data: Data(components.joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated func load(key: String) throws -> [Float]? {
        let url = try cacheDirectory().appendingPathComponent(key).appendingPathExtension("pcm")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data = try Data(contentsOf: url)
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        var samples = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = samples.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        guard Self.isValidAudio(samples) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        return samples
    }

    nonisolated func store(_ samples: [Float], key: String) throws {
        guard !samples.isEmpty else { throw NeuralTTSError.emptyAudio }
        guard Self.isValidAudio(samples) else { throw NeuralTTSError.invalidAudio }
        let directory = try cacheDirectory()
        let url = directory.appendingPathComponent(key).appendingPathExtension("pcm")
        let data = samples.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }
        try data.write(to: url, options: .atomic)
        trim(directory: directory)
    }

    nonisolated func removeAll() throws {
        let directory = try cacheDirectory()
        try FileManager.default.removeItem(at: directory)
    }

    private nonisolated static func isValidAudio(_ samples: [Float]) -> Bool {
        var hasSound = false
        for sample in samples {
            // Allow headroom above normalized PCM, but reject corrupt model output.
            guard sample.isFinite, abs(sample) <= 4 else { return false }
            if abs(sample) > 0.00001 { hasSound = true }
        }
        return hasSound
    }

    private nonisolated func cacheDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EnhancedTTS", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private nonisolated func trim(directory: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys)
            )
        else { return }

        let files = urls.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true,
                let size = values.fileSize
            else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }
        var totalSize = files.reduce(0) { $0 + $1.1 }
        guard totalSize > Self.maximumSize else { return }

        for file in files.sorted(by: { $0.2 < $1.2 }) where totalSize > Self.maximumSize {
            try? FileManager.default.removeItem(at: file.0)
            totalSize -= file.1
        }
    }
}
