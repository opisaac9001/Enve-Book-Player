import Combine
import Foundation
import SwiftUI

#if targetEnvironment(macCatalyst)
import UIKit
#endif

extension Notification.Name {
    static let enveCatalystSelectTab = Notification.Name("enve.catalyst.selectTab")
    static let enveCatalystShowSettings = Notification.Name("enve.catalyst.showSettings")
}

struct AppRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(EnveEngine.self) private var engine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: HearthTab = .hearth
    @State private var tabResetTokens: [HearthTab: UUID] = Dictionary(
        uniqueKeysWithValues: HearthTab.allCases.map { ($0, UUID()) }
    )
    @AppStorage("hearth.mode") private var modeRaw = Hearth.Mode.system.rawValue
    @State private var prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()

    @State private var debugDetailBook: Book?
    @State private var debugPodcastShow: Book?
    @State private var debugLibrarianBook: Book?
    @State private var debugSettingsPresented = false
    @State private var debugAddSourcePresented = false
    private struct DebugRoute: Identifiable { let id: String }
    @State private var debugScreenRoute: DebugRoute?
    @State private var debugWorkHubKey: DebugRoute?
    @State private var debugCardRequest: QuoteCardRequest?
    @State private var tourPresented = false
    @State private var reauthConnection: ServerConnection?
    @State private var showOrphanedMatcher = false

    init() {
        let preferences = LibraryDisplayPreferencesStore.shared.loadPreferences()
        _prefs = State(initialValue: preferences)
        _tab = State(
            initialValue: HearthTab(rawValue: preferences.preferredStartTab.rawValue) ?? .hearth
        )
    }

    var body: some View {
        @Bindable var presentation = appState.presentation

        ZStack {
            if appState.isBootstrapComplete {
                shell
                    .transition(.opacity)
            } else {
                SplashGlow()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: appState.isBootstrapComplete)
        .overlay(alignment: .top) {
            ReaderOpenPreparationBanner()
                .safeAreaPadding(.top, 8)
                .zIndex(100)
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.25),
            value: engine.readerOpen.activity
        )
        .fullScreenCover(isPresented: $presentation.isPlayerPresented) {
            PlayerScreen()
                .enveEnvironment()
        }
        .fullScreenCover(item: $presentation.selectedEbookForDetail) { book in
            ReaderScreen(book: book, providerResolver: appState.providerConnections)
                .id(book.stableId)
                .enveEnvironment()
        }
        .fullScreenCover(item: $debugDetailBook) { book in
            NavigationStack { BookDetailScreen(book: book) }
                .enveEnvironment()
        }
        .fullScreenCover(item: $debugPodcastShow) { show in
            NavigationStack { PodcastShowScreen(show: show) }
                .enveEnvironment()
        }
        .fullScreenCover(isPresented: $debugSettingsPresented) {
            NavigationStack { SettingsScreen() }
                .enveEnvironment()
        }
        .fullScreenCover(isPresented: $debugAddSourcePresented) {
            NavigationStack { SourcesQuickConnectScreen() }
                .enveEnvironment()
        }
        .fullScreenCover(isPresented: $tourPresented) {
            HearthTour()
                .enveEnvironment()
        }
        .fullScreenCover(item: $debugScreenRoute) { route in
            NavigationStack { debugRoutedScreen(route.id) }
                .enveEnvironment()
        }
        .fullScreenCover(item: $debugWorkHubKey) { route in
            NavigationStack { WorkHubScreen(workKey: route.id) }
                .enveEnvironment()
        }
        .fullScreenCover(item: $debugLibrarianBook) { book in
            LibrarianChatScreen(book: book)
                .enveEnvironment()
        }
        .sheet(item: $debugCardRequest) { request in
            QuoteCardSheet(quote: request.text, book: request.book, attribution: request.attribution)
                .enveEnvironment()
                .presentationDetents([.large])
        }
        .sheet(item: $reauthConnection) { connection in
            NavigationStack { SourceDetailScreen(connectionId: connection.id) }
                .enveEnvironment()
        }
        .sheet(isPresented: $showOrphanedMatcher) {
            NavigationStack { OrphanedBookMatcherScreen() }
                .enveEnvironment()
        }
        .alert(item: $presentation.userFacingError) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .alert(item: $presentation.zipFileAlertBook) { book in
            Alert(
                title: Text("Can't play this file"),
                message: Text(
                    "\"\(book.title)\" is a .zip archive Enve can't play directly. Unzip it on your server, or download a supported format."
                ),
                dismissButton: .default(Text("OK"))
            )
        }
        .onChange(of: appState.isBootstrapComplete) { _, complete in
            if complete, !UserDefaults.standard.bool(forKey: "imagine.hasSeenTour"),
                Self.launchArgumentValue("imagineScreen") == nil
            {
                tourPresented = true
            }
        }
        .preferredColorScheme(Hearth.Mode(rawValue: modeRaw)?.preferredColorScheme)
        .hearthRoot()
        .task { await restoreLastPlayedIntoMantel() }
        .task { await handleDebugRoute() }
        .task { await observePreferenceChanges() }
        .onChange(of: appState.currentBook?.stableId) { _, newId in
            if let newId {
                PlayerStateStore.shared.saveLastPlayedBookId(newId)
            }
        }
        .onOpenURL { openEnveBookLink($0) }
        .onReceive(NotificationCenter.default.publisher(for: .enveCatalystSelectTab)) { notification in
            guard let rawValue = notification.object as? String,
                let destination = HearthTab(rawValue: rawValue)
            else { return }
            selectTab(destination)
        }
        .onReceive(NotificationCenter.default.publisher(for: .enveCatalystShowSettings)) { _ in
            debugSettingsPresented = true
        }
        .onAppear { configureCatalystWindow() }
    }

    private func configureCatalystWindow() {
        #if targetEnvironment(macCatalyst)
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        windowScene?.sizeRestrictions?.minimumSize = CGSize(width: 900, height: 640)
        #endif
    }

    private func openEnveBookLink(_ url: URL) {
        if let request = EnveBookLink.readerRequest(from: url),
            var book = appState.bookInMemory(stableId: request.bookID)
        {
            if let locator = request.locator, !locator.isEmpty {
                book.epubLocator = locator
            }
            engine.playback.openEbook(book)
        } else if let request = EnveBookLink.playerRequest(from: url),
            let book = appState.bookInMemory(stableId: request.bookID)
        {
            engine.playback.play(book)
            if let timestamp = request.timestamp {
                Task { @MainActor in
                    for _ in 0..<20 {
                        let snapshot = ActivePlayback.controller.snapshot
                        if snapshot.currentBook?.stableId == book.stableId,
                            !snapshot.isLoading
                        {
                            PlayerViewModel.shared.seek(to: timestamp)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
            }
        }
    }

    private func restoreLastPlayedIntoMantel() async {
        for _ in 0..<25 {
            if engine.playback.restoreLastPlayedIntoMantelIfAvailable() { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func observePreferenceChanges() async {
        for await _ in NotificationCenter.default.notifications(named: .preferencesDidChange).map({ _ in () }) {
            prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
        }
    }

    private func handleDebugRoute() async {
        #if DEBUG
        let route = Self.launchArgumentValue("imagineScreen")
        let openBook = Self.launchArgumentValue("imagineOpenBook")
        let fixtureFilename = Self.launchArgumentValue("imagineFixture")
        let seedCountArg = Int(Self.launchArgumentValue("imagineSeed") ?? "") ?? 0
        let teardownArg = Self.launchArgumentBool("imagineTeardownSynthetic")
        let refreshArg = Self.launchArgumentBool("imagineRefreshLibraries")
        Self.clearPersistedDebugRouteKeys()
        guard route != nil || (openBook?.isEmpty == false) || seedCountArg > 0 || teardownArg || refreshArg else { return }
        while !appState.isBootstrapComplete {
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .seconds(1.5))

        await connectDebugSource()

        if refreshArg {
            await engine.sources.refreshActiveConnectionLibraries()
        }

        if teardownArg {
            await SyntheticLibrarySeeder.shared.teardown()
            await engine.library.removeLocalEbookDebugImports(limit: 500)
        }

        if seedCountArg > 0 {
            await SyntheticLibrarySeeder.shared.seed(count: seedCountArg, scenario: .mixed) { _ in }
            NotificationCenter.default.post(name: .bookStoreDidChange, object: nil)
            tab = .library
        }

        switch route ?? "" {
        case "hearth":
            tab = .hearth
        case "browse":
            tab = .library
        case "library", "libraryfilters", "librarybatch", "librarybatchbar":
            tab = .library
        case "journal":
            tab = .journal
        case "settings":
            debugSettingsPresented = true
        case "addsource":
            debugAddSourcePresented = true
        case "player":
            if openBook?.isEmpty ?? true {
                var book = await engine.library.continueListeningBooks(limit: 1).first
                if book == nil {
                    book = await engine.library.firstBooks(mediaType: "audiobook", limit: 1).first
                }
                let playerBook = book ?? Self.makePlayerSmokeBook()
                appState.currentBook = playerBook
                appState.presentation.isPlayerPresented = true
            }
        case "reader", "readerchrome", "ttsvoices", "ttsdownload", "ttsplayback", "kokorodownload", "kokoroplayback":
            var ebook: Book?
            if let needle = openBook, !needle.isEmpty {
                ebook = await engine.library.firstBooks(mediaType: "ebook", limit: 500)
                    .first { $0.title.localizedCaseInsensitiveContains(needle) }
            }
            if ebook == nil, openBook?.isEmpty ?? true {
                ebook = await engine.library.continueReadingBooks(limit: 1).first
            }
            if ebook == nil, openBook?.isEmpty ?? true {
                ebook = await engine.library.downloadedEbooks(limit: 1).first
            }
            if ebook == nil, openBook?.isEmpty ?? true {
                ebook = await engine.library.firstBooks(mediaType: "ebook", limit: 1).first
            }
            if let ebook {
                engine.playback.presentReader(for: ebook)
            } else if route == "reader", let smokeBook = Self.makeReaderSmokeBook() {
                engine.playback.presentReader(for: smokeBook)
            }
        case "footnotefixture":
            if let fixtureFilename,
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            {
                let directURL = documents.appendingPathComponent(fixtureFilename)
                let importedURL =
                    documents
                    .appendingPathComponent("Ebooks/local", isDirectory: true)
                    .appendingPathComponent(fixtureFilename)
                let fileURL = FileManager.default.fileExists(atPath: directURL.path) ? directURL : importedURL
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let book = Book(
                        id: "debug-\(fixtureFilename)",
                        title: "Enve Footnote Fixture",
                        author: "Test Fixture",
                        source: .local,
                        filePath: fileURL.path,
                        mediaType: .ebook,
                        ebookFormat: EbookFormat.epub.rawValue,
                        ebookFileURL: fileURL,
                        libraryId: "debug"
                    )
                    engine.playback.presentReader(for: book)
                }
            }
        case "readaloudreader":
            var books = await engine.library.firstBooks(source: Book.BookSource.storyteller.rawValue, mediaType: "audiobook", limit: 500)
            if let needle = openBook, !needle.isEmpty {
                books = books.filter { $0.title.localizedCaseInsensitiveContains(needle) }
            }
            if let book = books.first(where: { $0.epub3Features?.hasMediaOverlay == true && $0.ebookFileURL != nil })
                ?? books.first(where: { $0.epub3Features?.hasMediaOverlay == true })
            {
                engine.playback.presentReader(for: book)
            }
        case "comicdetail":
            debugDetailBook = Book(
                id: "debug-comic-detail",
                title: "The Ember Archive",
                author: "Enve",
                mediaType: .ebook,
                ebookFormat: EbookFormat.cbz.rawValue,
                series: "The Ember Archive",
                seriesNumber: 7,
                providerId: UUID(),
                libraryId: "debug"
            )
        case "splitdetail":
            let tracks = [
                AudioTrack(
                    index: 0,
                    title: "Chapter 1 - The Worst Birthday",
                    filePath: "/tmp/Chapter 1 - The Worst Birthday.mp3",
                    duration: 900,
                    startOffset: 0
                ),
                AudioTrack(
                    index: 1,
                    title: "Chapter 2 - Dobby's Warning",
                    filePath: "/tmp/Chapter 2 - Dobby's Warning.mp3",
                    duration: 1_100,
                    startOffset: 900
                ),
            ]
            debugDetailBook = Book(
                id: "debug-split-detail",
                title: "Chapter Grouping Fixture",
                author: "Enve",
                duration: 2_000,
                chapters: [
                    Chapter(id: "debug-chapter-1", start: 0, end: 900, title: "Chapter 1 - The Worst Birthday"),
                    Chapter(id: "debug-chapter-2", start: 900, end: 2_000, title: "Chapter 2 - Dobby's Warning"),
                ],
                source: .local,
                filePath: tracks[0].filePath,
                audioTracks: tracks,
                providerId: UUID(),
                libraryId: "debug"
            )
        case "detail":
            if openBook?.isEmpty ?? true {
                var book = await engine.library.continueListeningBooks(limit: 1).first
                if book == nil {
                    book = await engine.library.recentBooks(limit: 1).first
                }
                debugDetailBook = book
            }
        case "librarian":
            var book = await engine.library.continueListeningBooks(limit: 1).first
            if book == nil {
                book = await engine.library.recentBooks(limit: 1).first
            }
            debugLibrarianBook = book
        case "quotecard":
            var book = await engine.library.recentBooks(limit: 1).first
            if book == nil { book = engine.playback.currentBook }
            if let book {
                debugCardRequest = QuoteCardRequest(
                    text: "We are all in the gutter, but some of us are looking at the stars.",
                    book: book,
                    attribution: "Act III"
                )
            }
        case "speedtest":
            await runPerBookSpeedSelfTest()
        case "queuetest":
            runPlaybackQueueSelfTest()
        case "queuee2e":
            await runPlaybackQueueEndToEndTest()
        case "levelingtest":
            runVolumeLevelingSelfTest()
        case "keepofflinetest":
            runKeepNextOfflineSelfTest()
        case "podcastqueuetest":
            runPodcastAutoQueueSelfTest()
        case "siriintenttest":
            await runSiriAudiobookIntentSelfTest()
        case "podcastshow":
            debugPodcastShow = PodcastsModel.shared.installDebugShow()
        case "queue":
            let books = await engine.library.firstBooks(mediaType: "audiobook", limit: 4)
            if let current = books.first {
                appState.currentBook = current
                engine.playback.queue.store.replace(
                    with: Array(books.dropFirst()),
                    origin: .playAll,
                    groupKey: "debug:queue-preview"
                )
                appState.presentation.isPlayerPresented = true
            }
        case "leveling":
            if let book = await engine.library.firstBooks(mediaType: "audiobook", limit: 1).first {
                appState.currentBook = book
                appState.presentation.isPlayerPresented = true
            }
        case "worktest":
            await runWorkGroupingSelfTest()
        case "dedupaudit":
            await runDedupAudit()
        case "chaptertest":
            await runChapterExtractionTest()
        case "grimmorye2e":
            await runGrimmoryE2ETest()
        case "storytellere2e":
            await runStorytellerE2ETest()
        case "storytellersmiltest":
            runStorytellerSMILSelfTest()
        case "storytellerposition":
            await StorytellerPositionProbe.run(
                fraction: Self.launchArgumentValue("imagineSeekFraction").flatMap(Double.init),
                titleNeedle: openBook,
                engine: engine,
                appState: appState
            )
        case "storytellerreadaloud":
            await StorytellerReadaloudE2E.run(
                serverURL: Self.launchArgumentValue("imagineSourceURL"),
                titleNeedle: openBook,
                engine: engine,
                appState: appState
            )
        case "workhub":
            let books = await engine.library.firstBooks(mediaTypes: ["audiobook", "ebook"], limitPerMediaType: 8000)
            if let top = WorkGrouping.group(books)
                .filter({ $0.isConsolidated })
                .max(by: { ($0.sourceCount + $0.editionCount) < ($1.sourceCount + $1.editionCount) })
            {
                debugWorkHubKey = DebugRoute(id: top.workKey)
            }
        case "suggestions":
            debugWorkHubKey = nil
            debugScreenRoute = DebugRoute(id: "suggestions")
        case "podcasts", "discover", "collections", "hardcover", "vocabulary", "insights", "completion", "storage", "libraryhealth", "metadatabatch", "tour":
            if let route { debugScreenRoute = DebugRoute(id: route) }
        default:
            break
        }

        if route != "readaloudreader", route != "storytellerreadaloud", route != "storytellerposition", let needle = openBook,
            !needle.isEmpty
        {
            var book: Book?
            if needle.hasPrefix("format:") {
                let ext = String(needle.dropFirst("format:".count)).lowercased()
                let ebooks = await engine.library.firstBooks(mediaType: "ebook", limit: 100)
                book = ebooks.first {
                    $0.ebookFormat?.lowercased() == ext || $0.ebookFileURL?.pathExtension.lowercased() == ext
                }
            } else if needle.hasPrefix("id:") {
                let id = String(needle.dropFirst("id:".count))
                func matchesID(_ candidate: Book) -> Bool {
                    candidate.id == id
                        || candidate.stableId == id
                        || candidate.uniqueId == id
                        || candidate.id.contains(id)
                        || candidate.stableId.contains(id)
                        || candidate.uniqueId.contains(id)
                }
                book = await engine.library.firstBooks(mediaType: "audiobook", limit: 8000)
                    .first(where: matchesID)
                if book == nil {
                    book = await engine.library.firstBooks(mediaType: "ebook", limit: 8000)
                        .first(where: matchesID)
                }
            } else if needle.hasPrefix("source:") {
                let pieces = needle.split(separator: ":", maxSplits: 2).map(String.init)
                if pieces.count == 3 {
                    let source = pieces[1]
                    let title = pieces[2]
                    let sourceBooks = await engine.library.firstBooks(
                        source: source,
                        mediaTypes: ["audiobook", "ebook"],
                        limitPerMediaType: 500
                    )
                    book =
                        sourceBooks
                        .first { $0.title.localizedCaseInsensitiveContains(title) }
                }
            } else {
                book = await engine.library.searchBooks(query: needle, limit: 5).first
            }
            if let book {
                if route == "detail" {
                    debugDetailBook = book
                } else {
                    engine.playback.openDebugRouteBook(book)
                }
            }
        }
        #endif
    }

    #if DEBUG
    private func connectDebugSource() async {
        guard let typeRaw = Self.launchArgumentValue("imagineSourceType"),
            let type = ProviderType(rawValue: typeRaw),
            let url = Self.launchArgumentValue("imagineSourceURL"),
            let username = Self.launchArgumentValue("imagineSourceUser"),
            let password = Self.launchArgumentValue("imagineSourcePassword")
        else { return }

        if appState.providerConnections.connections.contains(where: { $0.type == type && $0.url == url && !$0.isArchived }) {
            return
        }

        do {
            let delegate = engine.sources.makeLoginDelegate(for: type)
            let authed = try await delegate.authenticate(
                serverURL: url,
                username: username,
                password: password,
                customHeaders: nil
            )
            _ = try engine.sources.completeAuthenticatedConnection(authed)
            try? await Task.sleep(for: .seconds(5))
        } catch {
            try? "connect failed for \(typeRaw) \(url): \(error)".write(
                to: URL.documentsDirectory.appendingPathComponent("enve_connect.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func runStorytellerSMILSelfTest() {
        let results = StorytellerSMILFixtureRunner.run()
        let passed = results.filter(\.passed).count
        let lines = results.map { result in
            "[\(result.passed ? "PASS" : "FAIL")] \(result.name) | expected=\(result.expected) actual=\(result.actual)"
        }
        let report =
            ([
                "STORYTELLER SMIL - \(passed) pass, \(results.count - passed) fail",
                String(repeating: "-", count: 44),
            ] + lines).joined(separator: "\n")
        try? report.write(
            to: URL.documentsDirectory.appendingPathComponent("enve_storyteller_smil.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func runPerBookSpeedSelfTest() async {
        func write(_ s: String) {
            let url = URL.documentsDirectory.appendingPathComponent("enve_speedtest.txt")
            try? s.write(to: url, atomically: true, encoding: .utf8)
        }
        write("entered")
        let pm = PlaybackManager.shared
        let mem = PlaybackSpeedMemory.shared
        var books = await engine.library.continueListeningBooks(limit: 2)
        if books.count < 2 {
            books = await engine.library.recentBooks(limit: 12).filter { $0.mediaType == .audiobook }
        }
        guard books.count >= 2 else {
            write("FAIL: fewer than 2 audiobooks available (\(books.count))")
            return
        }
        let a = books[0]
        let b = books[1]
        let originalGlobal = pm.playbackSpeed
        mem.forget(stableId: a.stableId)
        mem.forget(stableId: b.stableId)

        pm.debugApplyPerBookSpeed(for: a)
        pm.setPlaybackSpeed(1.8)
        pm.debugApplyPerBookSpeed(for: b)
        pm.setPlaybackSpeed(1.3)
        pm.debugApplyPerBookSpeed(for: a)
        let reloadA = pm.playbackSpeed
        pm.debugApplyPerBookSpeed(for: b)
        let reloadB = pm.playbackSpeed

        let pass = abs(Double(reloadA) - 1.8) < 0.001 && abs(Double(reloadB) - 1.3) < 0.001
        write("reloadA=\(reloadA) (exp 1.8) reloadB=\(reloadB) (exp 1.3) => \(pass ? "PASS" : "FAIL")")

        pm.setPlaybackSpeed(originalGlobal)
        mem.forget(stableId: a.stableId)
        mem.forget(stableId: b.stableId)
    }

    private func runKeepNextOfflineSelfTest() {
        let providerID = UUID()

        func seriesBook(_ id: String, sequence: String, isFinished: Bool = false) -> Book {
            var book = Book(
                id: id,
                title: id,
                seriesInfo: SeriesInfo(name: "Self Test Series", sequence: sequence),
                duration: 600,
                isFinished: isFinished,
                libraryId: "self-test",
                providerId: providerID
            )
            book.seriesSequence = sequence
            return book
        }

        func episode(_ id: String, date: TimeInterval) -> Book {
            Book(
                id: id,
                title: id,
                duration: 600,
                isPodcastEpisode: true,
                episodeId: id,
                podcastLibraryItemId: "self-test-show",
                dateAdded: Date(timeIntervalSince1970: date),
                libraryId: "self-test-podcasts",
                providerId: providerID
            )
        }

        let one = seriesBook("one", sequence: "1")
        let two = seriesBook("two", sequence: "2")
        let twoAndHalf = seriesBook("two-and-half", sequence: "2.5")
        let three = seriesBook("three", sequence: "3")
        let four = seriesBook("four", sequence: "4", isFinished: true)
        let seriesCandidates = KeepNextOfflinePolicy.seriesCandidates(
            current: two,
            books: [three, one, four, twoAndHalf, two]
        )

        let oldest = episode("oldest", date: 1)
        let middle = episode("middle", date: 2)
        let newest = episode("newest", date: 3)
        let podcastCandidates = KeepNextOfflinePolicy.podcastCandidates(
            current: newest,
            episodes: [middle, oldest, newest],
            newestFirst: true
        )
        let downloads = KeepNextOfflinePolicy.downloadsNeeded(
            from: [twoAndHalf, three, four],
            targetCount: 2,
            isKeptOffline: { $0.id == twoAndHalf.id }
        )

        var preferences = UserPreferences.default
        preferences.keepNextItemsOfflineEnabled = true
        preferences.keepNextItemsOfflineCount = 5
        let decoded = try? JSONDecoder().decode(
            UserPreferences.self,
            from: JSONEncoder().encode(preferences)
        )

        let checks: [(String, Bool)] = [
            ("series order", seriesCandidates.map(\.id) == [twoAndHalf.id, three.id]),
            ("podcast order", podcastCandidates.map(\.id) == [middle.id, oldest.id]),
            ("offline window", downloads.map(\.id) == [three.id]),
            ("preference persistence", decoded?.keepNextItemsOfflineEnabled == true && decoded?.keepNextItemsOfflineCount == 5),
        ]
        let passed = checks.count(where: \.1)
        let report =
            (["KEEP NEXT OFFLINE - \(passed) pass, \(checks.count - passed) fail"]
            + checks.map {
                "[\($0.1 ? "PASS" : "FAIL")] \($0.0)"
            }).joined(separator: "\n")
        try? report.write(
            to: URL.documentsDirectory.appendingPathComponent("enve_keepofflinetest.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func runPodcastAutoQueueSelfTest() {
        let providerID = UUID()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-podcast-queue-self-test", isDirectory: true)
        let file = directory.appendingPathComponent("queue.json")
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        func episode(_ id: String, date: TimeInterval, isFinished: Bool = false) -> Book {
            Book(
                id: id,
                title: id,
                duration: 600,
                isPodcastEpisode: true,
                episodeId: id,
                podcastLibraryItemId: "self-test-show",
                dateAdded: Date(timeIntervalSince1970: date),
                isFinished: isFinished,
                libraryId: "self-test-podcasts",
                providerId: providerID
            )
        }

        let old = episode("old", date: 1)
        let middle = episode("middle", date: 2)
        let newest = episode("newest", date: 3)
        let finished = episode("finished", date: 4, isFinished: true)
        let recent = episode("recent", date: 99_000)
        let candidates = PodcastAutoQueuePolicy.newEpisodes(
            from: [finished, newest, old, middle],
            after: Date(timeIntervalSince1970: 1),
            limit: .all,
            now: Date(timeIntervalSince1970: 5)
        )
        let timeWindowCandidates = PodcastAutoQueuePolicy.newEpisodes(
            from: [old, recent],
            after: Date(timeIntervalSince1970: 0),
            limit: .last24Hours,
            now: Date(timeIntervalSince1970: 100_000)
        )

        let store = PlaybackQueueStore(fileURL: file)
        store.addLast(old, origin: .podcastAuto, groupKey: "self-test-show")
        store.addLast(middle, origin: .podcastAuto, groupKey: "self-test-show")
        store.addLast(newest, origin: .podcastAuto, groupKey: "self-test-show")
        store.addLast(episode("manual", date: 0), origin: .manual)
        let removals = PodcastAutoQueuePolicy.entriesToRemove(
            from: store.entries,
            groupKey: "self-test-show",
            limit: .two,
            now: Date(timeIntervalSince1970: 5)
        )

        var preferences = UserPreferences.default
        preferences.podcastAutoQueueSettings["self-test-show"] = PodcastAutoQueueSetting(
            position: .last,
            limit: .last7Days,
            baselinePublishedAt: Date(timeIntervalSince1970: 3)
        )
        let decoded = try? JSONDecoder().decode(
            UserPreferences.self,
            from: JSONEncoder().encode(preferences)
        )

        let checks: [(String, Bool)] = [
            ("new episodes are oldest first", candidates.map(\.id) == [middle.id, newest.id]),
            ("finished episodes are skipped", !candidates.contains(where: { $0.id == finished.id })),
            ("time limit excludes stale episodes", timeWindowCandidates.map(\.id) == [recent.id]),
            ("count limit removes only oldest auto-added episode", removals == [old.uniqueId]),
            ("queue entries retain their podcast group", store.entries.first?.groupKey == "self-test-show"),
            (
                "preference persistence",
                decoded?.podcastAutoQueueSettings["self-test-show"]?.limit == .last7Days
            ),
        ]
        let passed = checks.count(where: \.1)
        let report =
            (["PODCAST AUTO-QUEUE - \(passed) pass, \(checks.count - passed) fail"]
            + checks.map {
                "[\($0.1 ? "PASS" : "FAIL")] \($0.0)"
            }).joined(separator: "\n")
        try? report.write(
            to: URL.documentsDirectory.appendingPathComponent("enve_podcastqueuetest.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func runSiriAudiobookIntentSelfTest() async {
        let fixture = SiriAudiobookDescriptor(
            id: "self-test-audiobook",
            title: "The Left Hand of Darkness",
            author: "Ursula K. Le Guin",
            narrator: "George Guidall"
        )
        let descriptors = await SiriAudiobookService.downloadedAudiobooks()
        let ids = descriptors.map(\.id)
        let sorted = descriptors.sorted {
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id < $1.id
        }
        let resolved = await SiriAudiobookService.downloadedAudiobooks(with: ids)
        let selectedQuery: String? = descriptors.first?.title
            .split(separator: " ")
            .first
            .map(String.init)
        let matches: [SiriAudiobookDescriptor] =
            if let selectedQuery {
                await SiriAudiobookService.downloadedAudiobooks(matching: selectedQuery)
            } else {
                []
            }

        let checks: [(String, Bool)] = [
            ("title matching is case insensitive", fixture.matches("left hand")),
            ("author matching is supported", fixture.matches("le guin")),
            ("narrator matching is supported", fixture.matches("guidall")),
            ("blank search returns the entity", fixture.matches("   ")),
            ("downloaded entities have unique stable IDs", Set(ids).count == ids.count),
            ("downloaded entities are title sorted", descriptors == sorted),
            ("identifier query preserves order", resolved.map(\.id) == ids),
            (
                "title query returns the selected downloaded audiobook",
                descriptors.isEmpty || matches.contains(where: { $0.id == descriptors[0].id })
            ),
        ]
        let passed = checks.count(where: \.1)
        let report =
            (["SIRI AUDIOBOOK INTENTS - \(passed) pass, \(checks.count - passed) fail"]
            + checks.map {
                "[\($0.1 ? "PASS" : "FAIL")] \($0.0)"
            }).joined(separator: "\n")
        try? report.write(
            to: URL.documentsDirectory.appendingPathComponent("enve_siriintenttest.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func runPlaybackQueueSelfTest() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-queue-self-test", isDirectory: true)
        let file = directory.appendingPathComponent("queue.json")
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let providerID = UUID()
        func book(
            _ id: String,
            mediaType: AppMediaType = .audiobook,
            isFinished: Bool = false
        ) -> Book {
            Book(
                id: id,
                title: id,
                duration: 600,
                mediaType: mediaType,
                isFinished: isFinished,
                providerId: providerID,
                libraryId: "self-test"
            )
        }

        let one = book("one", isFinished: true)
        let two = book("two")
        let three = book("three")
        let ebook = book("ebook", mediaType: .ebook)
        var checks: [(String, Bool)] = []

        checks.append(
            (
                "policy keeps unfinished audio in source order",
                PlaybackQueuePolicy.playAllCandidates([one, two, ebook, three]).map(\.id) == ["two", "three"]
            )
        )

        let store = PlaybackQueueStore(fileURL: file)
        store.replace(with: [two, three, two], origin: .playAll, groupKey: "series:self-test")
        checks.append(("replace deduplicates", store.entries.map(\.book.id) == ["two", "three"]))
        store.addNext(one)
        store.move(bookID: three.uniqueId, by: -1)
        checks.append(("add and move preserve order", store.entries.map(\.book.id) == ["one", "three", "two"]))

        let restored = PlaybackQueueStore(fileURL: file)
        checks.append(("queue survives reload", restored.entries.map(\.book.id) == ["one", "three", "two"]))
        checks.append(
            (
                "origin survives reload",
                restored.entries.map(\.origin) == [.manual, .playAll, .playAll]
            )
        )

        let passed = checks.filter(\.1).count
        let report =
            (["PLAYBACK QUEUE - \(passed) pass, \(checks.count - passed) fail"]
            + checks.map {
                "[\($0.1 ? "PASS" : "FAIL")] \($0.0)"
            }).joined(separator: "\n")
        try? report.write(
            to: URL.documentsDirectory.appendingPathComponent("enve_queuetest.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func runPlaybackQueueEndToEndTest() async {
        let reportURL = URL.documentsDirectory.appendingPathComponent("enve_queue_e2e.txt")
        let fixtureDirectory = URL.documentsDirectory
            .appendingPathComponent("Individual_Audiobooks", isDirectory: true)
        let firstURL = fixtureDirectory.appendingPathComponent("queue-e2e-one.wav")
        let secondURL = fixtureDirectory.appendingPathComponent("queue-e2e-two.wav")
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: firstURL.path),
            fileManager.fileExists(atPath: secondURL.path)
        else {
            try? "PLAYBACK QUEUE E2E - FAIL\nMissing queue-e2e audio fixtures."
                .write(to: reportURL, atomically: true, encoding: .utf8)
            return
        }

        let providerID = UUID()
        let first = Book(
            id: "queue-e2e-one",
            title: "Queue Test One",
            duration: 1.5,
            source: .local,
            filePath: firstURL.path,
            providerId: providerID,
            libraryId: "queue-e2e"
        )
        let second = Book(
            id: "queue-e2e-two",
            title: "Queue Test Two",
            duration: 1.5,
            source: .local,
            filePath: secondURL.path,
            providerId: providerID,
            libraryId: "queue-e2e"
        )

        let originalContinuousPlayback = LibraryDisplayPreferencesStore.shared
            .loadPreferences()
            .continuousPlaybackEnabled
        SettingsPrefs.mutate { $0.continuousPlaybackEnabled = true }
        engine.playback.clearQueue()
        ActivePlayback.controller.stop()

        let started = engine.playback.playAll([first, second], groupKey: "debug:queue-e2e")
        var sawFirst = false
        var sawSecond = false
        for _ in 0..<150 {
            let currentID = ActivePlayback.controller.snapshot.currentBook?.id
            sawFirst = sawFirst || currentID == first.id
            if currentID == second.id {
                sawSecond = true
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        let error = ActivePlayback.controller.snapshot.errorDescription
        ActivePlayback.controller.stop()
        engine.playback.clearQueue()
        SettingsPrefs.mutate { $0.continuousPlaybackEnabled = originalContinuousPlayback }

        let fixtureNames = Set([firstURL.lastPathComponent, secondURL.lastPathComponent])
        let storedFixtures = await engine.library
            .firstBooks(source: Book.BookSource.local.rawValue, mediaType: "audiobook", limit: 1_000)
            .filter { book in
                guard let filePath = book.filePath else { return false }
                return fixtureNames.contains(URL(fileURLWithPath: filePath).lastPathComponent)
            }
        var removalByID: [String: Book] = [:]
        for book in storedFixtures + [first, second] {
            removalByID[book.uniqueId] = book
        }
        let removalCandidates = Array(removalByID.values)
        LibraryRecoveryCoordinator.shared.removeBooks(removalCandidates)
        await appState.bookStore.deleteBooks(uniqueIds: Set(removalCandidates.map(\.uniqueId)))
        try? fileManager.removeItem(at: firstURL)
        try? fileManager.removeItem(at: secondURL)

        let passed = started && sawFirst && sawSecond && error == nil
        let lines = [
            "PLAYBACK QUEUE E2E - \(passed ? "PASS" : "FAIL")",
            "started=\(started)",
            "sawFirst=\(sawFirst)",
            "sawSecond=\(sawSecond)",
            "error=\(error ?? "none")",
        ]
        try? lines.joined(separator: "\n")
            .write(to: reportURL, atomically: true, encoding: .utf8)
    }

    private func runVolumeLevelingSelfTest() {
        func steadyOutput(input: Float, strength: VolumeLevelingStrength) -> Float {
            guard let parameters = strength.parameters else { return input }
            let sampleRate = 44_100
            let processor = VolumeLeveler(
                parameters: parameters,
                sampleRate: Double(sampleRate),
                channels: 1
            )
            var samples = [Float](repeating: input, count: sampleRate)
            samples.withUnsafeMutableBufferPointer { buffer in
                processor.process(buffer: buffer.baseAddress!, count: buffer.count, channel: 0)
            }
            let tail = samples.suffix(sampleRate / 10)
            return tail.reduce(0) { $0 + abs($1) } / Float(tail.count)
        }

        func ratio(for strength: VolumeLevelingStrength) -> Float {
            steadyOutput(input: 0.8, strength: strength)
                / steadyOutput(input: 0.02, strength: strength)
        }

        let low = ratio(for: .low)
        let medium = ratio(for: .medium)
        let high = ratio(for: .high)
        let originalStrength = AudioProcessor.shared.volumeLevelingStrength
        AudioProcessor.shared.setVolumeLevelingStrength(.high)
        let persisted =
            LibraryDisplayPreferencesStore.shared
            .loadPreferences()
            .volumeLevelingStrength == .high
        AudioProcessor.shared.setVolumeLevelingStrength(originalStrength)

        let passed = low < 25 && medium < low && high < medium && persisted
        let report = [
            "VOLUME LEVELING - \(passed ? "PASS" : "FAIL")",
            "inputRatio=40.000",
            String(format: "lowRatio=%.3f", low),
            String(format: "mediumRatio=%.3f", medium),
            String(format: "highRatio=%.3f", high),
            "persistence=\(persisted ? "PASS" : "FAIL")",
        ].joined(separator: "\n")
        try? report.write(
            to: URL.documentsDirectory.appendingPathComponent("enve_levelingtest.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
    #endif

    private func runChapterExtractionTest() async {
        func write(_ s: String) {
            try? s.write(to: URL.documentsDirectory.appendingPathComponent("enve_chaptertest.txt"), atomically: true, encoding: .utf8)
        }
        let books = await engine.library.firstBooks(mediaType: "audiobook", limit: 120)
        var lines: [String] = []
        var tried = 0
        var got = 0
        for book in books where (book.chapters?.isEmpty ?? true) {
            guard tried < 6 else { break }
            tried += 1

            let b = await engine.library.refreshDetails(for: book)
            let serverChapters = b.chapters?.count ?? 0
            let chapters = serverChapters > 0 ? b.chapters : await MetadataLayeringManager.shared.extractChapters(for: b)
            let n = chapters?.count ?? 0
            if n > 0 { got += 1 }
            lines.append(
                "• \(b.title) src=\(b.source.rawValue) serverCh=\(serverChapters) tracks=\(b.audioTracks?.count ?? 0) partKey=\(b.partKey?.prefix(34) ?? "nil") file=\(b.filePath?.prefix(24) ?? "nil") → \(n) ch"
            )
        }
        write("tried=\(tried) gotChapters=\(got)\n" + lines.joined(separator: "\n"))
    }

    private func runStorytellerE2ETest() async {
        var lines: [String] = []
        var pass = 0
        var fail = 0
        var skip = 0
        func ok(_ m: String) { lines.append("[PASS] \(m)"); pass += 1 }
        func bad(_ m: String) { lines.append("[FAIL] \(m)"); fail += 1 }
        func na(_ m: String) { lines.append("[SKIP] \(m)"); skip += 1 }
        func flush() {
            let header = "STORYTELLER E2E - \(pass) pass, \(fail) fail, \(skip) skip\n" + String(repeating: "-", count: 44)
            let body = ([header] + lines + ["SUMMARY: \(pass) pass, \(fail) fail, \(skip) skip"]).joined(separator: "\n")
            try? body.write(
                to: URL.documentsDirectory.appendingPathComponent("enve_storyteller_e2e.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let storytellerConnections = appState.providerConnections.connections.filter { $0.type == .storyteller && !$0.isArchived }
        guard !storytellerConnections.isEmpty else {
            bad("No Storyteller connection. Add one in Settings > Sources, then re-run."); flush(); return
        }
        var connection = storytellerConnections[0]
        for candidate in storytellerConnections {
            let stored = await engine.library.books(source: Book.BookSource.storyteller.rawValue, providerId: candidate.id)
            if !stored.isEmpty {
                connection = candidate
                break
            }
        }
        guard let provider = appState.getProvider(connection.id) as? StorytellerProvider else {
            bad("Storyteller connection has no live provider instance."); flush(); return
        }
        ok("Connection: \"\(connection.name)\" \(connection.url)")

        do {
            let valid = try await provider.validateConnection()
            valid ? ok("Auth: connection validated") : bad("Auth: validation returned false")
        } catch {
            bad("Auth: \(error.localizedDescription)")
        }

        var libraries: [Library] = []
        do {
            libraries = try await provider.fetchLibraries()
            libraries.isEmpty ? bad("Libraries: server returned 0") : ok("Libraries: \(libraries.count)")
        } catch {
            bad("Libraries: \(error.localizedDescription)")
        }

        let libraryId = libraries.first?.id ?? "storyteller-library"
        var books: [Book] = []
        do {
            books = try await provider.fetchBooks(libraryId: libraryId)
            books.isEmpty ? bad("Books: server returned 0") : ok("Books: \(books.count)")
        } catch {
            bad("Books: \(error.localizedDescription)")
        }

        guard
            let book = books.first(where: { $0.id == "d61824f1-2b5e-4a05-adfc-aa65156f3d17" })
                ?? books.first(where: { $0.id == "8aa13ce0-efaf-4998-a01e-10031ff60a15" })
                ?? books.first(where: { $0.title.localizedCaseInsensitiveContains("seamage") })
        else {
            bad("Seamage: not found in Storyteller books"); flush(); return
        }
        ok("Seamage: found \"\(book.title)\" id=\(book.id)")

        var detailedBook = book
        do {
            let detail = try await provider.fetchFullBookDetails(bookId: book.id, libraryId: book.libraryId)
            detailedBook = detail
            let chapterCount = detail.chapters?.count ?? 0
            if chapterCount == 47 {
                ok("Detail: \(chapterCount) chapters")
            } else {
                bad("Detail: expected 47 chapters, got \(chapterCount)")
            }
            if let duration = detail.duration, duration > 78_000, duration < 79_000 {
                ok("Detail: duration \(Int(duration))s")
            } else {
                bad("Detail: unexpected duration \(Int(detail.duration ?? 0))s")
            }
        } catch {
            bad("Detail: \(error.localizedDescription)")
        }

        do {
            let chapters = try await provider.fetchManifestChapters(for: book)
            if chapters.count == 47 {
                ok("Manifest chapters: \(chapters.count)")
            } else {
                bad("Manifest chapters: expected 47, got \(chapters.count)")
            }
            if let first = chapters.first, abs(first.start) < 0.001 {
                ok("Manifest chapters: first starts at 0s")
            } else {
                bad("Manifest chapters: first start was \(chapters.first?.start ?? -1)")
            }
            if let last = chapters.last, last.end > 78_000, last.end < 79_000 {
                ok("Manifest chapters: last ends at \(Int(last.end))s")
            } else {
                bad("Manifest chapters: unexpected last end \(Int(chapters.last?.end ?? 0))s")
            }
        } catch {
            bad("Manifest chapters: \(error.localizedDescription)")
        }

        do {
            let session = try await provider.startPlaybackSession(for: book)
            defer { Task { await StorytellerStreamingServer.shared.stopStreaming() } }
            let total = session.audioTracks.reduce(0.0) { $0 + max($1.duration, 0) }
            if session.audioTracks.count == 47 {
                ok("Playback session: \(session.audioTracks.count) tracks")
            } else {
                bad("Playback session: expected 47 tracks, got \(session.audioTracks.count)")
            }
            if session.chapters.count == 47 {
                ok("Playback session: \(session.chapters.count) chapters")
            } else {
                bad("Playback session: expected 47 chapters, got \(session.chapters.count)")
            }
            if total > 78_000, total < 79_000 {
                ok("Playback session: duration \(Int(total))s")
            } else {
                bad("Playback session: unexpected duration \(Int(total))s")
            }
        } catch {
            bad("Playback session: \(error.localizedDescription)")
        }

        let synced = await engine.library.books(source: Book.BookSource.storyteller.rawValue, providerId: connection.id)
            .filter { $0.title.localizedCaseInsensitiveContains("seamage") }
        synced.isEmpty ? bad("Synced store: Seamage not present") : ok("Synced store: \(synced.count) Seamage result(s)")

        try? await Task.sleep(for: .seconds(2))
        let original: (progress: Double, locator: String?)?
        if let authoritative = await StorytellerPositionSyncService.shared.authoritativePosition(
            for: detailedBook,
            through: provider
        ) {
            original = (authoritative.position.progression, authoritative.position.locatorJSON)
        } else {
            original = nil
        }
        if let original,
            let probeTrack = detailedBook.audioTracks?.dropFirst(10).first,
            probeTrack.duration > 0
        {
            let localTime = min(probeTrack.duration * 0.4, max(probeTrack.duration - 1, 0))
            let expectedGlobalTime = probeTrack.startOffset + localTime
            let totalDuration = detailedBook.audioTracks?.totalDuration ?? detailedBook.duration ?? 0
            guard totalDuration > 0 else {
                bad("Audio locator probe: manifest duration is zero")
                flush()
                return
            }
            do {
                try await StorytellerPositionSyncService.shared.submitAudioPosition(
                    book: detailedBook,
                    currentTime: expectedGlobalTime,
                    observedAt: Date(),
                    through: provider
                )
                try? await Task.sleep(for: .milliseconds(900))
                if let audioProgress = try await provider.fetchAudiobookProgress(for: detailedBook) {
                    let delta = abs(audioProgress.positionSeconds - expectedGlobalTime)
                    if delta < 2 {
                        ok("Canonical audio locator: track-local t mapped to \(Int(expectedGlobalTime))s global")
                    } else {
                        bad("Canonical audio locator: expected \(Int(expectedGlobalTime))s, got \(Int(audioProgress.positionSeconds))s")
                    }
                } else {
                    bad("Canonical audio locator: fetchAudiobookProgress returned nil")
                }
                let session = try await provider.startPlaybackSession(for: detailedBook)
                await StorytellerStreamingServer.shared.stopStreaming()
                let sessionTime = session.serverCurrentTime ?? 0
                let sessionDelta = abs(sessionTime - expectedGlobalTime)
                if sessionDelta < 2 {
                    ok("Canonical audio locator → playback session: restored track-local t")
                } else {
                    bad("Canonical audio locator → playback session: expected \(Int(expectedGlobalTime))s, got \(Int(sessionTime))s")
                }
            } catch {
                bad("Canonical audio locator: \(error.localizedDescription)")
            }
            if let locator = original.locator {
                _ = try? await StorytellerPositionSyncService.shared.submit(
                    book: detailedBook,
                    locatorJSON: locator,
                    observedAt: Date(),
                    through: provider
                )
                try? await Task.sleep(for: .milliseconds(600))
                if let restored = await StorytellerPositionSyncService.shared.authoritativePosition(
                    for: detailedBook,
                    through: provider
                ), abs(restored.position.progression - original.progress) < 0.0001 {
                    ok("Canonical audio locator: original server position restored")
                } else {
                    bad("Canonical audio locator: original server position was not restored")
                }
            }
        } else {
            na("Canonical audio locator: no original position or manifest track to probe")
        }

        flush()
    }

    private func runGrimmoryE2ETest() async {
        var lines: [String] = []
        var pass = 0
        var fail = 0
        var skip = 0
        func ok(_ m: String) { lines.append("[PASS] \(m)"); pass += 1 }
        func bad(_ m: String) { lines.append("[FAIL] \(m)"); fail += 1 }
        func na(_ m: String) { lines.append("[SKIP] \(m)"); skip += 1 }
        func flush() {
            let header = "GRIMMORY E2E - \(pass) pass, \(fail) fail, \(skip) skip\n" + String(repeating: "-", count: 40)
            let body = ([header] + lines + ["SUMMARY: \(pass) pass, \(fail) fail, \(skip) skip"]).joined(separator: "\n")
            try? body.write(to: URL.documentsDirectory.appendingPathComponent("enve_grimmory_e2e.txt"), atomically: true, encoding: .utf8)
        }

        guard let connection = appState.providerConnections.connections.first(where: { $0.type == .booklore && !$0.isArchived }) else {
            bad("No Grimmory connection. Add one in Settings > Sources, then re-run."); flush(); return
        }
        guard let provider = appState.getProvider(connection.id) as? BookloreProvider else {
            bad("Grimmory connection has no live provider instance."); flush(); return
        }
        ok("Connection: \"\(connection.name)\" \(connection.url)")
        if let token = connection.token, !token.isEmpty {
            ok("Auth: bearer token present (\(token.count) chars)")
        } else {
            bad("Auth: no token. Login likely failed.")
        }

        var libraries: [Library] = []
        do {
            libraries = try await provider.fetchLibraries()
            if libraries.isEmpty {
                bad("Libraries: server returned 0")
            } else {
                ok("Libraries: \(libraries.count): " + libraries.prefix(5).map(\.name).joined(separator: ", "))
            }
        } catch { bad("Libraries: \(error.localizedDescription)") }

        var synced = await engine.library.firstBooks(
            source: Book.BookSource.booklore.rawValue,
            mediaTypes: ["audiobook", "ebook"],
            limitPerMediaType: 20000
        )
        synced = synced.filter { $0.providerId == connection.id }
        let audio = synced.filter { $0.mediaType == .audiobook }
        let ebooks = synced.filter { $0.mediaType == .ebook }
        if synced.isEmpty {
            bad("Books synced: 0. Run a library sync first.")
        } else {
            ok("Books synced: \(synced.count) (audiobooks=\(audio.count) ebooks=\(ebooks.count))")
        }

        let companions = audio.filter { $0.id.hasPrefix(BookloreProvider.companionAudiobookIDPrefix) }
        let linkedEbooks = ebooks.filter { $0.linkedAudiobookStableId != nil }
        if companions.isEmpty && linkedEbooks.isEmpty {
            na("Dual-format: no paired books found (fine if your library has none)")
        } else {
            let companionStableIds = Set(companions.map(\.stableId))
            let resolved = linkedEbooks.filter { ($0.linkedAudiobookStableId).map(companionStableIds.contains) ?? false }
            if !companions.isEmpty, companions.allSatisfy({ $0.linkedAudiobookStableId != nil }) {
                ok(
                    "Dual-format: \(companions.count) companion audiobooks, \(linkedEbooks.count) linked ebooks, \(resolved.count) fully cross-linked"
                )
            } else {
                bad("Dual-format: \(companions.count) companions but some lack a back-link to the ebook")
            }
        }

        if let companion = companions.first {
            do {
                let detail = try await provider.fetchFullBookDetails(bookId: companion.id, libraryId: companion.libraryId)
                if detail.mediaType == .audiobook && detail.id.hasPrefix(BookloreProvider.companionAudiobookIDPrefix) {
                    ok("Companion detail: id=\(detail.id) media=audiobook tracks=\(detail.audioTracks?.count ?? 0)")
                } else {
                    bad("Companion detail: expected audiobook companion, got id=\(detail.id) media=\(detail.mediaType.rawValue)")
                }
            } catch { bad("Companion detail: \(error.localizedDescription)") }
        } else if let ebook = ebooks.first {
            do {
                let detail = try await provider.fetchFullBookDetails(bookId: ebook.id, libraryId: ebook.libraryId)
                ok("Book detail (ebook): \"\(detail.title)\" id=\(detail.id) media=\(detail.mediaType.rawValue)")
            } catch { bad("Book detail (ebook): \(error.localizedDescription)") }
        }

        if let book = audio.first {
            do {
                let session = try await provider.startPlaybackSession(for: book)
                let dur = session.audioTracks.reduce(0.0) { $0 + max($1.duration, 0) }
                let maxTrack = session.audioTracks.map(\.duration).max() ?? 0

                let scalingSane = maxTrack < 86_400 * 1.5
                if session.audioTracks.isEmpty {
                    bad("Playback session: 0 tracks for \"\(book.title)\"")
                } else if !scalingSane {
                    bad("Playback session: implausible track duration \(Int(maxTrack))s. ms scaling likely wrong")
                } else {
                    ok(
                        "Playback session: tracks=\(session.audioTracks.count) chapters=\(session.chapters.count) total=\(Int(dur))s (scaling OK)"
                    )
                }
            } catch { bad("Playback session: \(error.localizedDescription)") }
        } else {
            na("Playback session: no audiobooks to test")
        }

        if let inProgress = await firstGrimmoryAudiobookWithProgress(provider: provider, candidates: audio) {
            let (book, original) = inProgress
            do {
                try await provider.updatePlaybackProgress(
                    book: book,
                    sessionId: nil,
                    currentTime: original,
                    isFinished: false,
                    timeListened: 0
                )
                try? await Task.sleep(for: .milliseconds(800))
                if let after = try await provider.fetchAudiobookProgress(for: book) {
                    let delta = abs(after.positionSeconds - original)
                    if delta < 3 {
                        ok(
                            "Audiobook progress round-trip: \"\(book.title)\" \(Int(original))s -> \(Int(after.positionSeconds))s (\(String(format: "%.1f", delta))s delta, exact-position OK)"
                        )
                    } else {
                        bad(
                            "Audiobook progress round-trip: pushed \(Int(original))s but pulled \(Int(after.positionSeconds))s (\(Int(delta))s delta. Exact position not preserved)"
                        )
                    }
                } else {
                    bad("Audiobook progress round-trip: pull returned nil after push")
                }
            } catch { bad("Audiobook progress round-trip: \(error.localizedDescription)") }
        } else {
            na("Audiobook progress round-trip: no in-progress audiobook (start one, then re-run)")
        }

        if let ebook = ebooks.first(where: { ($0.ebookProgress ?? 0) > 0.001 }) {
            let original = ebook.ebookProgress ?? 0
            let marker = "enve-drift-probe-anchor"
            let probeLocator =
                "{\"href\":\"\",\"type\":\"application/xhtml+xml\",\"locations\":{\"totalProgression\":\(original)},\"text\":{\"highlight\":\"\(marker)\",\"before\":\"\",\"after\":\"\"}}"
            do {
                try await provider.updateEbookProgress(for: ebook, progress: original, epubLocator: probeLocator)
                try? await Task.sleep(for: .milliseconds(900))
                if let result = try await provider.fetchEbookProgress(for: ebook) {
                    let pctOK = abs(result.progress - original) < 0.01
                    let anchorOK = result.locator?.contains(marker) ?? false
                    if pctOK && anchorOK {
                        ok("Ebook locator round-trip: \"\(ebook.title)\" \(Int(original*100))% + text-anchor preserved (drift-proof)")
                    } else if pctOK {
                        bad(
                            "Ebook round-trip: percent OK but text-anchor lost → would drift (locator=\(result.locator?.prefix(50) ?? "nil"))"
                        )
                    } else {
                        bad("Ebook round-trip: pushed \(Int(original*100))% but read \(Int(result.progress*100))%")
                    }
                } else {
                    bad("Ebook round-trip: fetchEbookProgress returned nil")
                }
            } catch { bad("Ebook round-trip: \(error.localizedDescription)") }
        } else {
            na("Ebook round-trip: no in-progress ebook (open one, then re-run)")
        }

        let sample = Array(synced.prefix(8))
        let withCovers = sample.filter { ($0.coverURL?.scheme?.hasPrefix("http")) ?? false }
        if sample.isEmpty {
            na("Cover URLs: no books to sample")
        } else if withCovers.count == sample.count {
            ok("Cover URLs: \(withCovers.count)/\(sample.count) well-formed")
        } else {
            bad("Cover URLs: only \(withCovers.count)/\(sample.count) are http(s)")
        }

        flush()
    }

    private func firstGrimmoryAudiobookWithProgress(provider: BookloreProvider, candidates: [Book]) async -> (Book, TimeInterval)? {
        for book in candidates.prefix(40) {
            if let result = try? await provider.fetchAudiobookProgress(for: book), result.positionSeconds > 60 {
                return (book, result.positionSeconds)
            }
        }
        return nil
    }

    private func runDedupAudit() async {
        func write(_ s: String) {
            let url = URL.documentsDirectory.appendingPathComponent("enve_dedupaudit.txt")
            try? s.write(to: url, atomically: true, encoding: .utf8)
        }
        let books = await engine.library.firstBooks(mediaTypes: ["audiobook", "ebook"], limitPerMediaType: 9000)
        let works = WorkGrouping.group(books)
            .filter { $0.isConsolidated }
            .sorted { $0.sourceCount > $1.sourceCount }

        func fmt(_ d: Date?) -> String { d.map { "\(Int($0.timeIntervalSince1970))" } ?? "-" }
        func last(_ s: String?, _ n: Int = 40) -> String {
            guard let s, !s.isEmpty else { return "-" }
            return String(s.suffix(n))
        }

        var lines: [String] = ["consolidatedWorks=\(works.count)"]
        for w in works {
            let srcs = w.editions.flatMap { $0.sources }
            lines.append("=== WORK \(w.workKey) | \"\(w.title)\" | editions=\(w.editionCount) sources=\(w.sourceCount)")
            for (i, b) in srcs.enumerated() {
                let dur = b.duration.map { String(format: "%.0f", $0) } ?? "nil"
                let chCount = b.chapters?.count ?? 0
                let ch0 = b.chapters?.first?.title ?? "-"
                let prov = String(b.providerId.uuidString.prefix(8))
                lines.append(
                    "  S\(i): title=\"\(b.title)\" media=\(b.mediaType.rawValue) prov=\(prov) backend=\(b.backendName ?? "-") lib=\(b.libraryName ?? "-") rk=\(b.ratingKey) bookId=\(b.id) durSec=\(dur) ch=\(chCount) ch0=\"\(ch0)\" asin=\(b.asin ?? "-") isbn=\(b.isbn ?? "-") seq=\(b.seriesSequence ?? "-") added=\(fmt(b.addedAt)) file=\(last(b.filePath)) ino=\(b.audioFileIno ?? "-") cover=\(last(b.coverURL?.absoluteString, 50))"
                )
            }
        }
        write(lines.joined(separator: "\n"))
    }

    private func runWorkGroupingSelfTest() async {
        func write(_ s: String) {
            let url = URL.documentsDirectory.appendingPathComponent("enve_worktest.txt")
            try? s.write(to: url, atomically: true, encoding: .utf8)
        }
        let books = await engine.library.firstBooks(mediaTypes: ["audiobook", "ebook"], limitPerMediaType: 8000)
        let works = WorkGrouping.group(books)
        let consolidated =
            works
            .filter { $0.isConsolidated }
            .sorted { ($0.sourceCount + $0.editionCount) > ($1.sourceCount + $1.editionCount) }

        func position(_ b: Book) -> String? {
            if let raw = b.seriesSequence?.trimmingCharacters(in: .whitespaces), !raw.isEmpty { return raw.lowercased() }
            if let n = b.seriesNumber { return String(n) }
            return nil
        }
        var violations: [String] = []
        for w in works {
            let positions = Set(w.editions.flatMap { $0.sources }.compactMap(position))
            if positions.count > 1 {
                violations.append("⚠️ \(w.title): merged positions \(positions.sorted().prefix(8).joined(separator: ","))")
            }
        }

        var lines = ["books=\(books.count) works=\(works.count) consolidated=\(consolidated.count) seriesViolations=\(violations.count)"]
        lines += violations.prefix(25)
        lines.append("--- top consolidated ---")
        for w in consolidated.prefix(30) {
            let eds = w.editions.map { "\($0.label)×\($0.sources.count)" }.joined(separator: ", ")
            lines.append("• \(w.title) [ed=\(w.editionCount) src=\(w.sourceCount)] \(eds)")
        }
        lines.append("--- detail: largest 6 groups ---")
        for w in consolidated.prefix(6) {
            lines.append("WORK \(w.workKey)")
            for s in w.editions.flatMap({ $0.sources }).prefix(12) {
                let dur = s.duration.map { "\(Int($0/60))m" } ?? "nil"
                lines.append(
                    "   ‹\(s.title)› seq=\(s.seriesSequence ?? "-")/\(s.seriesNumber.map(String.init) ?? "-") dur=\(dur) src=\(s.source.rawValue) lib=\(s.libraryName ?? "-")"
                )
            }
        }
        write(lines.joined(separator: "\n"))
    }

    @ViewBuilder
    private func debugRoutedScreen(_ route: String) -> some View {
        switch route {
        case "suggestions": WorkSuggestionsScreen()
        case "podcasts": PodcastsHomeScreen()
        case "discover": DiscoverScreen()
        case "collections": CollectionsScreen()
        case "hardcover": HardcoverHubScreen()
        case "vocabulary": VocabularyHubScreen()
        case "insights": JournalInsightsScreen()
        case "completion": CompletionCenterScreen()
        case "storage": StorageScreen()
        case "libraryhealth": LibraryHealthScreen()
        case "metadatabatch": MetadataBatchScreen()
        case "tour": HearthTour()
        default: EmptyView()
        }
    }

    private var shell: some View {
        ZStack(alignment: .bottom) {
            HearthBackground()

            VStack(spacing: 0) {
                shellBanners

                ZStack {
                    tabContent(.hearth) { HearthScreen(isActive: tab == .hearth) }
                    tabContent(.library) { LibraryScreen(isActive: tab == .library) }
                    tabContent(.podcasts) { PodcastsHomeScreen(isActive: tab == .podcasts, showsBackButton: false) }
                    tabContent(.journal) { JournalScreen(isActive: tab == .journal) }
                }
            }

            MantelBar(tab: $tab, style: prefs.shellNavigationStyle, onSelect: selectTab)

                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .environment(\.mantelInset, mantelInset)
        .environment(\.shellNavigationStyle, prefs.shellNavigationStyle)
    }

    private var mantelInset: CGFloat {
        switch prefs.shellNavigationStyle {
        case .classic:
            MantelBar.height + 16
        case .liquidGlass:
            MantelBar.liquidHeight + 18
        }
    }

    @ViewBuilder
    private var shellBanners: some View {
        VStack(spacing: 8) {
            if let connection = appState.providerConnections.connectionsNeedingReauth.first {
                ShellBanner(
                    kind: .warn,
                    glyph: "lock.rotation",
                    title: "\(connection.name) needs to sign in again"
                ) {
                    reauthConnection = connection
                }
            }
            if !appState.presentation.orphanedBooks.isEmpty {
                let n = appState.presentation.orphanedBooks.count
                ShellBanner(
                    kind: .info,
                    glyph: "questionmark.folder",
                    title: "\(n) downloaded \(n == 1 ? "file needs" : "files need") matching"
                ) {
                    showOrphanedMatcher = true
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, appState.providerConnections.connectionsNeedingReauth.isEmpty && appState.presentation.orphanedBooks.isEmpty ? 0 : 8)
        .animation(.smooth(duration: 0.3), value: appState.providerConnections.connectionsNeedingReauth.count)
        .animation(.smooth(duration: 0.3), value: appState.presentation.orphanedBooks.count)
    }

    @ViewBuilder
    private func tabContent<Content: View>(_ item: HearthTab, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .accessibilityHidden(tab != item)
        }
        .id(tabResetTokens[item])
        .opacity(tab == item ? 1 : 0)
        .allowsHitTesting(tab == item)
        .accessibilityHidden(tab != item)
    }

    private func selectTab(_ item: HearthTab) {
        tabResetTokens[item] = UUID()
        tab = item
    }

    private static func launchArgumentValue(_ key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-\(key)"),
            args.indices.contains(index + 1)
        else { return nil }
        return args[index + 1]
    }

    private static func launchArgumentBool(_ key: String) -> Bool {
        guard let value = launchArgumentValue(key)?.lowercased() else { return false }
        return value == "1" || value == "true" || value == "yes"
    }

    private static func clearPersistedDebugRouteKeys() {
        let keys = [
            "imagineScreen",
            "imagineOpenBook",
            "imagineFixture",
            "imagineSeed",
            "imagineTeardownSynthetic",
            "imagineRefreshLibraries",
            "imagineSourceType",
            "imagineSourceURL",
            "imagineSourceUser",
            "imagineSourcePassword",
            "imagineSeekFraction",
        ]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        if let bundleID = Bundle.main.bundleIdentifier,
            var domain = UserDefaults.standard.persistentDomain(forName: bundleID)
        {
            keys.forEach { domain.removeValue(forKey: $0) }
            UserDefaults.standard.setPersistentDomain(domain, forName: bundleID)
        }
        UserDefaults.standard.synchronize()
    }

    #if DEBUG
    private static func makePlayerSmokeBook() -> Book {
        Book(
            id: "debug-player-smoke",
            title: "The Ember Archive",
            author: "Enve Test Library",
            duration: 28_800,
            chapters: [
                Chapter(id: "debug-player-chapter-1", start: 0, end: 7_200, title: "The First Spark"),
                Chapter(id: "debug-player-chapter-2", start: 7_200, end: 18_000, title: "Across the Stacks"),
                Chapter(id: "debug-player-chapter-3", start: 18_000, end: 28_800, title: "Home to the Hearth"),
            ],
            source: .local,
            currentTime: 9_450,
            libraryId: "debug"
        )
    }

    private static func makeReaderSmokeBook() -> Book? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-reader-smoke", isDirectory: true)
        let page = folder.appendingPathComponent("page.png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: page.path) {
                let png = Data(
                    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZlK8AAAAASUVORK5CYII="
                )!
                try png.write(to: page, options: .atomic)
            }
        } catch {
            return nil
        }
        return Book(
            id: "debug-reader-smoke",
            title: "Reader Smoke Fixture",
            author: "Enve",
            source: .local,
            filePath: folder.path,
            mediaType: .ebook,
            ebookFormat: EbookFormat.imagefolder.rawValue,
            libraryId: "debug"
        )
    }
    #endif
}

struct HearthBackground: View {
    @Environment(\.hearth) private var hearth

    var body: some View {
        hearth.bg.ignoresSafeArea()
    }
}

private struct ShellBanner: View {
    enum Kind { case warn, info }
    let kind: Kind
    let glyph: String
    let title: String
    let action: () -> Void

    @Environment(\.hearth) private var hearth

    private var tint: Color { kind == .warn ? hearth.statusWarn : hearth.ember }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: glyph)
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.hearthUI(13, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.hearthUI(11, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                            .strokeBorder(tint.opacity(0.4), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(hearth.isInk ? 0.4 : 0.12), radius: 12, y: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct SplashGlow: View {
    @Environment(\.hearth) private var hearth

    var body: some View {
        ZStack {
            hearth.bg.ignoresSafeArea()
            EmberGlow(tint: Hearth.accent, isBreathing: true, intensity: 0.5)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                HearthSplashEmblem()
                    .frame(width: 154, height: 154)
                Text("enve")
                    .font(.system(size: Hearth.scaled(42), weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hexValue: 0xFFD15C), hearth.ember],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .black.opacity(0.24), radius: 10, y: 5)
            }
            .padding(.top, 12)
        }
    }
}

private struct HearthSplashEmblem: View {
    @Environment(\.hearth) private var hearth

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hexValue: 0x4D565E),
                            Color(hexValue: 0x252B31),
                            Color(hexValue: 0x111316),
                        ],
                        center: .top,
                        startRadius: 8,
                        endRadius: 140
                    )
                )
                .overlay {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.30), .black.opacity(0.36)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }

            BookFoldMark()
                .frame(width: 124, height: 78)
                .offset(y: 18)

            Image(systemName: "flame.fill")
                .font(.system(size: 58, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(hexValue: 0xFFE17A),
                            Color(hexValue: 0xFFC233),
                            Color(hexValue: 0xF58214),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.42), radius: 8, y: 4)
                .shadow(color: hearth.ember.opacity(0.54), radius: 18)
        }
        .shadow(color: .black.opacity(0.42), radius: 24, y: 12)
        .shadow(color: hearth.ember.opacity(0.28), radius: 30, y: 6)
    }
}

private struct BookFoldMark: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let valley = CGPoint(x: w * 0.5, y: h * 0.84)
            let leftOuter = CGPoint(x: w * 0.02, y: h * 0.46)
            let rightOuter = CGPoint(x: w * 0.98, y: h * 0.46)
            let leftTop = CGPoint(x: w * 0.36, y: h * 0.18)
            let rightTop = CGPoint(x: w * 0.64, y: h * 0.18)
            let center = CGPoint(x: w * 0.5, y: h * 0.44)

            ZStack {
                Path { path in
                    path.move(to: valley)
                    path.addLine(to: leftOuter)
                    path.addLine(to: leftTop)
                    path.addLine(to: center)
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [Color(hexValue: 0x5A646D), Color(hexValue: 0x20262C)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

                Path { path in
                    path.move(to: valley)
                    path.addLine(to: rightOuter)
                    path.addLine(to: rightTop)
                    path.addLine(to: center)
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [Color(hexValue: 0x46505A), Color(hexValue: 0x161A1F)],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                )

                Path { path in
                    path.move(to: leftOuter)
                    path.addLine(to: valley)
                    path.addLine(to: rightOuter)
                }
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.72), .white.opacity(0.30)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .opacity(0.92)
    }
}

extension View {

    func enveEnvironment() -> some View {
        self
            .environment(AppState.shared)
            .environment(EnveEngine.shared)
            .environmentObject(ThemeManager.shared)
            .environment(PlayerViewModel.shared)
            .environment(\.shellNavigationStyle, LibraryDisplayPreferencesStore.shared.loadPreferences().shellNavigationStyle)
            .preferredColorScheme(Hearth.mode.preferredColorScheme)
            .hearthRoot()
    }
}
