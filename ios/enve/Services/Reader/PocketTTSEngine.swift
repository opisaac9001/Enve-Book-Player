#if os(iOS)
import AVFoundation
import Foundation
import Logging
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared

#if !targetEnvironment(macCatalyst)
import FluidAudio

actor PocketTTSRuntime {
    static let shared = PocketTTSRuntime()
    nonisolated static var hasDownloadedVoices: Bool { LocalNarratorPack.pocket.isInstalled }

    private let audioCache = NeuralTTSAudioCache(namespace: "PocketTTS")
    private var manager: PocketTtsManager?
    private var preparation: Task<PocketTtsManager, Error>?
    private var generation = 0
    private var inFlight: [String: Task<[Float], Error>] = [:]

    func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if manager != nil {
            progress?(1)
            return
        }
        let started = generation
        let task: Task<PocketTtsManager, Error>
        if let preparation {
            task = preparation
        } else {
            task = Task {
                let root = try await LocalNarratorPack.pocket.install { progress?($0 * 0.98) }
                NeuralTTSStorage.excludeModelsFromBackup()
                let manager = PocketTtsManager(defaultVoice: PocketTtsConstants.defaultVoice, language: .english, directory: root)
                try await manager.initialize()
                return manager
            }
            preparation = task
        }
        defer { if generation == started { preparation = nil } }
        let ready = try await task.value
        guard generation == started else { throw CancellationError() }
        manager = ready
        progress?(1)
    }

    func synthesize(text: String) async throws -> [Float] {
        try Task.checkCancellation()
        let cacheKey = audioCache.key(try LocalNarratorPack.pocket.revision, PocketTtsConstants.defaultVoice, text)
        if let cached = try audioCache.load(key: cacheKey) { return cached }
        return try await generate(text: text, cacheKey: cacheKey)
    }

    private func generate(text: String, cacheKey: String) async throws -> [Float] {
        if let task = inFlight[cacheKey] { return try await task.value }
        try await prepare()
        try Task.checkCancellation()
        if let task = inFlight[cacheKey] { return try await task.value }
        guard let manager else { throw NeuralTTSError.notReady }

        let started = generation
        let task = Task {
            let result = try await manager.synthesizeDetailed(text: text, voice: PocketTtsConstants.defaultVoice)
            // The pipeline stops generating on cancellation and returns partial audio instead of throwing.
            try Task.checkCancellation()
            guard !result.samples.isEmpty else { throw NeuralTTSError.emptyAudio }
            return result.samples
        }
        inFlight[cacheKey] = task
        do {
            let samples = try await task.value
            guard generation == started else { throw CancellationError() }
            inFlight[cacheKey] = nil
            try audioCache.store(samples, key: cacheKey)
            return samples
        } catch {
            if generation == started { inFlight[cacheKey] = nil }
            throw error
        }
    }

    func removeModels() async throws {
        await unload()
        let root = try LocalNarratorPack.pocket.root
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try? audioCache.removeAll()
    }

    func unload() async {
        generation += 1
        let preparing = preparation
        preparation = nil
        preparing?.cancel()
        let previous = manager
        manager = nil
        let tasks = Array(inFlight.values)
        inFlight.removeAll()
        tasks.forEach { $0.cancel() }
        _ = try? await preparing?.value
        for task in tasks { _ = try? await task.value }
        await previous?.cleanup()
    }
}

@MainActor
final class PocketTTSEngine: @preconcurrency TTSEngine, @unchecked Sendable {
    var currentRate: Float

    nonisolated(unsafe) let availableVoices: [TTSVoice] = []

    private let runtime: PocketTTSRuntime
    private let startAnchor: EbookTTSStartAnchor
    private let fallbackEngine: AnchoredAVTTSEngine
    private let audioPlayer = NeuralTTSAudioPlayer(
        sampleRate: Double(PocketTtsConstants.audioSampleRate), adjustsRate: true
    )

    init(
        runtime: PocketTTSRuntime = .shared,
        rate: Float,
        startAnchor: EbookTTSStartAnchor
    ) {
        self.runtime = runtime
        self.startAnchor = startAnchor
        currentRate = rate
        fallbackEngine = AnchoredAVTTSEngine(rate: rate, anchor: startAnchor)
    }

    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, ReadiumNavigator.TTSError> {
        guard !Task.isCancelled else { return .success(()) }
        guard baseLanguageCode(for: utterance.language) == "en" else {
            return await speakWithApple(utterance, onSpeakRange: onSpeakRange)
        }
        guard let slice = startAnchor.slice(for: utterance.text) else {
            return .success(())
        }

        return await withTaskCancellationHandler {
            do {
                if utterance.delay > 0 {
                    try await Task.sleep(for: .seconds(utterance.delay))
                }
                let samples = try await runtime.synthesize(text: slice.spoken)
                try Task.checkCancellation()
                return await audioPlayer.play(
                    samples,
                    text: slice.spoken,
                    rate: currentRate,
                    onSpeakRange: { range in
                        onSpeakRange(slice.originalRange(for: range))
                    }
                )
            } catch is CancellationError {
                return .success(())
            } catch {
                AppLogger.library.error("Pocket TTS synthesis failed; using Apple speech: \(error)")
                return await speakWithApple(
                    utterance,
                    slice: slice,
                    onSpeakRange: onSpeakRange
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.audioPlayer.cancel()
            }
        }
    }

    private func speakWithApple(
        _ utterance: TTSUtterance,
        slice: SpokenTextSlice? = nil,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, ReadiumNavigator.TTSError> {
        fallbackEngine.currentRate = currentRate
        if let slice {
            return await fallbackEngine.speak(
                utterance,
                slice: slice,
                onSpeakRange: onSpeakRange
            )
        }
        return await fallbackEngine.speak(utterance, onSpeakRange: onSpeakRange)
    }

    private func baseLanguageCode(for language: ReadiumShared.Language) -> String {
        language.code.bcp47
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init)
            ?? "en"
    }
}
#else
actor PocketTTSRuntime {
    static let shared = PocketTTSRuntime()
    nonisolated static var hasDownloadedVoices: Bool { false }

    func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        throw NeuralTTSError.notReady
    }

    func synthesize(text: String) async throws -> [Float] {
        throw NeuralTTSError.notReady
    }

    func removeModels() async throws {}
    func unload() async {}
}

@MainActor
final class PocketTTSEngine: @preconcurrency TTSEngine, @unchecked Sendable {
    var currentRate: Float

    nonisolated(unsafe) let availableVoices: [TTSVoice] = []

    private let fallbackEngine: AnchoredAVTTSEngine

    init(
        runtime: PocketTTSRuntime = .shared,
        rate: Float,
        startAnchor: EbookTTSStartAnchor
    ) {
        currentRate = rate
        fallbackEngine = AnchoredAVTTSEngine(rate: rate, anchor: startAnchor)
    }

    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, ReadiumNavigator.TTSError> {
        fallbackEngine.currentRate = currentRate
        return await fallbackEngine.speak(utterance, onSpeakRange: onSpeakRange)
    }
}
#endif
#endif
