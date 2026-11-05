#if os(iOS)
import Combine
import Foundation
@preconcurrency import ReadiumShared

/// Sentence read-along for an ordinary EPUB whose linked audiobook plays in the main player, which stays the
/// only transport. Manual browsing pauses page-following until resumed.
@MainActor
final class ReaderLinkedReadAlongController {
    enum Status: Equatable {
        case idle
        case following
        case browsing
        case preparing(Phase)
        case narrationElsewhere
        /// Preparation stopped; `remedy` says whether the reader can do anything about it.
        case blocked(PassageUnavailableReason)
        /// The window being narrated was analyzed without a usable result; only Try again analyzes it again.
        case unmatched(Unmatched)
        case passagesOff
        case unavailable(String)
    }

    enum Phase: Equatable {
        case starting
        case identifyingFiles
        case loadingEngine
        case waitingForPassage
        case matchingPassage
    }

    enum Unmatched: Equatable {
        case analysisFailed
        case noConfidentMatch
    }

    enum Remedy: Equatable {
        case resumeFollowing
        case play
        case download
        case storyAlignSettings
        case appSettings
        case retry
    }

    enum ListenResult: Equatable {
        case started
        case notSpoken
        case ambiguous
        case noMatch(String)
        /// A newer tap, task cancellation, reader dismissal or unlink made the request inert; nothing to report.
        case cancelled
    }

    private(set) var linkedAudiobook: Book?
    private(set) var isFollowRequested = false
    private(set) var status: Status = .idle
    private(set) var highlighted: PassageMapping?
    /// The word being narrated inside `highlighted`; nil between words, in silence, or without qualified word timings.
    private(set) var activeWord: PassageWordTiming?
    /// True while following turns the page, so the reader does not mistake that relocation for browsing.
    private(set) var isMovingPage = false
    var onChange: (() -> Void)?

    private let book: Book
    private let profileSession: ProfileSession
    private let playback: any PlaybackControlling
    private let adapter: () -> (any ReaderEngineAdapter)?
    private let openedFileURL: () -> URL?
    private let highlightColor: () -> ReadAloudHighlightColor
    private let startAudiobook: (Book) -> Void
    private let startAudiobookAtPosition: (Book, TimeInterval) -> Void
    private let recordReadingPosition: (PassageMapping) async -> Void
    private var loop: Task<Void, Never>?
    private var decorationWrite: Task<Void, Never>?
    private var wordWrite: Task<Void, Never>?
    /// The newest word decoration not yet written; intermediate words are dropped at fast playback.
    private var pendingWord: (locatorJSON: String?, session: UUID?, epoch: Int)?
    /// The stored mapping behind `highlighted`, whose words were validated before use.
    private var highlightedSource: PassageMapping?
    private var context: PassageAlignmentService.ReadAlongContext?
    private var contextChangeCount = -1
    private var contextEpoch = -1
    private var followedKey: PassageSentenceKey?
    private var lastTime: TimeInterval?
    private var lastPreparation: ContinuousClock.Instant?
    private var lastContextLoad: ContinuousClock.Instant?
    private var listenRequest: UUID?
    private var transportRequest: UUID?
    /// Identifies one follow request; work resuming from an await after stop or retirement no longer matches it.
    private var followSession: UUID?
    /// Whether the opened file is the prepared original, for the files and mapping epoch it was checked against.
    private var revision: (stamp: RevisionStamp, matches: Bool)?
    private var lastRevisionProbe: ContinuousClock.Instant?
    /// The browsed page's first original sentence and the last narrated sentence seen since.
    private var browsedPage: (top: PassageSentenceKey, startsOnPage: Bool, lastNarrated: PassageSentenceKey?)?
    /// The browsed page's first line until its sentence is identified; its text may not be prepared yet.
    private var browsedLine: (locator: Locator, triedAt: PassageSentenceKey?)?
    private var browseProbe: Task<Void, Never>?
    /// The first line of the page following last turned to, so turning back to it resumes following.
    private var followedPage: String?
    /// The link as last confirmed: the linker cache generation, and whether the library book itself carried it.
    private var linkGeneration: Int?
    private var linkInMemory = false
    private var lastLinkCheck: ContinuousClock.Instant?
    private var isRetired = false

