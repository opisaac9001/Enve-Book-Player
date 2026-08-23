import AVFoundation
import Combine
import Foundation
import Logging
import MediaPlayer
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared

#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif

#if !targetEnvironment(macCatalyst)
private nonisolated struct EbookTTSActivityHandle: @unchecked Sendable {
    let activity: Activity<BookTTSActivityAttributes>
}
#endif

@preconcurrency @MainActor
final class EbookTTSService: NSObject, ObservableObject {
    private static let rateDefaultsKey = "ebookTTS.rate"
    private static let voiceDefaultsKey = "ebookTTS.voiceIdentifier"
    private static let languageDefaultsKey = "ebookTTS.languageIdentifier"
    private static let engineDefaultsKey = "ebookTTS.engine"
    private static let enhancedVoiceDefaultsKey = "ebookTTS.enhancedVoice"
    private static let enhancedModelReadyDefaultsKey = "ebookTTS.enhancedModelReady"
    private static let kokoroModelReadyDefaultsKey = "ebookTTS.kokoroModelReady"

    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var currentUtteranceText: String = ""
    @Published var rate: Float = 1.0 {
        didSet {
            rate = Self.clampedRate(rate)
            appleEngine?.currentRate = rate
            supertonicEngine?.currentRate = rate
            kokoroEngine?.currentRate = rate
            userDefaults.set(Double(rate), forKey: Self.rateDefaultsKey)
            updateNowPlayingInfo()
        }
    }
    @Published var selectedVoiceIdentifier: String?
    @Published var preferredLanguageIdentifier: String?
    @Published var highlightLocator: Locator?
    @Published private(set) var followLocator: Locator?
    @Published private(set) var engineChoice: EbookTTSEngineChoice = .apple
    @Published private(set) var enhancedVoice: EnhancedTTSVoice = .m1
    @Published private(set) var enhancedDownloadState: TTSModelDownloadState = .notDownloaded
    @Published private(set) var kokoroDownloadState: TTSModelDownloadState = .notDownloaded

    private(set) var synthesizer: PublicationSpeechSynthesizer?
    private var publication: Publication?
    private var appleEngine: AnchoredAVTTSEngine?
    private var supertonicEngine: SupertonicTTSEngine?
    private var kokoroEngine: KokoroTTSEngine?
    private let startAnchor = EbookTTSStartAnchor()
    private var modelDownloadTask: Task<Void, Never>?
    private var paragraphPrewarmTask: Task<Void, Never>?
    private var nowPlayingTitle: String?
    private var nowPlayingAuthor: String?
    private var nowPlayingArtworkURL: URL?
    private var nowPlayingContentIdentifier: String?
    #if !targetEnvironment(macCatalyst)
    private var liveActivity: EbookTTSActivityHandle?
    #endif
    private let userDefaults: UserDefaults

    var availableVoices: [TTSVoice] {
        RateAwareAVTTSEngineDelegate.supportedVoices()
    }

    var availableLanguages: [Language] {
        let languages: [Language]
        switch engineChoice {
        case .apple:
            languages = availableVoices.map { $0.language.removingRegion() }
        case .supertonic3:
            languages = EnhancedTTSVoice.supportedLanguageCodes.map {
                Language(code: .bcp47($0))
            }
        case .kokoro:
            languages = [Language(code: .bcp47("en"))]
        }
        return Array(Set(languages))
            .sorted { $0.localizedDescription() < $1.localizedDescription() }
    }

    var currentVoiceDisplayName: String {
        switch engineChoice {
        case .supertonic3:
            return "Supertonic 3 · \(enhancedVoice.rawValue)"
        case .kokoro:
            return "Kokoro · Heart"
        case .apple:
            break
        }
        if let id = selectedVoiceIdentifier,
            let voice = voiceWithIdentifier(id)
        {
            return voice.name
        }
        if let voice = recommendedVoice() {
            return "Automatic: \(voice.name)"
        }
        return "Automatic"
    }

