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
    private static let kokoroVoiceDefaultsKey = "ebookTTS.kokoroVoice"
    private static let kokoroModelReadyDefaultsKey = "ebookTTS.kokoroModelReady"

    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var currentUtteranceText: String = ""
    @Published var rate: Float {
        didSet {
            let validated = Self.validatedRate(rate) ?? oldValue
            if validated != rate { rate = validated }
            guard validated != oldValue else { return }
            scheduleRateCommit()
        }
    }
    @Published var selectedVoiceIdentifier: String?
    @Published var preferredLanguageIdentifier: String?
    @Published var highlightLocator: Locator?
    @Published private(set) var followLocator: Locator?
    @Published private(set) var engineChoice: EbookTTSEngineChoice = .apple
    @Published private(set) var speechError: String?
    @Published private(set) var kokoroVoice: KokoroTTSVoice = .heart
    @Published private(set) var kokoroDownloadState: TTSModelDownloadState = .notDownloaded

    private(set) var synthesizer: PublicationSpeechSynthesizer?
    private var publication: Publication?
    private var appleEngine: AnchoredAVTTSEngine?
    private var modelDownloadGeneration = 0
    private static var modelPreparationTask: Task<Void, Never>?
    private var enginePreparationTask: Task<Void, Never>?
    private var kokoroEngine: KokoroTTSEngine?
    private let startAnchor = EbookTTSStartAnchor()
    private var playbackGeneration = 0
    private var needsInitialStart = false
    private var pendingStartLocator: Locator?
    private var modelDownloadTask: Task<Void, Never>?
    private var paragraphPrewarmTask: Task<Void, Never>?
    private var prewarmedUtterance: PublicationSpeechSynthesizer.Utterance?
    private var nowPlayingTitle: String?
    private var nowPlayingAuthor: String?
    private var nowPlayingArtworkURL: URL?
    private var nowPlayingContentIdentifier: String?
    private var rateCommitTask: Task<Void, Never>?
    private var cachedVoices: [TTSVoice]?
    private var voicesChangeObserver: AnyCancellable?
    #if !targetEnvironment(macCatalyst)
    private var liveActivity: EbookTTSActivityHandle?
    #endif
    private let userDefaults: UserDefaults

    var availableVoices: [TTSVoice] {
        if let cachedVoices { return cachedVoices }
        let voices = RateAwareAVTTSEngineDelegate.supportedVoices()
        cachedVoices = voices
        return voices
    }

    var availableLanguages: [Language] {
        let languages: [Language]
        switch engineChoice {
        case .apple:
            languages = availableVoices.map { $0.language.removingRegion() }
        case .kokoro:
            languages = [Language(code: .bcp47("en"))]
        }
        return Array(Set(languages))
            .sorted { $0.localizedDescription() < $1.localizedDescription() }
    }

    var currentVoiceDisplayName: String {
        switch engineChoice {
        case .kokoro:
            return "Kokoro · \(kokoroVoice.displayName)"
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

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let savedRate = (userDefaults.object(forKey: Self.rateDefaultsKey) as? Double).map(Float.init)
        _rate = Published(initialValue: savedRate.flatMap(Self.validatedRate) ?? 1.0)
        super.init()

        voicesChangeObserver = NotificationCenter.default
            .publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.cachedVoices = nil }
        selectedVoiceIdentifier = userDefaults.string(forKey: Self.voiceDefaultsKey)
        preferredLanguageIdentifier = userDefaults.string(forKey: Self.languageDefaultsKey)
        kokoroVoice =
            userDefaults.string(forKey: Self.kokoroVoiceDefaultsKey)
            .flatMap(KokoroTTSVoice.init(rawValue:))
            ?? .heart
        kokoroDownloadState =
            userDefaults.bool(forKey: Self.kokoroModelReadyDefaultsKey)
                && KokoroTTSRuntime.hasDownloadedVoices
            ? .ready
            : .notDownloaded
        let savedEngine =
            userDefaults.string(forKey: Self.engineDefaultsKey)
            .flatMap(EbookTTSEngineChoice.init(rawValue:))
            ?? .apple
        engineChoice = isModelReady(for: savedEngine) ? savedEngine : .apple
        if let storedEngine = userDefaults.string(forKey: Self.engineDefaultsKey),
            storedEngine != engineChoice.rawValue
        {
            userDefaults.set(engineChoice.rawValue, forKey: Self.engineDefaultsKey)
        }
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

        prepareEngine(engineChoice)
        rebuildSynthesizer(resumeFrom: nil, shouldResume: false, shouldPauseAfterResume: false)
    }

    func startSpeaking(from locator: Locator? = nil) {
        speechError = nil
        if synthesizer == nil, publication != nil {
            rebuildSynthesizer(resumeFrom: nil, shouldResume: false, shouldPauseAfterResume: false)
        }
        guard synthesizer != nil else { return }
        NowPlayingCoordinator.shared.setActive(self)
        startAnchor.prepare(fragment: locator?.text.highlight)
        needsInitialStart = true
        pendingStartLocator = locator
        isPlaying = true
        isPaused = false
        activateAudioSession { [weak self] in
            guard let self, let synth = self.synthesizer else { return }
            synth.start(from: locator)
            self.isPlaying = true
            self.isPaused = false
            self.updateNowPlayingInfo()
            self.updateLiveActivity()
        }
    }

    func pause() {
        cancelPendingStart()
        synthesizer?.pause()
        paragraphPrewarmTask?.cancel()
        prewarmedUtterance = nil
        isPaused = true
        isPlaying = false
        updateNowPlayingInfo()
        updateLiveActivity()
    }

    func resume() {
        speechError = nil
        guard let synthesizer else { return }
        if needsInitialStart || synthesizer.state == .stopped {
            startSpeaking(from: pendingStartLocator ?? highlightLocator)
            return
        }
        isPlaying = true
        isPaused = false
        NowPlayingCoordinator.shared.setActive(self)
        activateAudioSession { [weak self] in
            guard let self else { return }
            self.synthesizer?.resume()
            self.isPaused = false
            self.isPlaying = true
            self.updateNowPlayingInfo()
            self.updateLiveActivity()
        }
    }

    func stop() {
        speechError = nil
        cancelPendingStart()
        needsInitialStart = false
        pendingStartLocator = nil
        synthesizer?.stop()
        paragraphPrewarmTask?.cancel()
        prewarmedUtterance = nil
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
        rate = newRate
        commitRate()
    }

    func commitRate() {
        rateCommitTask?.cancel()
        rateCommitTask = nil
        appleEngine?.currentRate = rate
        kokoroEngine?.currentRate = rate
        guard userDefaults.object(forKey: Self.rateDefaultsKey) as? Double != Double(rate) else { return }
        userDefaults.set(Double(rate), forKey: Self.rateDefaultsKey)
        updateNowPlayingInfo()
    }

    private func scheduleRateCommit() {
        rateCommitTask?.cancel()
        rateCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.commitRate()
        }
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
        guard choice == .kokoro else { return }
        switch kokoroDownloadState {
        case .notDownloaded, .failed:
            break
        case .downloading, .removing, .ready:
            return
        }

        modelDownloadGeneration &+= 1
        let generation = modelDownloadGeneration
        kokoroDownloadState = .downloading(0)
        modelDownloadTask?.cancel()
        modelDownloadTask = Task { [weak self] in
            guard let service = self else { return }
            do {
                await Self.modelPreparationTask?.value
                try Task.checkCancellation()
                try await KokoroTTSRuntime.shared.prepare { progress in
                    Task { @MainActor in
                        guard service.modelDownloadGeneration == generation,
                            case .downloading = service.kokoroDownloadState
                        else { return }
                        service.kokoroDownloadState = .downloading(progress)
                    }
                }
                guard !Task.isCancelled, service.modelDownloadGeneration == generation else { return }
                service.kokoroDownloadState = .ready
                service.userDefaults.set(true, forKey: Self.kokoroModelReadyDefaultsKey)
                service.applyEngineChoice(.kokoro)
            } catch is CancellationError {
                guard service.modelDownloadGeneration == generation else { return }
                service.kokoroDownloadState = service.userDefaults.bool(forKey: Self.kokoroModelReadyDefaultsKey)
                    && KokoroTTSRuntime.hasDownloadedVoices ? .ready : .notDownloaded
            } catch {
                guard service.modelDownloadGeneration == generation else { return }
                service.kokoroDownloadState = .failed(error.localizedDescription)
            }
        }
    }

    func removeModel(for choice: EbookTTSEngineChoice) {
        guard choice == .kokoro, kokoroDownloadState == .ready else { return }
        if engineChoice == .kokoro {
            applyEngineChoice(.apple)
        }
        modelDownloadGeneration &+= 1
        let generation = modelDownloadGeneration
        kokoroDownloadState = .removing
        modelDownloadTask?.cancel()
        modelDownloadTask = Task { [weak self] in
            guard let service = self else { return }
            do {
                await Self.modelPreparationTask?.value
                try await KokoroTTSRuntime.shared.removeModels()
                guard service.modelDownloadGeneration == generation else { return }
                service.userDefaults.set(false, forKey: Self.kokoroModelReadyDefaultsKey)
                service.kokoroDownloadState = .notDownloaded
            } catch {
                guard service.modelDownloadGeneration == generation else { return }
                service.kokoroDownloadState = .failed(error.localizedDescription)
            }
        }
    }

    func downloadState(for choice: EbookTTSEngineChoice) -> TTSModelDownloadState {
        switch choice {
        case .apple: .ready
        case .kokoro: kokoroDownloadState
        }
    }

    func setKokoroVoice(_ voice: KokoroTTSVoice) {
        guard voice != kokoroVoice else { return }
        kokoroVoice = voice
        userDefaults.set(voice.rawValue, forKey: Self.kokoroVoiceDefaultsKey)

        guard engineChoice == .kokoro else { return }
        rebuildPreservingPlayback()
    }

    func setVoice(_ identifier: String?) {
        let normalized = normalizedVoiceIdentifier(identifier)
        guard normalized != selectedVoiceIdentifier else { return }

        let resumeLocator = pendingStartLocator ?? highlightLocator
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

        let resumeLocator = pendingStartLocator ?? highlightLocator
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
        enginePreparationTask?.cancel()
        enginePreparationTask = nil
        commitRate()
        cancelPendingStart()
        needsInitialStart = false
        pendingStartLocator = nil
        synthesizer?.delegate = nil
        synthesizer?.stop()
        paragraphPrewarmTask?.cancel()
        prewarmedUtterance = nil
        isPlaying = false
        isPaused = false
        currentUtteranceText = ""
        highlightLocator = nil
        followLocator = nil
        synthesizer = nil
        appleEngine = nil
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

    static let rateRange: ClosedRange<Float> = 0.5...3.0

    private static func validatedRate(_ rate: Float) -> Float? {
        guard rate.isFinite else { return nil }
        return min(max(rate, rateRange.lowerBound), rateRange.upperBound)
    }

    private func activateAudioSession(then start: @escaping @MainActor @Sendable () -> Void) {
        playbackGeneration &+= 1
        let generation = playbackGeneration
        AudioSessionQueue.perform {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(
                    .playback,
                    mode: .spokenAudio,
                    policy: .longFormAudio,
                    options: [.allowAirPlay, .allowBluetoothA2DP]
                )
                try session.setActive(true)
            } catch {
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
            }
        } completion: { [weak self] failure in
            guard let self, self.playbackGeneration == generation else { return }
            if let failure {
                AppLogger.library.error("Ebook narration audio session failed: \(failure)")
            }
            start()
        }
    }

    private func cancelPendingStart() {
        playbackGeneration &+= 1
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
        speechError = nil
        userDefaults.set(choice.rawValue, forKey: Self.engineDefaultsKey)
        let normalizedLanguage = normalizedLanguageIdentifier(preferredLanguageIdentifier)
        if normalizedLanguage != preferredLanguageIdentifier {
            preferredLanguageIdentifier = normalizedLanguage
            persistPreferences()
        }
        prepareEngine(choice)
        rebuildPreservingPlayback()
    }

    private func prepareEngine(_ choice: EbookTTSEngineChoice) {
        let previous = Self.modelPreparationTask
        previous?.cancel()
        let task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, self?.engineChoice == choice else { return }
            if choice == .apple {
                await KokoroTTSRuntime.shared.unload()
            }
        }
        Self.modelPreparationTask = task
        enginePreparationTask = task
    }

    private func isModelReady(for choice: EbookTTSEngineChoice) -> Bool {
        switch choice {
        case .apple:
            true
        case .kokoro:
            kokoroDownloadState == .ready && KokoroTTSRuntime.isSupportedOnCurrentOS
        }
    }

    private func rebuildPreservingPlayback() {
        guard publication != nil else { return }
        rebuildSynthesizer(
            resumeFrom: pendingStartLocator ?? highlightLocator,
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

        cancelPendingStart()
        needsInitialStart = false
        pendingStartLocator = nil
        synthesizer?.delegate = nil
        synthesizer?.stop()
        paragraphPrewarmTask?.cancel()
        prewarmedUtterance = nil
        let config = makeConfiguration()
        speechError = nil
        switch engineChoice {
        case .apple:
            kokoroEngine = nil
            let engine = AnchoredAVTTSEngine(rate: rate, anchor: startAnchor)
            appleEngine = engine
            let prepared = PreparedTTSEngine(engine: engine, preparation: enginePreparationTask)
            synthesizer = PublicationSpeechSynthesizer(
                publication: publication,
                config: config,
                engineFactory: { @Sendable in prepared },
                tokenizerFactory: Self.paragraphTokenizerFactory,
                delegate: self
            )
        case .kokoro:
            appleEngine = nil
            let engine = KokoroTTSEngine(voice: kokoroVoice, rate: rate, startAnchor: startAnchor)
            kokoroEngine = engine
            let prepared = PreparedTTSEngine(engine: engine, preparation: enginePreparationTask)
            synthesizer = PublicationSpeechSynthesizer(
                publication: publication,
                config: config,
                engineFactory: { @Sendable in prepared },
                tokenizerFactory: Self.paragraphTokenizerFactory,
                delegate: self
            )
        }

        guard shouldResume else { return }
        if shouldPauseAfterResume {
            needsInitialStart = true
            pendingStartLocator = locator
            isPlaying = false
            isPaused = true
        } else {
            startSpeaking(from: locator)
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
        guard engineChoice == .kokoro, let publication else { return }

        let kokoroVoice = self.kokoroVoice
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
                        guard !Task.isCancelled else { return }
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
                            guard code == "en" else { continue }
                            _ = try await KokoroTTSRuntime.shared.synthesize(
                                text: text,
                                voice: kokoroVoice,
                                speed: speed
                            )
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
    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        stateDidChange state: PublicationSpeechSynthesizer.State
    ) {
        guard synthesizer === self.synthesizer else { return }
        switch state {
        case .stopped:
            guard !needsInitialStart || !isPaused else { return }
            needsInitialStart = false
            pendingStartLocator = nil
            isPlaying = false
            isPaused = false
            currentUtteranceText = ""
            highlightLocator = nil
            followLocator = nil
            paragraphPrewarmTask?.cancel()
            prewarmedUtterance = nil
            NowPlayingCoordinator.shared.resignIfActive(self)
            NowPlayingCoordinator.shared.clearNowPlaying(if: self)
            endLiveActivity()
        case .paused(let utterance):
            isPlaying = false
            isPaused = true
            currentUtteranceText = utterance.text
            followLocator = nil
            updateNowPlayingInfo()
            updateLiveActivity()
        case .playing(let utterance, let range):
            // Readium can finish loading a cancelled start after the user has paused.
            guard !needsInitialStart || !isPaused else {
                synthesizer.pause()
                return
            }
            isPlaying = true
            isPaused = false
            currentUtteranceText = utterance.text
            if let range {
                needsInitialStart = false
                pendingStartLocator = nil
                highlightLocator = range
                followLocator = range
                if prewarmedUtterance != utterance {
                    prewarmedUtterance = utterance
                    prewarmParagraphs(after: utterance.locator)
                }
            } else {
                followLocator = nil
            }
            updateNowPlayingInfo()
            updateLiveActivity()
        }
    }

    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        utterance: PublicationSpeechSynthesizer.Utterance,
        didFailWithError error: PublicationSpeechSynthesizer.Error
    ) {
        guard synthesizer === self.synthesizer else { return }
        AppLogger.network.error("Error speaking: \(error)")
        if speechError == nil { speechError = error.localizedDescription }
        isPlaying = false
        isPaused = true
        paragraphPrewarmTask?.cancel()
        prewarmedUtterance = nil
        updateNowPlayingInfo()
        updateLiveActivity()
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
