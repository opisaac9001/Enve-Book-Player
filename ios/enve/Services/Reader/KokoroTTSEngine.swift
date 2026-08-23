import Foundation
import Logging
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared

#if !targetEnvironment(macCatalyst)
import FluidAudio
#endif

#if !targetEnvironment(macCatalyst)
actor KokoroTTSRuntime {
    static let shared = KokoroTTSRuntime()

    nonisolated static var isSupportedOnCurrentOS: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return !(version.majorVersion == 26 && (4...5).contains(version.minorVersion))
    }

    private let audioCache = NeuralTTSAudioCache(namespace: "Kokoro")
    private var manager: KokoroAneManager?
    private var preparationTask: Task<KokoroAneManager, Error>?
    private var preparationGeneration = 0
    private var inFlight: [String: Task<[Float], Error>] = [:]

    func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard Self.isSupportedOnCurrentOS else { throw NeuralTTSError.unsupportedOS }
        if manager != nil {
            progress?(1)
            return
        }

        let generation = preparationGeneration
        let task: Task<KokoroAneManager, Error>
        if let preparationTask {
            task = preparationTask
        } else {
            task = Task {
                try await KokoroAneResourceDownloader.ensureModels(
                    variant: .english,
                    progressHandler: { update in progress?(update.fractionCompleted * 0.9) }
                )
                try await KokoroAneResourceDownloader.ensureG2PAssets(
                    progressHandler: { update in progress?(0.9 + update.fractionCompleted * 0.08) }
                )
                _ = await KokoroAneResourceDownloader.ensureEnglishLexicon()
                NeuralTTSStorage.excludeModelsFromBackup()
                try Task.checkCancellation()
                let manager = KokoroAneManager(variant: .english)
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

    func synthesize(text: String, speed: Float) async throws -> [Float] {
        let cacheKey = audioCache.key(
            "v1",
            "af_heart",
            String(format: "%.2f", speed),
            text
        )
        if let samples = try audioCache.load(key: cacheKey) {
            return samples
        }
        if let task = inFlight[cacheKey] {
            return try await task.value
        }

        try await prepare()
        guard let manager else { throw NeuralTTSError.notReady }

        let task = Task {
            try await Self.generateSamples(text: text, speed: speed, manager: manager)
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

    private nonisolated static func generateSamples(
        text: String,
        speed: Float,
        manager: KokoroAneManager
    ) async throws -> [Float] {
        let chunks = Self.chunks(text)
        let silence = [Float](
            repeating: 0,
            count: Int(Double(KokoroAneConstants.sampleRate) * 0.12)
        )
        var samples: [Float] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let result = try await manager.synthesizeDetailed(
                text: chunk,
                voice: "af_heart",
                speed: speed
            )
            if index > 0 {
                samples.append(contentsOf: silence)
            }
            samples.append(contentsOf: result.samples)
        }

        guard !samples.isEmpty else { throw NeuralTTSError.emptyAudio }
        return samples
    }

    func removeModels() async throws {
        await unload()
        let models = try TtsCacheDirectory.ensure()
            .appendingPathComponent("Models", isDirectory: true)
        for repo in [Repo.kokoroAne, .kokoro] {
            let url = models.appendingPathComponent(repo.folderName, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try? audioCache.removeAll()
    }

    func unload() async {
        preparationGeneration += 1
        let preparationTask = self.preparationTask
        self.preparationTask = nil
        preparationTask?.cancel()
        let preparingManager = try? await preparationTask?.value
        if let preparingManager {
            await preparingManager.cleanup()
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
    }

    private nonisolated static func chunks(_ text: String) -> [String] {
        let maximumCharacters = 240
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumCharacters else { return [trimmed] }

        var sentences: [String] = []
        trimmed.enumerateSubstrings(
            in: trimmed.startIndex..<trimmed.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            let sentence = trimmed[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
        }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            for part in splitLongText(sentence, maximumCharacters: maximumCharacters) {
                let candidate = current.isEmpty ? part : "\(current) \(part)"
                if candidate.count <= maximumCharacters {
                    current = candidate
                } else {
                    if !current.isEmpty { chunks.append(current) }
                    current = part
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [trimmed] : chunks
    }

    private nonisolated static func splitLongText(
        _ text: String,
        maximumCharacters: Int
    ) -> [String] {
        guard text.count > maximumCharacters else { return [text] }

        var parts: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \Character.isWhitespace).map(String.init) {
            let candidate = current.isEmpty ? word : "\(current) \(word)"
            if candidate.count <= maximumCharacters {
                current = candidate
            } else {
                if !current.isEmpty { parts.append(current) }
                current = word
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

@MainActor
final class KokoroTTSEngine: @preconcurrency TTSEngine, @unchecked Sendable {
    var currentRate: Float

    nonisolated(unsafe) let availableVoices: [TTSVoice] = []

    private let runtime: KokoroTTSRuntime
    private let startAnchor: EbookTTSStartAnchor
    private let fallbackEngine: AnchoredAVTTSEngine
    private let audioPlayer = NeuralTTSAudioPlayer(
        sampleRate: Double(KokoroAneConstants.sampleRate)
    )

    init(
        runtime: KokoroTTSRuntime = .shared,
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
        guard baseLanguageCode(for: utterance.language) == "en",
            KokoroTTSRuntime.isSupportedOnCurrentOS
        else {
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
                AppLogger.library.error("Kokoro synthesis failed; using Apple speech: \(error)")
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
actor KokoroTTSRuntime {
    static let shared = KokoroTTSRuntime()

    nonisolated static var isSupportedOnCurrentOS: Bool { false }

    func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        throw NeuralTTSError.notReady
    }

    func synthesize(text: String, speed: Float) async throws -> [Float] {
        throw NeuralTTSError.notReady
    }

    func removeModels() async throws {}
    func unload() async {}
}

@MainActor
final class KokoroTTSEngine: @preconcurrency TTSEngine, @unchecked Sendable {
    var currentRate: Float

    nonisolated(unsafe) let availableVoices: [TTSVoice] = []

    private let fallbackEngine: AnchoredAVTTSEngine

    init(
        runtime: KokoroTTSRuntime = .shared,
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
