#if os(iOS)
import CoreML
import Foundation
import Logging
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared

#if !targetEnvironment(macCatalyst)
import FluidAudio
#endif

nonisolated enum EnhancedTTSVoice: String, CaseIterable, Identifiable, Sendable {
    case f1 = "F1"
    case f2 = "F2"
    case f3 = "F3"
    case f4 = "F4"
    case f5 = "F5"
    case m1 = "M1"
    case m2 = "M2"
    case m3 = "M3"
    case m4 = "M4"
    case m5 = "M5"

    var id: String { rawValue }
    var displayName: String { "Voice \(rawValue)" }
    var detail: String { rawValue.hasPrefix("F") ? "Feminine" : "Masculine" }

    static let supportedLanguageCodes = [
        "ar", "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr",
        "hi", "hr", "hu", "id", "it", "ja", "ko", "lt", "lv", "nl", "pl",
        "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi",
    ]

    #if !targetEnvironment(macCatalyst)
    fileprivate var fluidVoice: Supertonic3Voice {
        Supertonic3Voice(name: rawValue) ?? .default
    }
    #endif
}

#if !targetEnvironment(macCatalyst)
actor SupertonicTTSRuntime {
    static let shared = SupertonicTTSRuntime()
    nonisolated static var hasDownloadedVoices: Bool { LocalNarratorPack.supertonic.isInstalled }

    private let audioCache = NeuralTTSAudioCache(namespace: "Supertonic3")
    private struct Pack: Sendable {
        let manager: Supertonic3Manager
        let styles: [EnhancedTTSVoice: Supertonic3VoiceStyle]
    }

    private var pack: Pack?
    private var preparation: Task<Pack, Error>?
    private var generation = 0
    private var inFlight: [String: Task<[Float], Error>] = [:]

    func prepareVoicePack(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if pack != nil {
            progress?(1)
            return
        }
        let started = generation
        let task: Task<Pack, Error>
        if let preparation {
            task = preparation
        } else {
            task = Task {
                let root = try await LocalNarratorPack.supertonic.install { progress?($0 * 0.98) }
                NeuralTTSStorage.excludeModelsFromBackup()
                let manager = Supertonic3Manager(directory: root, computeUnits: .cpuAndNeuralEngine, vectorEstimator: .aneBucketed(.int4))
                try await manager.initialize()
                let directory = root.appendingPathComponent(Repo.supertonic3.folderName)
                var styles: [EnhancedTTSVoice: Supertonic3VoiceStyle] = [:]
                for voice in EnhancedTTSVoice.allCases {
                    try Task.checkCancellation()
                    styles[voice] = try Supertonic3VoiceStyle.load(from: directory.appendingPathComponent(voice.fluidVoice.fileName))
                }
                return Pack(manager: manager, styles: styles)
            }
            preparation = task
        }
        defer { if generation == started { preparation = nil } }
        let ready = try await task.value
        guard generation == started else { throw CancellationError() }
        pack = ready
        progress?(1)
    }

    func synthesize(
        text: String,
        language: String,
        voice: EnhancedTTSVoice,
        speed: Float
    ) async throws -> [Float] {
        try Task.checkCancellation()
        let cacheKey = audioCache.key(
            try LocalNarratorPack.supertonic.revision,
            language,
            voice.rawValue,
            String(format: "%.2f", speed),
            text
        )
        if let samples = try audioCache.load(key: cacheKey) {
            return samples
        }
        if let task = inFlight[cacheKey] {
            return try await task.value
        }

        try await prepareVoicePack()
        try Task.checkCancellation()
        if let task = inFlight[cacheKey] { return try await task.value }
        guard let pack, let style = pack.styles[voice] else {
            throw NeuralTTSError.notReady
        }

        let started = generation
        let task = Task {
            let result = try await pack.manager.synthesize(
                text: text,
                language: language,
                style: style,
                speed: speed
            )
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
        let root = try LocalNarratorPack.supertonic.root
        let legacy = try TtsCacheDirectory.ensure().appendingPathComponent("Models/\(Repo.supertonic3.folderName)")
        for url in [root, legacy] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try? audioCache.removeAll()
    }

    func unload() async {
        generation += 1
        let preparing = preparation
        preparation = nil
        preparing?.cancel()
        let previous = pack
        pack = nil
        let tasks = Array(inFlight.values)
        inFlight.removeAll()
        tasks.forEach { $0.cancel() }
        _ = try? await preparing?.value
        for task in tasks { _ = try? await task.value }
        await previous?.manager.cleanup()
    }
}

@MainActor
final class SupertonicTTSEngine: @preconcurrency TTSEngine, @unchecked Sendable {
    private static let supportedLanguages = Set(EnhancedTTSVoice.supportedLanguageCodes)

    var currentRate: Float
    var voice: EnhancedTTSVoice

    nonisolated(unsafe) let availableVoices: [TTSVoice] = []

    private let runtime: SupertonicTTSRuntime
    private let startAnchor: EbookTTSStartAnchor
    private let fallbackEngine: AnchoredAVTTSEngine
    private let audioPlayer = NeuralTTSAudioPlayer(
        sampleRate: Double(Supertonic3Constants.sampleRate)
    )

    init(
        runtime: SupertonicTTSRuntime = .shared,
        voice: EnhancedTTSVoice,
        rate: Float,
        startAnchor: EbookTTSStartAnchor
    ) {
        self.runtime = runtime
        self.voice = voice
        self.startAnchor = startAnchor
        currentRate = rate
        fallbackEngine = AnchoredAVTTSEngine(rate: rate, anchor: startAnchor)
    }

    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, ReadiumNavigator.TTSError> {
        let language = baseLanguageCode(for: utterance.language)
        guard Self.supportedLanguages.contains(language) else {
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
                let samples = try await runtime.synthesize(
                    text: slice.spoken,
                    language: language,
                    voice: voice,
                    speed: currentRate
                )
                try Task.checkCancellation()
                return await audioPlayer.play(
                    samples,
                    text: slice.spoken,
                    onSpeakRange: { range in
                        onSpeakRange(slice.originalRange(for: range))
                    }
                )
            } catch is CancellationError {
                return .success(())
            } catch {
                AppLogger.library.error("Supertonic synthesis failed; using Apple speech: \(error)")
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
actor SupertonicTTSRuntime {
    static let shared = SupertonicTTSRuntime()
    nonisolated static var hasDownloadedVoices: Bool { false }

    func prepareVoicePack(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        throw NeuralTTSError.notReady
    }

    func synthesize(
        text: String,
        language: String,
        voice: EnhancedTTSVoice,
        speed: Float
    ) async throws -> [Float] {
        throw NeuralTTSError.notReady
    }

    func removeModels() async throws {}
    func unload() async {}
}

@MainActor
final class SupertonicTTSEngine: @preconcurrency TTSEngine, @unchecked Sendable {
    var currentRate: Float
    var voice: EnhancedTTSVoice

    nonisolated(unsafe) let availableVoices: [TTSVoice] = []

    private let fallbackEngine: AnchoredAVTTSEngine

    init(
        runtime: SupertonicTTSRuntime = .shared,
        voice: EnhancedTTSVoice,
        rate: Float,
        startAnchor: EbookTTSStartAnchor
    ) {
        self.voice = voice
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
