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

    nonisolated static var isSupportedOnCurrentOS: Bool { true }

    nonisolated static func usesONNX(on version: OperatingSystemVersion) -> Bool {
        version.majorVersion > 26 || (version.majorVersion == 26 && version.minorVersion >= 4)
    }

    nonisolated static var hasDownloadedVoices: Bool {
        usesONNX(on: ProcessInfo.processInfo.operatingSystemVersion)
            ? KokoroONNXAssets.areDownloaded : KokoroTTSVoiceAssets.areDownloaded
    }

    private enum Backend: Sendable {
        case coreML(KokoroAneManager)
        case onnx(KokoroONNXModel)
    }

    private let audioCache = NeuralTTSAudioCache(namespace: "Kokoro")
    private var manager: Backend?
    private var preparationTask: Task<Backend, Error>?
    private var preparationGeneration = 0
    private var inFlight: [String: Task<[Float], Error>] = [:]

    func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard Self.isSupportedOnCurrentOS else { throw NeuralTTSError.unsupportedOS }
        if manager != nil {
            progress?(1)
            return
        }

        let generation = preparationGeneration
        let task: Task<Backend, Error>
        if let preparationTask {
            task = preparationTask
        } else {
            task = Task {
                if Self.usesONNX(on: ProcessInfo.processInfo.operatingSystemVersion) {
                    let model = try await KokoroONNXModel.prepare(progress: progress)
                    NeuralTTSStorage.excludeModelsFromBackup()
                    return .onnx(model)
                }
                let directory = try await KokoroAneResourceDownloader.ensureModels(
                    variant: .english,
                    progressHandler: { update in progress?(update.fractionCompleted * 0.9) }
                )
                try await KokoroAneResourceDownloader.ensureG2PAssets(
                    progressHandler: { update in progress?(0.9 + update.fractionCompleted * 0.08) }
                )
                _ = await KokoroAneResourceDownloader.ensureEnglishLexicon()
                try await KokoroTTSVoiceAssets.ensureDownloaded(in: directory)
                NeuralTTSStorage.excludeModelsFromBackup()
                try Task.checkCancellation()
                let manager = KokoroAneManager(variant: .english, computeUnits: .default)
                try await manager.initialize(preloadVoices: Set(KokoroTTSVoice.allCases.map(\.rawValue)))
                return .coreML(manager)
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

    func synthesize(text: String, voice: KokoroTTSVoice, speed: Float) async throws -> [Float] {
        try Task.checkCancellation()
        let cacheKey = audioCache.key(
            Self.usesONNX(on: ProcessInfo.processInfo.operatingSystemVersion) ? "onnx-cpu-\(KokoroONNXAssets.revision)" : "v2",
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

        try await prepare()
        guard let manager else { throw NeuralTTSError.notReady }

        let task = Task { [audioCache] in
            let samples = try await Self.generateSamples(text: text, voice: voice, speed: speed, manager: manager)
            try Task.checkCancellation()
            try audioCache.store(samples, key: cacheKey)
            return samples
        }
        inFlight[cacheKey] = task
        do {
            let samples = try await task.value
            try Task.checkCancellation()
            inFlight[cacheKey] = nil
            return samples
        } catch {
            inFlight[cacheKey] = nil
            throw error
        }
    }

    private nonisolated static func generateSamples(
        text: String,
        voice: KokoroTTSVoice,
        speed: Float,
        manager: Backend
    ) async throws -> [Float] {
        let chunks = Self.chunks(text)
        let silence = [Float](
            repeating: 0,
            count: Int(Double(KokoroAneConstants.sampleRate) * 0.12)
        )
        var samples: [Float] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let generated: [Float]
            switch manager {
            case .coreML(let coreML):
                generated = try await coreML.synthesizeDetailed(text: chunk, voice: voice.rawValue, speed: speed).samples
            case .onnx(let onnx):
                generated = try await onnx.synthesize(text: chunk, voice: voice, speed: speed)
            }
            if index > 0 {
                samples.append(contentsOf: silence)
            }
            samples.append(contentsOf: generated)
        }

        guard !samples.isEmpty else { throw NeuralTTSError.emptyAudio }
        return samples
    }

    /// Everything removal deletes for both the Core ML and ONNX backends.
    nonisolated static var modelDirectories: [URL] {
        get throws {
            let models = try TtsCacheDirectory.ensure().appendingPathComponent("Models", isDirectory: true)
            let onnx = try KokoroONNXAssets.directory
            return [Repo.kokoroAne, .kokoro].map { models.appendingPathComponent($0.folderName, isDirectory: true) } + [onnx]
        }
    }

    func removeModels() async throws {
        await unload()
        for url in try Self.modelDirectories where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try? audioCache.removeAll()
    }

    func unload() async {
        preparationGeneration += 1
        let preparationTask = self.preparationTask
        self.preparationTask = nil
        preparationTask?.cancel()
        let preparingManager = try? await preparationTask?.value
        if case .coreML(let coreML) = preparingManager {
            await coreML.cleanup()
        }
        let tasks = Array(inFlight.values)
        tasks.forEach { $0.cancel() }
        inFlight.removeAll()
        for task in tasks {
            _ = try? await task.value
        }
        if case .coreML(let coreML) = manager {
            await coreML.cleanup()
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
    private let voice: KokoroTTSVoice
    private let startAnchor: EbookTTSStartAnchor
    private let fallbackEngine: AnchoredAVTTSEngine
    private let audioPlayer = NeuralTTSAudioPlayer(
        sampleRate: Double(KokoroAneConstants.sampleRate)
    )

    init(
        runtime: KokoroTTSRuntime = .shared,
        voice: KokoroTTSVoice,
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
        guard !Task.isCancelled else { return .success(()) }
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

    nonisolated static var hasDownloadedVoices: Bool { false }

    func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        throw NeuralTTSError.notReady
    }

    func synthesize(text: String, voice: KokoroTTSVoice, speed: Float) async throws -> [Float] {
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
        voice: KokoroTTSVoice,
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
