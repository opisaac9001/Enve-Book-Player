#if os(iOS)
import AVFoundation
import Foundation
import Observation
@preconcurrency import ReadiumNavigator
import UIKit

#if !targetEnvironment(macCatalyst)
import FluidAudio
#endif

enum NarratorVoiceSample: Hashable {
    case apple(voiceIdentifier: String?, language: String)
    case kokoro(KokoroTTSVoice)
    case supertonic(EnhancedTTSVoice, language: String)
    case pocket
    case phonon(PhononVoice)

    var engine: EbookTTSEngineChoice {
        switch self {
        case .apple: .apple
        case .kokoro: .kokoro
        case .supertonic: .supertonic3
        case .pocket: .pocket
        case .phonon: .phonon
        }
    }

    var displayName: String {
        switch self {
        case .apple(let identifier, _):
            identifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))?.name ?? "Apple voice"
        case .kokoro(let voice): "Kokoro · \(voice.displayName)"
        case .supertonic(let voice, _): "Supertonic 3 · \(voice.displayName)"
        case .pocket: "Pocket TTS · Alba"
        case .phonon(let voice): "Phonon · \(voice.rawValue)"
        }
    }

    var text: String {
        let language: String
        switch self {
        case .apple(_, let code), .supertonic(_, let code): language = code
        case .kokoro, .pocket, .phonon: language = "en"
        }
        let base = language.lowercased().split(separator: "-").first.map(String.init) ?? "en"
        return Self.sentences[base] ?? Self.english
    }

    private static let english = "This is how I will sound reading your book aloud."
    private static let sentences = [
        "de": "So klinge ich, wenn ich dir dein Buch vorlese.",
        "es": "Así sonará mi voz al leer tu libro en voz alta.",
        "fr": "Voici comment je lirai votre livre à voix haute.",
        "it": "Ecco come suonerò leggendo il tuo libro ad alta voce.",
        "ja": "あなたの本をこの声で読み上げます。",
        "ko": "이 목소리로 책을 읽어 드릴게요.",
        "nl": "Zo klink ik als ik je boek voorlees.",
        "pt": "É assim que vou soar ao ler o seu livro em voz alta.",
        "zh": "我会用这个声音为你朗读这本书。",
    ]
}

// Samples have no publication, reading-position, or Now Playing ownership.
@Observable @MainActor
final class NarratorVoicePreview {
    enum Phase: Equatable {
        case idle
        case preparing(NarratorVoiceSample)
        case playing(NarratorVoiceSample)
        case failed(NarratorVoiceSample, String)

        var sample: NarratorVoiceSample? {
            switch self {
            case .idle: nil
            case .preparing(let sample), .playing(let sample), .failed(let sample, _): sample
            }
        }
    }

    struct Runtime {
        /// Speaks one sample, calling `didStart` when audio begins, and returns early when the task is cancelled.
        var speak: @MainActor (_ sample: NarratorVoiceSample, _ rate: Float, _ didStart: @escaping @MainActor () -> Void) async throws -> Void
    }

    private(set) var phase: Phase = .idle

    private let models: NarratorModelStore
    private let runtime: Runtime
    @ObservationIgnored nonisolated(unsafe) private var task: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isRegistered = false

    init(models: NarratorModelStore = .shared, runtime: Runtime = .live()) {
        self.models = models
        self.runtime = runtime
    }

    deinit {
        task?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func isActive(_ sample: NarratorVoiceSample) -> Bool {
        switch phase {
        case .preparing(sample), .playing(sample): true
        default: false
        }
    }

    func play(_ sample: NarratorVoiceSample, rate: Float, pausing narration: EbookTTSService? = nil) {
        registerIfNeeded()
        cancelCurrent()
        let generation = generation
        guard models.isReady(sample.engine), models.hasInstalledFiles(sample.engine) else {
            phase = .failed(sample, "Download \(sample.engine.modelName) to hear a sample.")
            models.use([], by: self)
            return
        }
        if let narration, narration.isPlaying { narration.pause() }
        phase = .preparing(sample)
        let residency = models.use(sample.engine == .apple ? [] : [sample.engine], by: self)
        let speak = runtime.speak
        task = Task { [weak self] in
            do {
                // Rapid taps replace the sample before any synthesis is queued.
                try await Task.sleep(for: .milliseconds(150))
                await residency.value
                try Task.checkCancellation()
                try await speak(sample, rate) { [weak self] in
                    guard let self, self.generation == generation else { return }
                    phase = .playing(sample)
                }
                guard let self, self.generation == generation else { return }
                phase = .idle
                task = nil
                models.use([], by: self)
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation else { return }
                phase = .failed(sample, error.localizedDescription)
                task = nil
                models.use([], by: self)
            }
        }
    }

    func stop() {
        cancelCurrent()
        phase = .idle
        models.use([], by: self)
    }

    /// Stops the sample and releases any model loaded only for previews.
    func invalidate() {
        stop()
        guard isRegistered else { return }
        isRegistered = false
        models.unregister(self)
    }

    private func cancelCurrent() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    private func registerIfNeeded() {
        guard !isRegistered else { return }
        isRegistered = true
        models.register(self) { [weak self] event in
            guard case .willRemove(let engine) = event, let self,
                phase.sample?.engine == engine else { return }
            stop()
        }
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
                let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                MainActor.assumeIsolated { if began { self?.stop() } }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
                let lostOutput = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                MainActor.assumeIsolated { if lostOutput { self?.stop() } }
            },
        ]
    }
}