    private struct RevisionStamp: Equatable {
        let epoch: Int
        let opened: FileStamp?
        let original: FileStamp?
    }

    private struct FileStamp: Equatable {
        let size: Int64
        let modified: Date

        init?(_ url: URL?) {
            // Attributes rather than cached URL resource values, so a replaced file is seen immediately.
            guard let path = url?.path, let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                let size = (attributes[.size] as? NSNumber)?.int64Value, let modified = attributes[.modificationDate] as? Date
            else { return nil }
            self.size = size
            self.modified = modified
        }
    }

    init(
        book: Book, profileSession: ProfileSession, playback: any PlaybackControlling,
        adapter: @escaping () -> (any ReaderEngineAdapter)?, openedFileURL: @escaping () -> URL?,
        highlightColor: @escaping () -> ReadAloudHighlightColor, startAudiobook: ((Book) -> Void)? = nil,
        startAudiobookAtPosition: ((Book, TimeInterval) -> Void)? = nil,
        recordReadingPosition: ((PassageMapping) async -> Void)? = nil
    ) {
        self.book = book
        self.profileSession = profileSession
        self.playback = playback
        self.adapter = adapter
        self.openedFileURL = openedFileURL
        self.highlightColor = highlightColor
        self.startAudiobook = startAudiobook ?? { [profileSession] in
            profileSession.engine.playback.resumeListening($0, presentPlayer: false)
        }
        self.startAudiobookAtPosition = startAudiobookAtPosition ?? { [profileSession] in
            profileSession.engine.playback.play($0, from: $1, presentPlayer: false)
        }
        self.recordReadingPosition = recordReadingPosition ?? { [profileSession, book] mapping in
            await profileSession.linkedProgress.recordEbookProgress(
                book: book, progression: mapping.totalProgression, locatorJSON: mapping.locatorJSON,
                observedAt: Date(), authoritative: true
            )
        }
    }

    var isAvailable: Bool { linkedAudiobook != nil }

    /// Reading saves never move the listening position while Listen Along has the linked audiobook in the player.
    var ownsListeningPosition: Bool {
        isFollowRequested && linkedAudiobook.map { playback.currentBook?.stableId == $0.stableId } == true
    }

    /// Transport for the linked audiobook while it is the loaded book; another book in the player is never touched.
    var hasLinkedNarrationLoaded: Bool {
        linkedAudiobook.map { playback.currentBook?.stableId == $0.stableId && playback.snapshot.isLoaded } == true
    }

    /// Called just before Listen Along starts the linked audiobook, so Read Aloud stops first.
    var onNarrationWillStart: (() -> Void)?
    private weak var tts: EbookTTSService?
    private var ttsStarts: AnyCancellable?

    /// One narration at a time: any TTS start, including from the lock screen, yields; a linked start stops TTS.
    func coordinate(with tts: EbookTTSService) {
        self.tts = tts
        ttsStarts = tts.$isPlaying.removeDuplicates().filter { $0 }
            .sink { [weak self] _ in self?.yieldNarration() }
    }

    private func narrationWillStart() {
        if let tts, tts.isPlaying || tts.isPaused { tts.stop() }
        onNarrationWillStart?()
    }

    /// Checked before every command: the link may have changed since the last tick.
    private func ownsLoadedNarration() async -> Bool {
        guard !isRetired, !Task.isCancelled, await linkStillHolds(), !isRetired, !Task.isCancelled else { return false }
        return hasLinkedNarrationLoaded
    }

    func skipNarration(by seconds: TimeInterval) async {
        guard await ownsLoadedNarration() else { return }
        if seconds < 0 { playback.skipBackward(seconds: -seconds) } else { playback.skipForward(seconds: seconds) }
    }

    func seekNarration(to time: TimeInterval) async {
        guard await ownsLoadedNarration() else { return }
        playback.seek(to: time)
    }

    func setNarrationRate(_ rate: Double) async {
        guard await ownsLoadedNarration() else { return }
        playback.setPlaybackRate(rate)
    }

