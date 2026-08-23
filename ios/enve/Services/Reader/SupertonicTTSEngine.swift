import CoreML
import Foundation
import Logging
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared

#if !targetEnvironment(macCatalyst)
import FluidAudio
#endif

enum EbookTTSEngineChoice: String, CaseIterable, Identifiable {
    case apple
    case supertonic3
    case kokoro

    var id: String { rawValue }

    static var allCases: [EbookTTSEngineChoice] {
        #if targetEnvironment(macCatalyst)
        [.apple]
        #else
        [.apple, .supertonic3, .kokoro]
        #endif
    }

    var displayName: String {
        switch self {
        case .apple: "Apple voices"
        case .supertonic3: "Enhanced on-device"
        case .kokoro: "Kokoro"
        }
    }

    var detail: String {
        switch self {
        case .apple: "Built into your iPhone"
        case .supertonic3: "Supertonic 3 · private and offline"
        case .kokoro: "Natural English · private and offline"
        }
    }

    var downloadTitle: String {
        switch self {
        case .apple: ""
        case .supertonic3: "Download Supertonic 3"
        case .kokoro: "Download Kokoro"
        }
    }

    var modelName: String {
        switch self {
        case .apple: ""
        case .supertonic3: "Supertonic 3"
        case .kokoro: "Kokoro"
        }
    }

    var downloadDetail: String {
        switch self {
        case .apple: ""
        case .supertonic3: "About 165 MB · 31 languages · 10 voices"
        case .kokoro: "About 400 MB · English · Heart voice"
        }
    }
}

enum EnhancedTTSVoice: String, CaseIterable, Identifiable, Sendable {
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

enum TTSModelDownloadState: Equatable {
    case notDownloaded
    case downloading(Double)
    case removing
    case ready
    case failed(String)
}

#if !targetEnvironment(macCatalyst)
actor SupertonicTTSRuntime {
    static let shared = SupertonicTTSRuntime()

    private let audioCache = NeuralTTSAudioCache(namespace: "Supertonic3")
    private var manager: Supertonic3Manager?
    private var preparationTask: Task<Supertonic3Manager, Error>?
    private var preparationGeneration = 0
    private var styles: [EnhancedTTSVoice: Supertonic3VoiceStyle] = [:]
    private var styleTasks: [EnhancedTTSVoice: Task<Supertonic3VoiceStyle, Error>] = [:]
    private var inFlight: [String: Task<[Float], Error>] = [:]

    func prepareVoicePack(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await prepareModels { update in
            progress?(update * 0.98)
        }

        let voices = EnhancedTTSVoice.allCases
        for (index, voice) in voices.enumerated() {
            try await prepareStyle(voice) { update in
                let voiceProgress = (Double(index) + update) / Double(voices.count)
                progress?(0.98 + voiceProgress * 0.02)
            }
        }
        progress?(1)
    }

    func prepare(
        voice: EnhancedTTSVoice,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try await prepareModels(progress: progress)

        try await prepareStyle(voice, progress: progress)
        progress?(1)
    }

    private func prepareModels(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if manager != nil {
            progress?(1)
            return
        }

        let generation = preparationGeneration
        let task: Task<Supertonic3Manager, Error>
        if let preparationTask {
            task = preparationTask
        } else {
            task = Task {
                try await Supertonic3ResourceDownloader.ensureModels(
                    veVariant: "ane-int4",
                    progressHandler: { update in progress?(update.fractionCompleted) }
                )
                NeuralTTSStorage.excludeModelsFromBackup()
                try Task.checkCancellation()
                let manager = Supertonic3Manager(
                    computeUnits: .cpuAndNeuralEngine,
                    vectorEstimator: .aneBucketed(.int4)
                )
                try await manager.initialize()
                return manager
            }
            preparationTask = task
        }

        do {
            let preparedManager = try await task.value
            guard generation == preparationGeneration else { throw CancellationError() }
            manager = preparedManager
            preparationTask = nil
            progress?(1)
        } catch {
            if generation == preparationGeneration {
                preparationTask = nil
            }
            throw error
        }
    }

    private func prepareStyle(
        _ voice: EnhancedTTSVoice,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        if styles[voice] != nil {
            progress?(1)
            return
        }

        let generation = preparationGeneration
        let task: Task<Supertonic3VoiceStyle, Error>
        if let styleTask = styleTasks[voice] {
            task = styleTask
        } else {
            task = Task {
                try await Supertonic3ResourceDownloader.loadVoiceStyle(
                    voice.fluidVoice,
                    progressHandler: { update in progress?(update.fractionCompleted) }
                )
            }
            styleTasks[voice] = task
        }

        do {
            let style = try await task.value
            guard generation == preparationGeneration else { throw CancellationError() }
            styles[voice] = style
            styleTasks[voice] = nil
            progress?(1)
        } catch {
            if generation == preparationGeneration {
                styleTasks[voice] = nil
            }
            throw error
        }
    }

    func synthesize(
        text: String,
        language: String,
        voice: EnhancedTTSVoice,
        speed: Float
    ) async throws -> [Float] {
        let cacheKey = audioCache.key(
            "v1",
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

        try await prepare(voice: voice)
        guard let manager, let style = styles[voice] else {
            throw NeuralTTSError.notReady
        }

        let task = Task {
            let result = try await manager.synthesize(
                text: text,
                language: language,
                style: style,
                speed: speed
            )
            guard !result.samples.isEmpty else { throw NeuralTTSError.emptyAudio }
            return result.samples
        }
        inFlight[cacheKey] = task
        do {
            let samples = try await task.value
            inFlight[cacheKey] = nil
            try audioCache.store(samples, key: cacheKey)
            return samples
        } catch {
            inFlight[cacheKey] = nil
            throw error
        }
    }

    func removeModels() async throws {
        await unload()
        let models = try TtsCacheDirectory.ensure()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Repo.supertonic3.folderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: models.path) {
            try FileManager.default.removeItem(at: models)
        }
        try? audioCache.removeAll()
    }

    func unload() async {
        preparationGeneration += 1
        let preparationTask = self.preparationTask
        self.preparationTask = nil
        preparationTask?.cancel()
        let styleTasks = Array(self.styleTasks.values)
        self.styleTasks.removeAll()
        styleTasks.forEach { $0.cancel() }
        let preparingManager = try? await preparationTask?.value
        if let preparingManager {
            await preparingManager.cleanup()
        }
        for task in styleTasks {
            _ = try? await task.value
        }
        let tasks = Array(inFlight.values)
        tasks.forEach { $0.cancel() }
        inFlight.removeAll()
        for task in tasks {
            _ = try? await task.value
        }
        if let manager {
            await manager.cleanup()
        }
        manager = nil
        styles.removeAll()
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