extension NarratorVoicePreview.Runtime {
    static func live() -> Self {
        let audio = NarratorPreviewAudio()
        return Self(speak: { sample, rate, didStart in
            try await audio.speak(sample, rate: rate, didStart: didStart)
        })
    }
}

/// Reuses the shared runtime actors and the reader's PCM player; it owns no models of its own.
@MainActor
private final class NarratorPreviewAudio: NSObject, AVSpeechSynthesizerDelegate {
    private var synthesizer: AVSpeechSynthesizer?
    private var speech: (utterance: AVSpeechUtterance, continuation: CheckedContinuation<Void, Never>)?

    func speak(_ sample: NarratorVoiceSample, rate: Float, didStart: @MainActor () -> Void) async throws {
        try await activateSession()
        try Task.checkCancellation()
        if case .apple(let identifier, let language) = sample {
            didStart()
            await speakApple(sample.text, voice: identifier.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: language), rate: rate)
            return
        }
        #if targetEnvironment(macCatalyst)
        throw NeuralTTSError.notReady
        #else
        let samples = try await synthesize(sample, rate: rate)
        try Task.checkCancellation()
        let player = player(for: sample.engine)
        didStart()
        let result = await withTaskCancellationHandler {
            await player.play(samples, text: sample.text, rate: [.pocket, .phonon].contains(sample.engine) ? rate : 1, onSpeakRange: { _ in })
        } onCancel: {
            Task { @MainActor in player.cancel() }
        }
        if case .failure(let error) = result { throw error }
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    private func synthesize(_ sample: NarratorVoiceSample, rate: Float) async throws -> [Float] {
        switch sample {
        case .apple: []
        case .kokoro(let voice):
            try await KokoroTTSRuntime.shared.synthesize(text: sample.text, voice: voice, speed: rate)
        case .supertonic(let voice, let language):
            try await SupertonicTTSRuntime.shared.synthesize(text: sample.text, language: language, voice: voice, speed: rate)
        case .pocket:
            try await PocketTTSRuntime.shared.synthesize(text: sample.text)
        case .phonon(let voice):
            try await PhononTTSRuntime.shared.synthesize(text: sample.text, voice: voice)
        }
    }

    private func player(for engine: EbookTTSEngineChoice) -> NeuralTTSAudioPlayer {
        switch engine {
        case .pocket: NeuralTTSAudioPlayer(sampleRate: Double(PocketTtsConstants.audioSampleRate), adjustsRate: true)
        case .phonon: NeuralTTSAudioPlayer(sampleRate: 24_000, adjustsRate: true)
        case .supertonic3: NeuralTTSAudioPlayer(sampleRate: Double(Supertonic3Constants.sampleRate))
        case .apple, .kokoro: NeuralTTSAudioPlayer(sampleRate: Double(KokoroAneConstants.sampleRate))
        }
    }
    #endif

    private func speakApple(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float) async {
        let synthesizer = synthesizer ?? makeSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AnchoredAVTTSEngine.appleSpeechRate(for: rate)
        let id = ObjectIdentifier(utterance)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                finishSpeech()
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                speech = (utterance, continuation)
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishSpeech(id) }
        }
    }

    private func makeSynthesizer() -> AVSpeechSynthesizer {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        self.synthesizer = synthesizer
        return synthesizer
    }

    private func finishSpeech(_ id: ObjectIdentifier? = nil) {
        guard let speech, id == nil || ObjectIdentifier(speech.utterance) == id else { return }
        self.speech = nil
        if synthesizer?.isSpeaking == true { synthesizer?.stopSpeaking(at: .immediate) }
        speech.continuation.resume()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishSpeech(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishSpeech(id) }
    }

    /// Joins the app's playback session without changing a category another player already configured.
    private func activateSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            AudioSessionQueue.perform {
                let session = AVAudioSession.sharedInstance()
                if session.category != .playback {
                    try session.setCategory(.playback, mode: .spokenAudio)
                }
                try session.setActive(true)
            } completion: { failure in
                if let failure { continuation.resume(throwing: failure) }
                else { continuation.resume() }
            }
        }
    }
}
#endif