    func toggleNarrationPlayback() async {
        if hasLinkedNarrationLoaded, playback.isPlaying {
            guard await ownsLoadedNarration() else { return }
            playback.pause()
        } else {
            await resumeLinkedAudiobook()
        }
    }

    /// Like Stop in Read Aloud: pauses the linked audiobook, never another book, then ends following.
    func stopListenAlong() async {
        if await ownsLoadedNarration(), playback.isPlaying { playback.pause() }
        stopFollowing()
    }

    /// Another narration mode is starting in this reader: the linked audiobook pauses and following ends.
    func yieldNarration() {
        guard !isRetired, isLinkedInMemory else { return }
        if hasLinkedNarrationLoaded, playback.isPlaying { playback.pause() }
        if isFollowRequested { stopFollowing() }
    }

    /// The synchronous part of `linkStillHolds`: false once the library book's own link changed.
    private var isLinkedInMemory: Bool {
        guard let linkedAudiobook else { return false }
        if let field = currentBook.linkedAudiobookStableId { return field == linkedAudiobook.stableId }
        return !linkInMemory
    }

    /// Available for every linked ordinary EPUB; missing downloads or engines are reported once following starts.
    func prepare() async {
        let generation = profileSession.playback.linker.cacheGeneration
        guard book.mediaType == .ebook, !book.hasEPUB3MediaOverlay, book.readAloudSourceStableId == nil,
            let audiobook = await profileSession.playback.linker.linkedAudiobookAsync(for: book),
            !isRetired
        else { return }
        linkedAudiobook = audiobook
        linkGeneration = generation
        linkInMemory = currentBook.linkedAudiobookStableId == audiobook.stableId
        onChange?()
    }

    private var currentBook: Book {
        profileSession.appState.libraryCache.bookInMemory(uniqueId: book.uniqueId) ?? book
    }

    /// An integer compare per tick; the link is looked up only after the linker cache changed, or once a second for a
    /// link stored only in the database. Unlink clears the library book's field first, so that is trusted over the
    /// database row, which is removed later.
    private func linkStillHolds() async -> Bool {
        guard let audiobook = linkedAudiobook else { return false }
        let linker = profileSession.playback.linker
        let generation = linker.cacheGeneration
        let due = !linkInMemory && lastLinkCheck.map { ContinuousClock.now - $0 >= .seconds(1) } ?? true
        guard generation != linkGeneration || due else { return true }
        lastLinkCheck = .now
        let linkedId: String?
        if let field = currentBook.linkedAudiobookStableId {
            linkedId = field
        } else if linkInMemory {
            linkedId = nil
        } else {
            linkedId = await linker.linkedAudiobookAsync(for: currentBook)?.stableId
        }
        guard !isRetired else { return false }
        linkGeneration = generation
        guard linkedId == audiobook.stableId else {
            let replacement = linkedId == nil ? nil : await linker.linkedAudiobookAsync(for: currentBook)
            guard !isRetired else { return false }
            endFollowing()
            listenRequest = nil
            transportRequest = nil
            linkedAudiobook = replacement
            linkInMemory = replacement.map { currentBook.linkedAudiobookStableId == $0.stableId } ?? linkInMemory
            setStatus(.idle)
            onChange?()
            return false
        }
        return true
    }

    /// The reader's audio button: pauses or resumes the loaded linked audiobook in place, otherwise starts it at the
    /// reading position. Only an explicit tap calls this; following never starts or moves playback.
    func toggleListening(audiobook: Book, readingLocatorJSON: String?, chapterIndex: Int?) async {
        guard !isRetired else { return }
        let request = UUID()
        transportRequest = request
        func isCurrent() -> Bool { transportRequest == request && !isRetired }
        guard await isStillLinked(audiobook), isCurrent(), !Task.isCancelled else { return }
        // A mini player restored at launch names the audiobook but has not loaded it yet.
        if playback.currentBook?.stableId == audiobook.stableId, playback.snapshot.isLoaded {
            if !playback.isPlaying { narrationWillStart() }
            playback.togglePlay()
            return
        }
        let target = await profileSession.playback.linker.audiobookTime(
            forReadingLocator: readingLocatorJSON, chapterIndex: chapterIndex, ebook: book, audiobook: audiobook
        )
        guard isCurrent(), !Task.isCancelled, await isStillLinked(audiobook), isCurrent(), !Task.isCancelled else { return }
        narrationWillStart()
        profileSession.engine.playback.play(audiobook, presentPlayer: false)
        for _ in 0..<20 {
            let snapshot = playback.snapshot
            if snapshot.currentBook?.stableId == audiobook.stableId, snapshot.isLoaded, !snapshot.isLoading { break }
            try? await Task.sleep(for: .milliseconds(150))
            guard isCurrent(), !Task.isCancelled else { return }
        }
        guard playback.currentBook?.stableId == audiobook.stableId else { return }
        if let target { playback.seek(to: target) }
        if !playback.isPlaying { playback.play() }
    }