    var currentLanguageDisplayName: String {
        preferredLanguage?.localizedDescription()
            ?? bookLanguageDisplayName
    }

    var bookLanguageDisplayName: String {
        publication?.metadata.language?.localizedDescription()
            ?? "Book Language"
    }

    override init() {
        self.userDefaults = .standard
        super.init()

        if let savedRate = userDefaults.object(forKey: Self.rateDefaultsKey) as? Double {
            rate = Self.clampedRate(Float(savedRate))
        }
        selectedVoiceIdentifier = userDefaults.string(forKey: Self.voiceDefaultsKey)
        preferredLanguageIdentifier = userDefaults.string(forKey: Self.languageDefaultsKey)
        enhancedVoice =
            userDefaults.string(forKey: Self.enhancedVoiceDefaultsKey)
            .flatMap(EnhancedTTSVoice.init(rawValue:))
            ?? .m1
        enhancedDownloadState =
            userDefaults.bool(forKey: Self.enhancedModelReadyDefaultsKey)
            ? .ready
            : .notDownloaded
        kokoroDownloadState =
            userDefaults.bool(forKey: Self.kokoroModelReadyDefaultsKey)
            ? .ready
            : .notDownloaded
        let savedEngine =
            userDefaults.string(forKey: Self.engineDefaultsKey)
            .flatMap(EbookTTSEngineChoice.init(rawValue:))
            ?? .apple
        engineChoice = isModelReady(for: savedEngine) ? savedEngine : .apple
        sanitizePersistedPreferences()
    }

    func configure(
        with publication: Publication,
        title: String? = nil,
        author: String? = nil,
        artworkURL: URL? = nil,
        contentIdentifier: String? = nil
    ) {
        self.publication = publication
        nowPlayingTitle = title
        nowPlayingAuthor = author
        nowPlayingArtworkURL = artworkURL
        nowPlayingContentIdentifier = contentIdentifier

        guard PublicationSpeechSynthesizer.canSpeak(publication: publication) else {
            AppLogger.network.error("Publication cannot be synthesized")
            return
        }

        rebuildSynthesizer(resumeFrom: nil, shouldResume: false, shouldPauseAfterResume: false)
    }

    func startSpeaking(from locator: Locator? = nil) {
        if synthesizer == nil, publication != nil {
            rebuildSynthesizer(resumeFrom: nil, shouldResume: false, shouldPauseAfterResume: false)
        }
        guard let synth = synthesizer else { return }
        activateAudioSession()
        NowPlayingCoordinator.shared.setActive(self)
        startAnchor.prepare(fragment: locator?.text.highlight)
        synth.start(from: locator)
        isPlaying = true
        isPaused = false
        updateNowPlayingInfo()
        updateLiveActivity()
    }

    func pause() {
        synthesizer?.pause()
        paragraphPrewarmTask?.cancel()
        isPaused = true
        isPlaying = false
        updateNowPlayingInfo()
        updateLiveActivity()
    }

    func resume() {
        activateAudioSession()
        NowPlayingCoordinator.shared.setActive(self)
        synthesizer?.resume()
        isPaused = false
        isPlaying = true
        updateNowPlayingInfo()
        updateLiveActivity()
    }

    func stop() {
        synthesizer?.stop()
        paragraphPrewarmTask?.cancel()
        isPlaying = false
        isPaused = false
        currentUtteranceText = ""
        highlightLocator = nil
        followLocator = nil
        NowPlayingCoordinator.shared.resignIfActive(self)
        NowPlayingCoordinator.shared.clearNowPlaying(if: self)
        endLiveActivity()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else if isPaused {
            resume()
        }
    }

    func nextParagraph() {
        synthesizer?.next()
    }

    func previousParagraph() {
        synthesizer?.previous()
    }

    func setRate(_ newRate: Float) {
        rate = Self.clampedRate(newRate)
    }

    func setEngineChoice(_ choice: EbookTTSEngineChoice) {
        if choice != .apple, !isModelReady(for: choice) {
            downloadModel(for: choice)
            return
        }
        guard choice != engineChoice else { return }
        applyEngineChoice(choice)
    }

    func downloadModel(for choice: EbookTTSEngineChoice) {
        guard choice != .apple,
            downloadState(for: choice) != .ready,
            !EbookTTSEngineChoice.allCases.contains(where: {
                switch downloadState(for: $0) {
                case .downloading, .removing: true
                default: false
                }
            })
        else { return }

        if engineChoice != .apple, engineChoice != choice {
            applyEngineChoice(.apple)
        }
        setDownloadState(.downloading(0), for: choice)
        modelDownloadTask?.cancel()
        modelDownloadTask = Task { [weak self] in
            guard let service = self else { return }
            do {
                let progressHandler: @Sendable (Double) -> Void = { progress in
                    Task { @MainActor in
                        guard case .downloading = service.downloadState(for: choice) else { return }
                        service.setDownloadState(.downloading(progress), for: choice)
                    }
                }
                switch choice {
                case .apple:
                    return
                case .supertonic3:
                    await KokoroTTSRuntime.shared.unload()
                    try await SupertonicTTSRuntime.shared.prepareVoicePack(progress: progressHandler)
                case .kokoro:
                    await SupertonicTTSRuntime.shared.unload()
                    try await KokoroTTSRuntime.shared.prepare(progress: progressHandler)
                }
                guard !Task.isCancelled else { return }
                service.setDownloadState(.ready, for: choice)
                service.userDefaults.set(true, forKey: service.modelReadyDefaultsKey(for: choice))
                service.applyEngineChoice(choice)
            } catch is CancellationError {
                let state: TTSModelDownloadState =
                    service.userDefaults.bool(
                        forKey: service.modelReadyDefaultsKey(for: choice)
                    )
                    ? .ready
                    : .notDownloaded
                service.setDownloadState(state, for: choice)
            } catch {
                service.setDownloadState(.failed(error.localizedDescription), for: choice)
            }
        }
    }

    func removeModel(for choice: EbookTTSEngineChoice) {
        guard choice != .apple,
            downloadState(for: choice) == .ready
        else { return }

        if engineChoice == choice {
            applyEngineChoice(.apple)
        }
        setDownloadState(.removing, for: choice)
        modelDownloadTask?.cancel()
        modelDownloadTask = Task { [weak self] in
            guard let service = self else { return }
            do {
                switch choice {
                case .apple:
                    return
                case .supertonic3:
                    try await SupertonicTTSRuntime.shared.removeModels()
                case .kokoro:
                    try await KokoroTTSRuntime.shared.removeModels()
                }
                service.userDefaults.set(false, forKey: service.modelReadyDefaultsKey(for: choice))
                service.setDownloadState(.notDownloaded, for: choice)
            } catch {
                service.setDownloadState(.failed(error.localizedDescription), for: choice)
            }
        }
    }

    func downloadState(for choice: EbookTTSEngineChoice) -> TTSModelDownloadState {
        switch choice {
        case .apple: .ready
        case .supertonic3: enhancedDownloadState
        case .kokoro: kokoroDownloadState
        }
    }

    func setEnhancedVoice(_ voice: EnhancedTTSVoice) {
        guard voice != enhancedVoice else { return }
        enhancedVoice = voice
        userDefaults.set(voice.rawValue, forKey: Self.enhancedVoiceDefaultsKey)

        guard engineChoice == .supertonic3 else { return }
        rebuildPreservingPlayback()
    }

    func setVoice(_ identifier: String?) {
        let normalized = normalizedVoiceIdentifier(identifier)
        guard normalized != selectedVoiceIdentifier else { return }

        let resumeLocator = highlightLocator
        let shouldResume = isPlaying || isPaused
        let shouldPauseAfterResume = isPaused

        selectedVoiceIdentifier = normalized
        persistPreferences()

        if publication != nil {
            rebuildSynthesizer(
                resumeFrom: resumeLocator,
                shouldResume: shouldResume,
                shouldPauseAfterResume: shouldPauseAfterResume
            )
        }
    }