    /// Resumes from the audiobook's own position; unlike the listen-along button it never uses the reading position.
    func resumeLinkedAudiobook() async {
        guard linkedAudiobook != nil, !isRetired, await linkStillHolds(), let audiobook = linkedAudiobook, !isRetired,
            !Task.isCancelled
        else { return }
        transportRequest = nil
        if playback.currentBook?.stableId == audiobook.stableId, playback.snapshot.isLoaded {
            guard !playback.isPlaying else { return }
            narrationWillStart()
            playback.play()
        } else {
            narrationWillStart()
            startAudiobook(audiobook)
        }
    }

    var remedy: Remedy? { Self.remedy(for: status, needsAudiobookDownload: needsAudiobookDownload) }

    static func remedy(for status: Status, needsAudiobookDownload: Bool) -> Remedy? {
        switch status {
        case .browsing: .resumeFollowing
        case .narrationElsewhere: .play
        case .unmatched: .retry
        case .passagesOff: .storyAlignSettings
        case .blocked(let reason):
            switch reason {
            case .missingMedia: needsAudiobookDownload ? .download : nil
            case .generationDisabled, .modelDownloadRequired, .lowStorage: .storyAlignSettings
            // Speech Recognition can only be re-allowed in the system Settings app.
            case .permissionDenied: .appSettings
            case .preparationFailed: .retry
            // Permanent limits have no corrective route; transient pauses resume on their own.
            case .unsupportedSystem, .unsupportedHardware, .unsupportedLanguage, .unsupportedFormat,
                .busy, .pausedForPower, .pausedForTemperature, .backgroundUnavailable:
                nil
            }
        case .idle, .following, .preparing, .unavailable: nil
        }
    }

    var needsAudiobookDownload: Bool {
        guard let linkedAudiobook else { return false }
        return !profileSession.downloads.hasCompleteAudio(for: linkedAudiobook)
    }

    func downloadLinkedAudiobook() {
        guard let audiobook = linkedAudiobook, !isRetired else { return }
        let downloads = profileSession.downloads
        Task { await downloads.download(book: audiobook) }
    }

    /// Prepares the narrated passage again, including windows that failed or found no confident match.
    func retryPreparation() {
        guard isFollowRequested, !isRetired, let audiobook = linkedAudiobook else { return }
        let snapshot = playback.snapshot
        guard snapshot.currentBook?.stableId == audiobook.stableId else { return }
        lastTime = snapshot.position
        lastPreparation = .now
        setStatus(.preparing(.starting))
        profileSession.passageAlignment.prepare(ebook: book, audiobook: audiobook, around: snapshot.position, reason: .playback, retrying: true)
    }