    func setPreferredLanguage(_ identifier: String?) {
        let normalized = normalizedLanguageIdentifier(identifier)
        guard normalized != preferredLanguageIdentifier else { return }

        let resumeLocator = highlightLocator
        let shouldResume = isPlaying || isPaused
        let shouldPauseAfterResume = isPaused

        preferredLanguageIdentifier = normalized
        persistPreferences()

        if publication != nil {
            rebuildSynthesizer(
                resumeFrom: resumeLocator,
                shouldResume: shouldResume,
                shouldPauseAfterResume: shouldPauseAfterResume
            )
        }
    }

    func voiceWithIdentifier(_ identifier: String) -> TTSVoice? {
        availableVoices.first { $0.identifier == identifier }
    }

    func recommendedVoice(for language: Language? = nil) -> TTSVoice? {
        let target = language ?? preferredLanguage ?? publication?.metadata.language ?? .current
        let exactMatches = availableVoices.filterByLanguage(target)
        if let voice = exactMatches.sorted().first {
            return voice
        }
        let baseMatches = availableVoices.filterByLanguage(target.removingRegion())
        if let voice = baseMatches.sorted().first {
            return voice
        }
        return availableVoices.sorted().first
    }

    func tearDown() {
        synthesizer?.delegate = nil
        synthesizer?.stop()
        paragraphPrewarmTask?.cancel()
        isPlaying = false
        isPaused = false
        currentUtteranceText = ""
        highlightLocator = nil
        followLocator = nil
        synthesizer = nil
        appleEngine = nil
        supertonicEngine = nil
        kokoroEngine = nil
        publication = nil
        nowPlayingTitle = nil
        nowPlayingAuthor = nil
        nowPlayingArtworkURL = nil
        nowPlayingContentIdentifier = nil
        NowPlayingCoordinator.shared.resignIfActive(self)
        NowPlayingCoordinator.shared.clearNowPlaying(if: self)
        endLiveActivity()
    }

    private var preferredLanguage: Language? {
        guard let preferredLanguageIdentifier, !preferredLanguageIdentifier.isEmpty else {
            return nil
        }
        return Language(code: .bcp47(preferredLanguageIdentifier))
    }