    func startFollowing() {
        guard linkedAudiobook != nil, !isFollowRequested, !isRetired else { return }
        isFollowRequested = true
        followSession = UUID()
        followedKey = nil
        setStatus(.following)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: self?.tickInterval ?? .milliseconds(250))
            }
        }
    }

    func stopFollowing() {
        endFollowing()
        setStatus(.idle)
    }

    /// Reader dismissal or profile retirement: pending Listen from here requests become inert and following ends.
    func retire() {
        isRetired = true
        listenRequest = nil
        endFollowing()
    }

    /// A renderer navigation already issued may still finish; no new highlight or page turn starts afterwards.
    private func endFollowing() {
        isFollowRequested = false
        followSession = nil
        browseProbe?.cancel()
        browsedPage = nil
        browsedLine = nil
        followedPage = nil
        loop?.cancel()
        loop = nil
        context = nil
        clearDecoration()
    }

    /// Called only for relocations the reader attributes to the user; following's own page turns are not reported.
    /// Pages are identified by original text: Readium and Foliate report different progressions for the same page.
    func userDidNavigate() {
        guard isFollowRequested else { return }
        if status != .browsing { setStatus(.browsing) }
        let session = followSession
        browsedPage = nil
        browsedLine = nil
        browseProbe?.cancel()
        browseProbe = Task { [weak self, adapter] in
            guard let locator = await adapter()?.ttsLocator(at: nil), let self, !Task.isCancelled,
                followSession == session, status == .browsing
            else { return }
            if let followedPage, followedPage == Self.pageIdentity(locator) {
                resumeFollowing()
                return
            }
            browsedLine = (locator, highlighted?.key)
            await identifyBrowsedPage(session: session)
        }
    }

    private func identifyBrowsedPage(session: UUID?) async {
        guard let line = browsedLine, let quote = line.locator.text.highlight, let audiobook = linkedAudiobook else { return }
        let resolution = await profileSession.passageAlignment.textResolution(
            ebook: book, audiobook: audiobook, href: line.locator.href.string, quote: quote,
            chapterProgression: line.locator.locations.progression
        )
        guard followSession == session, status == .browsing, browsedPage == nil,
            browsedLine.map({ Self.pageIdentity($0.locator) == Self.pageIdentity(line.locator) }) == true
        else { return }
        let top: (key: PassageSentenceKey, text: String)? = switch resolution {
        case .matched(let mapping): (mapping.key, mapping.text)
        case .notSpoken(let sentence): (sentence.key, sentence.text)
        case .unprepared(let sentence): sentence.map { ($0.key, $0.text) }
        case .ambiguous: nil
        }
        guard let top else { return }
        // A sentence carried over from the previous page is only partly on this one.
        let opening = String(PassageMappingSet.normalized(quote).prefix(16))
        let startsOnPage = !opening.isEmpty && PassageMappingSet.normalized(top.text).hasPrefix(opening)
        browsedPage = (top.key, startsOnPage, highlighted?.key)
        browsedLine = nil
    }

    /// Only a crossing into the page counts; a first mapping already past its top proves nothing.
    private func narrationReachedBrowsedPage(_ key: PassageSentenceKey) -> Bool {
        guard let page = browsedPage, page.lastNarrated != key else { return false }
        defer { browsedPage?.lastNarrated = key }
        guard let previous = page.lastNarrated else { return false }
        // A carried-over top sentence belongs to the previous page; the page begins with the sentence after it.
        if page.startsOnPage { return previous < page.top && !(key < page.top) }
        return !(page.top < previous) && page.top < key
    }

    private static func pageIdentity(_ locator: Locator) -> String {
        "\(locator.href.string)\u{1F}\(locator.text.highlight ?? "")"
    }

    func resumeFollowing() {
        guard isFollowRequested else { return }
        browseProbe?.cancel()
        browsedPage = nil
        browsedLine = nil
        followedKey = nil
        setStatus(.following)
    }

    /// Reading→listening at the tapped or first visible sentence. Text that is not narrated or not confidently matched
    /// never moves playback or either saved position.
    func listenFromHere(at point: CGPoint? = nil) async -> ListenResult {
        let request = UUID()
        listenRequest = request
        func isCurrent() -> Bool { listenRequest == request && !isRetired && !Task.isCancelled }
        guard let audiobook = linkedAudiobook, let adapter = adapter() else { return .noMatch("Enve could not read the visible text.") }
        let locator = await adapter.ttsLocator(at: point)
        guard isCurrent() else { return .cancelled }
        guard let locator, let quote = locator.text.highlight, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noMatch("Enve could not read the visible text.")
        }
        let passages = profileSession.passageAlignment
        let progression = locator.locations.totalProgression ?? book.canonicalEbookProgress
        let estimate = await profileSession.linkedProgress.estimatedAudioTime(forEbook: book, progression: progression) ?? 0
        guard isCurrent() else { return .cancelled }
        let resolution = await passages.findListeningPosition(
            ebook: book, audiobook: audiobook, href: locator.href.string, quote: quote,
            chapterProgression: locator.locations.progression, estimatedBookTime: estimate
        )
        guard isCurrent() else { return .cancelled }
        switch resolution {
        case .notSpoken:
            return .notSpoken
        case .ambiguous:
            return .ambiguous
        case .unprepared:
            if case .failure(let reason) = passages.capability(ebook: book, audiobook: audiobook) {
                return .noMatch(reason.message)
            }
            return .noMatch("No confident match was found nearby. Playback and both positions are unchanged.")
        case .matched(let mapping):
            guard let time = passages.bookTime(of: mapping, audiobook: audiobook) else {
                return .noMatch("The audiobook files are not available on this device.")
            }
            func ownsLink() async -> Bool {
                let isLinked = await isStillLinked(audiobook)
                guard isCurrent() else { return false }
                guard isLinked, linkedAudiobook?.stableId == audiobook.stableId else {
                    if linkedAudiobook?.stableId == audiobook.stableId { linkedAudiobook = nil }
                    stopFollowing()
                    return false
                }
                return true
            }
            guard await ownsLink() else { return .cancelled }
            let snapshot = playback.snapshot
            if snapshot.currentBook?.stableId == audiobook.stableId, snapshot.isLoaded, !snapshot.isLoading {
                narrationWillStart()
                playback.seek(to: time)
                if !playback.isPlaying { playback.play() }
            } else {
                await recordReadingPosition(mapping)
                // The link may have changed while the reading position was recorded.
                guard isCurrent(), await ownsLink() else { return .cancelled }
                narrationWillStart()
                startAudiobookAtPosition(audiobook, time)
            }
            if !isFollowRequested { startFollowing() } else { resumeFollowing() }
            return .started
        }
    }

    /// Unlinking clears the reader's in-memory link; the snapshot this controller opened with may still carry it.
    private func isStillLinked(_ audiobook: Book) async -> Bool {
        // Same order as `linkStillHolds`: the library book's field, then the database only for a database-only link.
        if let field = currentBook.linkedAudiobookStableId { return field == audiobook.stableId }
        if linkInMemory { return false }
        return await profileSession.playback.linker.linkedAudiobookAsync(for: currentBook)?.stableId == audiobook.stableId
    }

    private func tick() async {
        guard isFollowRequested, let session = followSession, let audiobook = linkedAudiobook else { return }
        // Before any status: an unlinked pair must not keep offering Play while another book or nothing is loaded.
        guard await linkStillHolds(), followSession == session else { return }
        let snapshot = playback.snapshot
        guard snapshot.currentBook?.stableId == audiobook.stableId else {
            clearDecoration()
            if status != .browsing { setStatus(.narrationElsewhere) }
            return
        }
        let passages = profileSession.passageAlignment
        guard passages.cachedMappingsEnabled else {
            context = nil
            clearDecoration()
            if status != .browsing { setStatus(.passagesOff) }
            return
        }
        // Without the downloaded original nothing prepared can be shown; capability reports what is missing.
        guard await checkRevision(audiobook: audiobook), followSession == session else {
            guard followSession == session else { return }
            context = nil
            clearDecoration()
            if status != .browsing { setStatus(preparationStatus(audiobook: audiobook, window: nil)) }
            return
        }
        guard revision?.matches != false else {
            clearDecoration()
            setStatus(.unavailable("This copy of the ebook differs from the downloaded original, so Read Along can't follow it."))
            return
        }
        // Re-verified each second: the cached media identity is file-stat checked, so a replaced or deleted audio
        // file drops the context until a new identity and its mappings exist.
        let reverify = lastContextLoad.map { ContinuousClock.now - $0 >= .seconds(1) } ?? true
        if reverify || contextChangeCount != passages.store.changeCount || contextEpoch != passages.mappingsEpoch {
            lastContextLoad = .now
            contextChangeCount = passages.store.changeCount
            contextEpoch = passages.mappingsEpoch
            let loaded = await passages.readAlongContext(ebook: book, audiobook: audiobook)
            guard followSession == session else { return }
            context = loaded
        }
        let live = liveTime(snapshot)
        let time = live ?? snapshot.position
        let jumped = lastTime.map { time < $0 - 2 || time > $0 + 20 } ?? true
        lastTime = time
        let setupResolved = isSetupResolved(audiobook: audiobook)
        if snapshot.isPlaying || jumped || setupResolved {
            requestPreparation(audiobook: audiobook, time: time, seek: jumped || setupResolved)
        }
        guard let context else {
            clearDecoration()
            if status != .browsing { setStatus(preparationStatus(audiobook: audiobook, window: nil)) }
            return
        }
        switch context.resolve(bookTime: time) {
        case .matched(let mapping):
            if status != .following, status != .browsing { setStatus(.following) }
            // A page turned before its text was prepared is identified again once per narrated sentence.
            if status == .browsing, browsedPage == nil, let line = browsedLine, line.triedAt != mapping.key {
                browsedLine?.triedAt = mapping.key
                await identifyBrowsedPage(session: session)
                guard followSession == session else { return }
            }
            // Narration caught up with a page the reader turned ahead to: follow on from there.
            if status == .browsing, narrationReachedBrowsedPage(mapping.key) {
                resumeFollowing()
            }
            await show(mapping)
            guard followSession == session else { return }
            // Word timings need the live clock; the published position moves once a second.
            let trackTime = live.flatMap { live in context.bookTime(of: mapping).map { live - ($0 - mapping.start) } }
            setWord(trackTime.flatMap { highlighted?.word(at: $0) })
        case .pause(let mapping, _):
            if status != .following, status != .browsing { setStatus(.following) }
            await show(mapping)
            setWord(nil)
        case .gap:
            // Prepared, but nothing in the text is being narrated here.
            clearDecoration()
            if status != .following, status != .browsing { setStatus(.following) }
        case .unprepared:
            clearDecoration()
            if status != .browsing { setStatus(preparationStatus(audiobook: audiobook, window: context.window(at: time), in: context)) }
        }
    }

    private func preparationStatus(audiobook: Book, window: PassageWindowRef?, in context: PassageAlignmentService.ReadAlongContext? = nil) -> Status {
        let passages = profileSession.passageAlignment
        let pair = passages.status(ebook: book, audiobook: audiobook)
        if pair.isRetrying { return .preparing(.starting) }
        if let window {
            if pair.analyzing == window { return .preparing(.matchingPassage) }
            if passages.isPending(window, ebook: book, audiobook: audiobook) { return .preparing(.waitingForPassage) }
            if pair.failedWindows.contains(window) { return .unmatched(.analysisFailed) }
            if context?.wasRejected(window) == true { return .unmatched(.noConfidentMatch) }
        }
        switch pair.activity {
        case .identifying:
            return .preparing(.identifyingFiles)
        case .loadingEngine:
            return .preparing(.loadingEngine)
        case .paused(let reason):
            return .blocked(reason)
        case .preparing:
            return .preparing(.waitingForPassage)
        case .idle:
            if case .failure(let reason) = passages.capability(ebook: book, audiobook: audiobook) { return .blocked(reason) }
            return .preparing(.starting)
        }
    }

    /// A pause that only the capability check reports (no model, no local files) clears once that check passes,
    /// for example after the model was downloaded in StoryAlign settings.
    private func isSetupResolved(audiobook: Book) -> Bool {
        let passages = profileSession.passageAlignment
        guard case .paused(let reason) = passages.status(ebook: book, audiobook: audiobook).activity,
            [.modelDownloadRequired, .missingMedia].contains(reason),
            case .success = passages.capability(ebook: book, audiobook: audiobook)
        else { return false }
        return true
    }

    private func requestPreparation(audiobook: Book, time: TimeInterval, seek: Bool) {
        let now = ContinuousClock.now
        if !seek, let lastPreparation, now - lastPreparation < .seconds(5) { return }
        lastPreparation = now
        profileSession.passageAlignment.prepare(ebook: book, audiobook: audiobook, around: time, reason: seek ? .playback : .lookAhead)
    }

    private var tickInterval: Duration {
        highlighted?.words != nil && playback.isPlaying ? .milliseconds(50) : .milliseconds(250)
    }

    /// The live player clock when it agrees with the published position.
    private func liveTime(_ snapshot: PlaybackSnapshot) -> TimeInterval? {
        guard let live = playback.livePosition else { return nil }
        return abs(live - snapshot.position) <= 2 + 1.5 * max(1, snapshot.playbackSpeed) ? live : nil
    }

    /// At most once a second: file stats, and a digest only when a file or the mapping epoch changed.
    /// False when the original EPUB or audio is not local.
    private func checkRevision(audiobook: Book) async -> Bool {
        let passages = profileSession.passageAlignment
        if let lastRevisionProbe, ContinuousClock.now - lastRevisionProbe < .seconds(1), revision?.stamp.epoch == passages.mappingsEpoch {
            return revision != nil
        }
        lastRevisionProbe = .now
        guard let fileURL = openedFileURL(), let original = passages.originalEPUBURL(ebook: book, audiobook: audiobook) else {
            revision = nil
            return false
        }
        let stamp = RevisionStamp(epoch: passages.mappingsEpoch, opened: FileStamp(fileURL), original: FileStamp(original))
        guard stamp != revision?.stamp else { return true }
        let matches = await passages.isPreparedReadingRevision(ebook: book, audiobook: audiobook, openedFileURL: fileURL)
        revision = (stamp, matches)
        return true
    }

    private func show(_ mapping: PassageMapping) async {
        if highlightedSource != mapping {
            if highlighted?.key != mapping.key { decorate(mapping.locatorJSON) }
            var checked = mapping
            checked.words = mapping.words.flatMap { PassageWordTiming.validated($0, in: mapping.text, start: mapping.start, end: mapping.end) }
            highlightedSource = mapping
            highlighted = checked
            setWord(nil)
        }
        guard status == .following, followedKey != mapping.key, isVisible(since: contextEpoch), let adapter = adapter() else { return }
        followedKey = mapping.key
        isMovingPage = true
        await adapter.followReadAlong(locatorJSON: mapping.locatorJSON)
        isMovingPage = false
        let page = await adapter.ttsLocator(at: nil)
        if status == .following, followedKey == mapping.key { followedPage = page.map(Self.pageIdentity) }
    }

    private func clearDecoration() {
        guard highlighted != nil else { return }
        setWord(nil)
        highlighted = nil
        highlightedSource = nil
        decorate(nil)
    }

    private func setWord(_ word: PassageWordTiming?) {
        guard word != activeWord else { return }
        activeWord = word
        writeWord(word.flatMap { highlighted?.locatorJSON(for: $0) })
    }

    /// One word write in flight; while it runs only the newest request is kept. Clears always run.
    private func writeWord(_ locatorJSON: String?) {
        pendingWord = (locatorJSON, followSession, contextEpoch)
        guard wordWrite == nil else { return }
        let color = highlightColor()
        wordWrite = Task { [weak self, adapter] in
            while let next = self?.pendingWord {
                self?.pendingWord = nil
                guard next.locatorJSON == nil
                    || (next.session != nil && self?.followSession == next.session && self?.isVisible(since: next.epoch) == true)
                else { continue }
                await adapter()?.applyReadAlongWordDecoration(locatorJSON: next.locatorJSON, color: color)
            }
            self?.wordWrite = nil
        }
    }

    /// Ordered writes; a queued highlight is dropped once its follow request ended or its passages were switched
    /// off or removed. Clears always run.
    private func decorate(_ locatorJSON: String?) {
        let previous = decorationWrite
        let color = highlightColor()
        let session = followSession
        let epoch = contextEpoch
        decorationWrite = Task { [weak self, adapter] in
            await previous?.value
            guard locatorJSON == nil || (session != nil && self?.followSession == session && self?.isVisible(since: epoch) == true) else { return }
            await adapter()?.applyReadAlongDecoration(locatorJSON: locatorJSON, color: color)
        }
    }

    private func isVisible(since epoch: Int) -> Bool {
        let passages = profileSession.passageAlignment
        return passages.cachedMappingsEnabled && passages.mappingsEpoch == epoch
    }

    private func setStatus(_ new: Status) {
        guard status != new else { return }
        status = new
        onChange?()
    }
}
#endif