    private static func clampedRate(_ rate: Float) -> Float {
        min(max(rate, 0.5), 3.0)
    }

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                policy: .longFormAudio,
                options: [.allowAirPlay, .allowBluetoothA2DP]
            )
            try session.setActive(true)
        } catch {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
            } catch {
                AppLogger.library.error("Ebook narration audio session failed: \(error)")
            }
        }
    }

    private func updateNowPlayingInfo() {
        guard let publication, isPlaying || isPaused else { return }
        let authors = publication.metadata.authors.map(\.name).joined(separator: ", ")
        NowPlayingCoordinator.shared.updateNowPlaying(
            NowPlayingInfo(
                title: nowPlayingTitle ?? publication.metadata.title ?? "Read Aloud",
                artist: nowPlayingAuthor ?? (authors.isEmpty ? nil : authors),
                rate: isPlaying ? Double(rate) : 0,
                defaultRate: 1,
                mediaType: .audio,
                contentIdentifier: nowPlayingContentIdentifier,
                serviceIdentifier: Bundle.main.bundleIdentifier ?? "com.enve.enve",
                artworkURL: nowPlayingArtworkURL
            )
        )
    }

    private func updateLiveActivity() {
        #if !targetEnvironment(macCatalyst)
        let state = BookTTSActivityAttributes.ContentState(isPlaying: isPlaying)
        if let liveActivity {
            Task { await liveActivity.activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }

        guard isPlaying, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let title = nowPlayingTitle ?? publication?.metadata.title ?? "Read Aloud"
        let authors = publication?.metadata.authors.map(\.name).joined(separator: ", ") ?? ""
        let author = nowPlayingAuthor ?? (authors.isEmpty ? "Enve Book Player" : authors)
        do {
            liveActivity = EbookTTSActivityHandle(
                activity: try Activity.request(
                    attributes: BookTTSActivityAttributes(title: title, author: author),
                    content: ActivityContent(state: state, staleDate: nil)
                )
            )
        } catch {
            AppLogger.library.error("Read aloud Live Activity failed: \(error)")
        }
        #endif
    }

    private func endLiveActivity() {
        #if !targetEnvironment(macCatalyst)
        guard let liveActivity else { return }
        self.liveActivity = nil
        let state = BookTTSActivityAttributes.ContentState(isPlaying: false)
        Task {
            await liveActivity.activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
        #endif
    }

    private func normalizedVoiceIdentifier(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return availableVoices.contains(where: { $0.identifier == identifier }) ? identifier : nil
    }

    private func normalizedLanguageIdentifier(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let normalized = Language(code: .bcp47(identifier)).removingRegion().code.bcp47
        return availableLanguages.contains(where: { $0.code.bcp47 == normalized }) ? normalized : nil
    }

    private func effectiveVoiceIdentifier() -> String? {
        guard engineChoice == .apple else { return nil }
        if let selected = normalizedVoiceIdentifier(selectedVoiceIdentifier) {
            return selected
        }
        return recommendedVoice(for: preferredLanguage)?.identifier
    }

    private func persistPreferences() {
        userDefaults.set(selectedVoiceIdentifier, forKey: Self.voiceDefaultsKey)
        userDefaults.set(preferredLanguageIdentifier, forKey: Self.languageDefaultsKey)
    }

    private func applyEngineChoice(_ choice: EbookTTSEngineChoice) {
        engineChoice = choice
        userDefaults.set(choice.rawValue, forKey: Self.engineDefaultsKey)
        let normalizedLanguage = normalizedLanguageIdentifier(preferredLanguageIdentifier)
        if normalizedLanguage != preferredLanguageIdentifier {
            preferredLanguageIdentifier = normalizedLanguage
            persistPreferences()
        }
        rebuildPreservingPlayback()
        Task {
            switch choice {
            case .apple:
                await SupertonicTTSRuntime.shared.unload()
                await KokoroTTSRuntime.shared.unload()
            case .supertonic3:
                await KokoroTTSRuntime.shared.unload()
            case .kokoro:
                await SupertonicTTSRuntime.shared.unload()
            }
        }
    }

    private func isModelReady(for choice: EbookTTSEngineChoice) -> Bool {
        switch choice {
        case .apple:
            true
        case .supertonic3:
            enhancedDownloadState == .ready
        case .kokoro:
            kokoroDownloadState == .ready && KokoroTTSRuntime.isSupportedOnCurrentOS
        }
    }

    private func setDownloadState(
        _ state: TTSModelDownloadState,
        for choice: EbookTTSEngineChoice
    ) {
        switch choice {
        case .apple:
            break
        case .supertonic3:
            enhancedDownloadState = state
        case .kokoro:
            kokoroDownloadState = state
        }
    }

    private func modelReadyDefaultsKey(for choice: EbookTTSEngineChoice) -> String {
        switch choice {
        case .apple: ""
        case .supertonic3: Self.enhancedModelReadyDefaultsKey
        case .kokoro: Self.kokoroModelReadyDefaultsKey
        }
    }

    private func rebuildPreservingPlayback() {
        guard publication != nil else { return }
        rebuildSynthesizer(
            resumeFrom: highlightLocator,
            shouldResume: isPlaying || isPaused,
            shouldPauseAfterResume: isPaused
        )
    }

    private func sanitizePersistedPreferences() {
        let normalizedVoice = normalizedVoiceIdentifier(selectedVoiceIdentifier)
        let normalizedLanguage = normalizedLanguageIdentifier(preferredLanguageIdentifier)
        let didChange = normalizedVoice != selectedVoiceIdentifier || normalizedLanguage != preferredLanguageIdentifier
        selectedVoiceIdentifier = normalizedVoice
        preferredLanguageIdentifier = normalizedLanguage
        if didChange {
            persistPreferences()
        }
    }

    private func makeConfiguration() -> PublicationSpeechSynthesizer.Configuration {
        PublicationSpeechSynthesizer.Configuration(
            defaultLanguage: preferredLanguage,
            voiceIdentifier: effectiveVoiceIdentifier()
        )
    }

    private func rebuildSynthesizer(
        resumeFrom locator: Locator?,
        shouldResume: Bool,
        shouldPauseAfterResume: Bool
    ) {
        guard let publication else { return }

        synthesizer?.delegate = nil
        synthesizer?.stop()
        paragraphPrewarmTask?.cancel()
        let config = makeConfiguration()
        switch engineChoice {
        case .apple:
            supertonicEngine = nil
            kokoroEngine = nil
            let engine = AnchoredAVTTSEngine(rate: rate, anchor: startAnchor)
            appleEngine = engine
            synthesizer = PublicationSpeechSynthesizer(
                publication: publication,
                config: config,
                engineFactory: { @Sendable in engine },
                tokenizerFactory: Self.paragraphTokenizerFactory,
                delegate: self
            )
        case .supertonic3:
            appleEngine = nil
            kokoroEngine = nil
            let engine = SupertonicTTSEngine(
                voice: enhancedVoice,
                rate: rate,
                startAnchor: startAnchor
            )
            supertonicEngine = engine
            synthesizer = PublicationSpeechSynthesizer(
                publication: publication,
                config: config,
                engineFactory: { @Sendable in engine },
                tokenizerFactory: Self.paragraphTokenizerFactory,
                delegate: self
            )
        case .kokoro:
            appleEngine = nil
            supertonicEngine = nil
            let engine = KokoroTTSEngine(rate: rate, startAnchor: startAnchor)
            kokoroEngine = engine
            synthesizer = PublicationSpeechSynthesizer(
                publication: publication,
                config: config,
                engineFactory: { @Sendable in engine },
                tokenizerFactory: Self.paragraphTokenizerFactory,
                delegate: self
            )
        }

        guard shouldResume else { return }
        startSpeaking(from: locator)
        if shouldPauseAfterResume {
            pause()
        }
    }

    private static let paragraphTokenizerFactory: PublicationSpeechSynthesizer.TokenizerFactory = {
        defaultLanguage in
        makeTextContentTokenizer(
            defaultLanguage: defaultLanguage,
            contextSnippetLength: 50,
            textTokenizerFactory: { language in
                makeDefaultTextTokenizer(unit: .paragraph, language: language)
            }
        )
    }

    private func prewarmParagraphs(after locator: Locator) {
        paragraphPrewarmTask?.cancel()
        guard engineChoice != .apple, let publication else { return }

        let choice = engineChoice
        let voice = enhancedVoice
        let speed = rate
        let preferredLanguage = self.preferredLanguage
        paragraphPrewarmTask = Task {
            guard !Task.isCancelled,
                let iterator = publication.content(from: locator)?.iterator()
            else { return }

            let tokenizer = Self.paragraphTokenizerFactory(
                preferredLanguage ?? publication.metadata.language
            )
            var skippedCurrentParagraph = false
            var warmedParagraphs = 0

            while warmedParagraphs < 3,
                !Task.isCancelled,
                let element = try? await iterator.next()
            {
                guard let pieces = try? tokenizer(element) else { continue }
                for piece in pieces {
                    let segments: [(String, Language?)]
                    if let text = piece as? TextContentElement {
                        segments = text.segments.map { ($0.text, $0.language) }
                    } else if let text = (piece as? TextualContentElement)?.text {
                        segments = [(text, piece.language)]
                    } else {
                        continue
                    }

                    for (text, declaredLanguage) in segments {
                        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                        if !skippedCurrentParagraph {
                            skippedCurrentParagraph = true
                            continue
                        }

                        let language =
                            declaredLanguage
                            ?? preferredLanguage
                            ?? publication.metadata.language
                            ?? .current
                        let code =
                            language.code.bcp47
                            .lowercased()
                            .split(separator: "-")
                            .first
                            .map(String.init)
                            ?? "en"
                        do {
                            switch choice {
                            case .apple:
                                return
                            case .supertonic3:
                                guard EnhancedTTSVoice.supportedLanguageCodes.contains(code) else { continue }
                                _ = try await SupertonicTTSRuntime.shared.synthesize(
                                    text: text,
                                    language: code,
                                    voice: voice,
                                    speed: speed
                                )
                            case .kokoro:
                                guard code == "en" else { continue }
                                _ = try await KokoroTTSRuntime.shared.synthesize(
                                    text: text,
                                    speed: speed
                                )
                            }
                        } catch {
                            return
                        }
                        warmedParagraphs += 1
                        if warmedParagraphs == 3 { return }
                    }
                }
            }
        }
    }
}

final class RateAwareAVTTSEngineDelegate: NSObject, AVTTSEngineDelegate, @unchecked Sendable {
    nonisolated(unsafe) var currentRate: Float

    init(initialRate: Float) {
        self.currentRate = initialRate
    }

    nonisolated static func supportedVoices() -> [TTSVoice] {
        AVTTSEngine().availableVoices.sorted()
    }

    private nonisolated var avRate: Float {
        let min = AVSpeechUtteranceMinimumSpeechRate
        let max = AVSpeechUtteranceMaximumSpeechRate
        let def = AVSpeechUtteranceDefaultSpeechRate

        if currentRate >= 1.0 {
            return def + (currentRate - 1.0) / 2.0 * (max - def)
        } else {
            return min + (currentRate - 0.5) / 0.5 * (def - min)
        }
    }

    nonisolated func avTTSEngine(_ engine: AVTTSEngine, didCreateUtterance utterance: AVSpeechUtterance) {
        utterance.rate = avRate
    }
}

extension EbookTTSService: PublicationSpeechSynthesizerDelegate {
    nonisolated func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        stateDidChange state: PublicationSpeechSynthesizer.State
    ) {
        Task { @MainActor in
            switch state {
            case .stopped:
                self.isPlaying = false
                self.isPaused = false
                self.currentUtteranceText = ""
                self.highlightLocator = nil
                self.followLocator = nil
                NowPlayingCoordinator.shared.resignIfActive(self)
                NowPlayingCoordinator.shared.clearNowPlaying(if: self)
                self.endLiveActivity()
            case .paused(let utterance):
                self.isPlaying = false
                self.isPaused = true
                self.currentUtteranceText = utterance.text
                self.followLocator = nil
                self.updateNowPlayingInfo()
                self.updateLiveActivity()
            case .playing(let utterance, let range):
                self.isPlaying = true
                self.isPaused = false
                self.currentUtteranceText = utterance.text
                if let range {
                    self.highlightLocator = range
                    self.followLocator = range
                } else {
                    self.followLocator = nil
                    self.prewarmParagraphs(after: utterance.locator)
                }
                self.updateNowPlayingInfo()
                self.updateLiveActivity()
            }
        }
    }

    nonisolated func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        utterance: PublicationSpeechSynthesizer.Utterance,
        didFailWithError error: PublicationSpeechSynthesizer.Error
    ) {
        Task { @MainActor in
            AppLogger.network.error("Error speaking: \(error)")
            self.isPlaying = false
            self.isPaused = false
            NowPlayingCoordinator.shared.resignIfActive(self)
            NowPlayingCoordinator.shared.clearNowPlaying(if: self)
            self.endLiveActivity()
        }
    }
}

extension EbookTTSService: RemoteCommandTarget {
    func remotePlay() {
        if isPaused { resume() }
    }

    func remotePause() { pause() }
    func remoteToggle() { togglePlayPause() }
    func remoteNext() { nextParagraph() }
    func remotePrevious() { previousParagraph() }
    func remoteSkipForward(by seconds: TimeInterval?) { nextParagraph() }
    func remoteSkipBackward(by seconds: TimeInterval?) { previousParagraph() }
    func remoteSeek(to positionTime: TimeInterval) {}
}
