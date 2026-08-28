import Combine
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import SwiftUI
import UIKit
import WebKit

struct ReaderScreen: View {
    let book: Book

    @StateObject private var model: ClassicReaderModel
    @Environment(\.hearth) private var hearth
    @Environment(\.shellNavigationStyle) private var shellNavigationStyle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var chromeVisible = false
    @State private var tray: ReaderTray?
    @State private var ambient: SwiftUI.Color = Hearth.accent
    @State private var inkColor = "#FFF59D"
    @State private var noteDraft: ReaderNoteDraft?
    @State private var bookmarkDraft: ReaderBookmarkDraft?
    @State private var bookmarkToast: String?
    @State private var bookmarkToastTask: Task<Void, Never>?
    @State private var readAloudControlsVisible = false
    @State private var ttsControlsVisible = false
    @State private var ttsControlsPresentedForSession = false
    @State private var initialChromeHideTask: Task<Void, Never>?
    @State private var readAloudControlsHideTask: Task<Void, Never>?
    @State private var ttsControlsHideToken = UUID()
    @State private var defineRequest: ReaderDefineRequest?
    @State private var showingConflict = false
    @State private var linkedAudiobook: Book?
    @State private var showingLibrarian = false
    @State private var librarianMessage: String?
    @State private var comicScrubTargetIndex: Int?
    @State private var epubScrubProgress: Double?
    @State private var nextSeriesIssue: Book?
    @State private var dismissedNextSeriesPrompt = false
    @State private var footnoteFixtureTriggered = false
    @State private var readAloudFixtureTriggered = false
    @State private var ttsPlaybackFixtureTriggered = false

    init(book: Book, providerResolver: any LibraryProviderResolving) {
        self.book = book
        #if DEBUG
        let engineOverride = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--reader-engine=") })
            .flatMap { ReaderEngineKind(rawValue: String($0.dropFirst("--reader-engine=".count))) }
        #else
        let engineOverride: ReaderEngineKind? = nil
        #endif
        _model = StateObject(
            wrappedValue: ClassicReaderModel(
                book: book,
                readerEngineOverride: engineOverride,
                providerResolver: providerResolver
            )
        )
    }

    var body: some View {
        ZStack {
            backdrop
            content
            readerDimmer
        }
        .accessibilityIdentifier("reader-screen")
        .overlay(alignment: .top) {
            if chromeVisible, model.state.isReady {
                topVeil
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if chromeVisible, model.state.isReady {
                bottomVeil
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if model.pendingSelection == nil {
                floatingPills
                    .padding(.bottom, chromeVisible ? 172 : 36)
            }
        }
        .overlay(alignment: .top) {
            if model.isReadTogetherActive {
                ReaderTogetherBanner {
                    Task { await model.stopReadTogether() }
                }
                .padding(.top, chromeVisible ? 64 : 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if let selection = model.pendingSelection {
                annotateLayer(selection)
            }
        }
        .overlay {
            VolumeButtonNavigationCapture(
                isEnabled: model.appearance.volumeButtonsTurnPages,
                onIncrease: { Task { await model.pageForward() } },
                onDecrease: { Task { await model.pageBackward() } }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
        .overlay {
            ReaderKeyboardNavigationCapture(
                isRightToLeft: model.isRightToLeftPageProgression,
                onForward: { Task { await model.pageForward() } },
                onBackward: { Task { await model.pageBackward() } }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
        .overlay {
            if showsFullHeightTapZones {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: geometry.size.width * 0.13)
                            .onTapGesture { turnPageFromLeftEdge() }
                        Color.clear
                            .allowsHitTesting(false)
                            .frame(maxWidth: .infinity)
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: geometry.size.width * 0.13)
                            .onTapGesture { turnPageFromRightEdge() }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if let bookmarkToast {
                ReaderToast(message: bookmarkToast)
                    .padding(.top, 72)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: nextSeriesPromptAlignment) {
            if let nextSeriesIssue, showsNextSeriesPrompt {
                ReaderNextSeriesPrompt(book: nextSeriesIssue, title: nextSeriesPromptTitle, tint: ambient) {
                    dismissNextSeriesPrompt()
                } onReadNext: {
                    openNextIssue(nextSeriesIssue)
                }
                .padding(.horizontal, 18)
                .padding(nextSeriesPromptPaddingEdge, 30)
                .transition(.move(edge: nextSeriesPromptTransitionEdge).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.35), value: chromeVisible)
        .animation(.smooth(duration: 0.25), value: model.pendingSelection != nil)
        .animation(.smooth(duration: 0.3), value: model.isReadTogetherActive)
        .animation(.smooth(duration: 0.25), value: bookmarkToast)
        .animation(.smooth(duration: 0.25), value: readAloudControlsVisible)
        .animation(.smooth(duration: 0.25), value: ttsControlsVisible)
        .animation(.smooth(duration: 0.28), value: showsNextSeriesPrompt)
        .sheet(item: $tray) { presented in
            Group {
                switch presented {
                case .contents:
                    ReaderContentsTray(model: model, ambient: ambient)
                case .appearance:
                    ReaderAppearanceTray(model: model)
                case .search:
                    ReaderSearchTray(model: model)
                case .tts:
                    ReaderTTSSheet(tts: model.ttsService) { model.startTTS() }
                case .readAloud:
                    ReaderReadAloudTray(model: model)
                case .export:
                    ReaderExportSheet(
                        book: book,
                        annotations: model.annotationController.annotations,
                        bookmarks: model.annotationController.bookmarks
                    )
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(model.preferredColorScheme)
            .enveEnvironment()
        }
        .fullScreenCover(isPresented: $showingLibrarian) {
            LibrarianChatScreen(book: book, currentEbookProgress: model.currentProgress ?? book.canonicalEbookProgress)
                .enveEnvironment()
        }
        .alert(
            "The librarian is away",
            isPresented: Binding(
                get: { librarianMessage != nil },
                set: { if !$0 { librarianMessage = nil } }
            )
        ) {
            Button("All right", role: .cancel) { librarianMessage = nil }
        } message: {
            Text(librarianMessage ?? "")
        }
        .sheet(item: $noteDraft) { draft in
            ReaderNoteSheet(excerpt: draft.text) { note in
                saveNote(draft: draft, note: note)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(model.preferredColorScheme)
            .enveEnvironment()
        }
        .sheet(item: $bookmarkDraft) { draft in
            ReaderNoteSheet(
                title: "Bookmark this spot",
                actionTitle: "Save Bookmark",
                excerpt: draft.context
            ) { note in
                saveBookmark(draft: draft, note: note)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(model.preferredColorScheme)
            .enveEnvironment()
        }
        .sheet(item: $defineRequest) { request in
            ReaderDefineSheet(
                term: request.term,
                vocabEntry: request.vocabEntry,
                initiallySaved: request.initiallySaved,
                onSaveWord: { model.annotationController.saveVocab($0) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(model.preferredColorScheme)
            .enveEnvironment()
        }
        .alert("Two reading positions", isPresented: $showingConflict) {
            if let conflict = EbookConflictStore.shared.find(stableId: book.stableId) {
                Button("Keep this device (\(Int(conflict.localProgress * 100))%)") {
                    SyncCoordinator.shared.resolveEbookConflict(bookStableId: book.stableId, useServer: false)
                }
                Button("Use the server (\(Int(conflict.serverProgress * 100))%)") {
                    let serverLocator = conflict.serverLocator
                    SyncCoordinator.shared.resolveEbookConflict(bookStableId: book.stableId, useServer: true)
                    if let json = serverLocator, !json.isEmpty {
                        model.navigateTo(locatorJSON: json)
                    }
                }
                Button("Not now", role: .cancel) {}
            }
        } message: {
            Text("This device and the server remember different places in this book.")
        }
        .onReceive(model.ttsService.$highlightLocator.removeDuplicates()) { locator in
            model.applyTTSDecoration(locator)
        }
        .onReceive(
            model.ttsService.$followLocator
                .compactMap { $0 }
                .removeDuplicates()
                .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
        ) { locator in
            model.followTTSLocator(locator)
        }
        .onReceive(
            model.ttsService.$isPlaying
                .combineLatest(model.ttsService.$isPaused)
                .map { $0 || $1 }
                .removeDuplicates()
        ) { active in
            if active {
                if !ttsControlsPresentedForSession {
                    ttsControlsPresentedForSession = true
                    if tray == nil {
                        withAnimation(.smooth(duration: 0.35)) {
                            chromeVisible = false
                        }
                    }
                    if !ttsControlsVisible {
                        showTTSControls(autoHide: true)
                    }
                }
            } else {
                ttsControlsPresentedForSession = false
                hideTTSControls()
            }
        }
        .onReceive(model.ttsService.$enhancedDownloadState) { state in
            #if DEBUG
            guard debugRoute == "ttsplayback", state == .ready, model.state.isReady else { return }
            startTTSPlaybackFixture()
            #endif
        }
        .onReceive(model.ttsService.$kokoroDownloadState) { state in
            #if DEBUG
            guard debugRoute == "kokoroplayback", state == .ready, model.state.isReady else { return }
            startTTSPlaybackFixture()
            #endif
        }
        .preferredColorScheme(model.preferredColorScheme)
        .statusBarHidden(!chromeVisible)
        .onAppear(perform: beginSession)
        .onChange(of: colorScheme) { _, newValue in
            model.updateSystemColorScheme(newValue)
        }
        .onChange(of: model.pendingSelection != nil) { _, active in
            guard active else { return }
            readAloudControlsHideTask?.cancel()
            withAnimation(.smooth) {
                chromeVisible = false
                readAloudControlsVisible = false
            }
        }
        .onChange(of: tray) { _, presented in
            guard presented == nil,
                model.ttsService.isPlaying || model.ttsService.isPaused
            else { return }
            withAnimation(.smooth(duration: 0.35)) {
                chromeVisible = false
            }
            if !ttsControlsVisible {
                showTTSControls(autoHide: true)
            }
        }
        .onChange(of: model.state.isReady) { _, ready in
            guard ready else { return }
            #if DEBUG
            if [
                "ttsvoices", "ttsdownload", "kokorodownload",
            ].contains(debugRoute) {
                tray = .tts
            }
            if debugRoute == "ttsplayback", model.ttsService.enhancedDownloadState == .ready {
                startTTSPlaybackFixture()
            }
            if debugRoute == "kokoroplayback", model.ttsService.kokoroDownloadState == .ready {
                startTTSPlaybackFixture()
            }
            if !footnoteFixtureTriggered,
                ProcessInfo.processInfo.arguments.contains("--activate-first-footnote")
            {
                footnoteFixtureTriggered = true
                Task { await model.activateFirstFootnoteForTesting() }
            }
            if !readAloudFixtureTriggered,
                ProcessInfo.processInfo.arguments.contains("--exercise-read-aloud")
            {
                readAloudFixtureTriggered = true
                startReadAloudFixture(useTTS: false)
            }
            if !readAloudFixtureTriggered,
                ProcessInfo.processInfo.arguments.contains("--exercise-tts-play")
            {
                readAloudFixtureTriggered = true
                startReadAloudFixture(useTTS: true)
            }
            #endif
            initialChromeHideTask?.cancel()
            initialChromeHideTask = Task { @MainActor in
                withAnimation(.smooth) { chromeVisible = true }
                try? await Task.sleep(for: .seconds(3.5))
                guard !Task.isCancelled else { return }
                #if DEBUG
                if UserDefaults.standard.string(forKey: "imagineScreen") == "readerchrome" { return }
                #endif
                if tray == nil, model.pendingSelection == nil {
                    withAnimation(.smooth) { chromeVisible = false }
                }
            }
        }
        .onChange(of: model.isReadAloudMode) { _, active in
            if active {
                showReadAloudControls(autoHide: true)
            } else {
                readAloudControlsHideTask?.cancel()
                withAnimation(.smooth) { readAloudControlsVisible = false }
            }
        }
        .onDisappear(perform: endSession)
        .task {
            ambient = await AmbientColorStore.shared.resolve(for: book)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-readerAutoReadTogether") {
                for _ in 0..<120 {
                    if case .loading = model.state {
                        try? await Task.sleep(for: .milliseconds(500))
                    } else {
                        break
                    }
                }
                await model.startReadTogether()
            }
            #endif
        }
    }

    #if DEBUG
    private var debugRoute: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-imagineScreen"),
            arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    private func startReadAloudFixture(useTTS: Bool) {
        Task { @MainActor in
            func write(_ lines: [String]) {
                try? lines.joined(separator: "\n").write(
                    to: URL.documentsDirectory.appendingPathComponent("enve_read_aloud.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }

            let selection = model.readerEngineSelection
            write([
                "READ-ALOUD REPRO",
                "book: \(book.title)",
                "source: \(book.source.rawValue)",
                "epub3Features.hasMediaOverlay: \(String(describing: book.epub3Features?.hasMediaOverlay))",
                "detected media overlay: \(model.hasMediaOverlay)",
                "engine preferred/active: \(selection.preferred.rawValue)/\(selection.active.rawValue)",
                "mode: \(useTTS ? "tts" : "read-aloud")",
                "server locator: \(book.epubLocator ?? "nil")",
                "ebookProgress: \(String(describing: book.ebookProgress))",
                "state: pressing play…",
            ])

            if useTTS { model.startTTS() } else { model.toggleReadAloud() }

            var samples: [String] = []
            for tick in 0..<12 {
                try? await Task.sleep(for: .seconds(2))
                let time = model.overlayPlayer?.currentTime ?? -1
                let fragment = model.overlayPlayer?.currentFragmentId ?? "nil"
                samples.append("  t+\(tick * 2)s  audio=\(String(format: "%.2f", time))  fragment=\(fragment)")
            }

            let after = model.readerEngineSelection
            write(
                [
                    "READ-ALOUD REPRO",
                    "book: \(book.title)",
                    "source: \(book.source.rawValue)",
                    "epub3Features.hasMediaOverlay: \(String(describing: book.epub3Features?.hasMediaOverlay))",
                    "detected media overlay: \(model.hasMediaOverlay)",
                    "engine preferred/active: \(after.preferred.rawValue)/\(after.active.rawValue)",
                    "overlayPlayer: \(model.overlayPlayer == nil ? "nil" : "present")",
                    "isReadAloudMode: \(model.isReadAloudMode)",
                    "playing: \(String(describing: model.overlayPlayer?.isPlaying))",
                    "player time: \(String(describing: model.overlayPlayer?.currentTime))",
                    "tts playing/paused: \(model.ttsService.isPlaying)/\(model.ttsService.isPaused)",
                    "survived: yes",
                    "--- progression ---",
                ] + samples
            )
        }
    }

    private func startTTSPlaybackFixture() {
        guard !ttsPlaybackFixtureTriggered else { return }
        ttsPlaybackFixtureTriggered = true
        model.startTTS()
        guard ProcessInfo.processInfo.arguments.contains("--exercise-tts-navigation") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await model.pageForward()
            try? await Task.sleep(for: .seconds(3))
            model.handleReaderDoubleTap(at: CGPoint(x: 196, y: 380))
        }
    }
    #endif

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            loadingView
        case .readyEPUB, .readyFoliate:
            if let adapter = model.activeReaderEngineAdapter {
                ZStack {
                    ReaderEngineControllerBridge(
                        adapter: adapter,
                        onHighlight: {
                            model.annotationController.addAnnotationFromSelection(style: .highlight, colorHex: inkColor)
                            PlatformHaptics.impact(.light)
                        },
                        onAnnotate: {
                            if let selection = adapter.currentSelection {
                                model.pendingSelection = selection
                                noteDraft = ReaderNoteDraft(text: selection.locator.text.highlight ?? "")
                            }
                        },
                        onSelectionDismiss: {
                            dismissPendingSelection()
                        },
                        onDoubleTap: { point in
                            model.doubleTapHandler?(point)
                        },
                        isDoubleTapEnabled: model.isReadAloudMode
                            || model.ttsService.isPlaying
                            || model.ttsService.isPaused,
                        isScrollMode: model.appearance.scrollEnabled,
                        isSelectionActive: model.pendingSelection != nil
                    )
                    .ignoresSafeArea(edges: model.castingCanvasSize == nil ? .vertical : [])
                    .frame(width: model.castingCanvasSize?.width, height: model.castingCanvasSize?.height)
                    .scaleEffect(model.castingCanvasSize == nil ? 1 : 1.0 / 3.0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if model.isReadTogetherActive {
                        ReaderCastingCover(model: model, bookTitle: book.title)
                    }
                }
            }
        case .readyPDF:
            if let controller = model.pdfController {
                PDFReaderBridge(controller: controller)
                    .ignoresSafeArea()
                    .simultaneousGesture(pdfPageTurnGesture)
            }
        case .readyComic:
            ComicReaderBridge(
                pages: model.comicPages,
                currentPageIndex: Binding(
                    get: { model.currentComicPageIndex },
                    set: { model.setComicPage($0) }
                ),
                layout: model.effectiveComicLayout,
                pageFit: model.appearance.comicPageFit,
                zoomEnabled: model.appearance.comicZoomEnabled,
                oneHandedZoom: model.appearance.comicOneHandedZoom,
                backgroundColor: model.appearance.comicBackgroundColor,
                spreadEnabled: model.appearance.comicLandscapeSpread,
                onVisiblePageChange: { index in
                    model.setComicPage(index, shouldRecordStats: false)
                },
                onTap: { point, size in
                    handleTap(point, viewSize: size)
                }
            )
            .ignoresSafeArea()
        case .readyHTML(let webView):
            HTMLReaderBridge(webView: webView)
                .ignoresSafeArea()
        case .failed(let error):
            failedView(error)
        }
    }

    private var backdrop: some View {
        Group {
            if case .readyComic = model.state {
                model.appearance.comicBackgroundColor.swiftUIColor
            } else if model.state.isReady {
                Color(model.effectiveAppearance.shellBackgroundColor)
            } else {
                hearth.bg
            }
        }
        .ignoresSafeArea()
    }

    private var readerDimmer: some View {
        Color.black
            .opacity(max(0, 1 - model.appearance.brightness))
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    private var loadingView: some View {
        VStack(spacing: 18) {
            ProgressView()
                .tint(hearth.ember)
            Text(book.title)
                .font(.hearthBookTitle)
                .foregroundStyle(hearth.text)
                .multilineTextAlignment(.center)
            Text("Finding your page…")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
        .padding(.horizontal, 40)
    }

    private func failedView(_ error: Error) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "book.closed")
                .font(.hearthUI(30))
                .foregroundStyle(hearth.ember)
            Text("This book wouldn't open.")
                .font(.hearthDisplay(22, weight: .semibold))
                .foregroundStyle(hearth.text)
            Text(readerOpenFailureMessage(error))
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .multilineTextAlignment(.center)
            QuietButton(title: "Close") { dismiss() }
                .padding(.top, 6)
        }
        .padding(.horizontal, 40)
    }

    private var topVeil: some View {
        ZStack {
            Overline(book.title)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background {
                    HearthChromeBackground(
                        shape: .capsule,
                        fill: hearth.bgElevated,
                        stroke: hearth.hairline,
                        tint: hearth.bgElevated
                    )
                }
                .padding(.horizontal, 76)
            HStack {
                Spacer()
                GlyphButton(systemImage: "xmark", label: "Close") {
                    Task { @MainActor in
                        await model.saveProgressResolvingVisibleOverlay()
                        dismiss()
                    }
                }
            }
            .padding(.trailing, 20)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    private var bottomVeil: some View {
        VStack(spacing: 12) {
            if isComicReader {
                comicPositionControls
            } else {
                ReaderFooterProgressPill(
                    progress: epubScrubProgress ?? model.currentProgress ?? 0,
                    tint: ambient,
                    ticks: ribbonTicks,
                    statusLine: epubScrubProgress.map { model.positionSummaryText(atProgress: $0) } ?? statusLine,
                    onScrub: { epubScrubProgress = $0 },
                    onCommit: { progress in
                        PlatformHaptics.selection()
                        Task {
                            await model.seek(toProgress: progress)
                            epubScrubProgress = nil
                        }
                    }
                )
                .padding(.horizontal, 28)
            }
            if let nextSeriesIssue, isComicAtEnd {
                QuietButton(title: "Open next issue", systemImage: "arrow.forward.circle") {
                    openNextIssue(nextSeriesIssue)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            readAloudBar
            if let linkedAudiobook {
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(hearth.statusOK)
                            .frame(width: 6, height: 6)
                        Text("Linked")
                            .font(.hearthUI(11, weight: .semibold))
                            .foregroundStyle(hearth.textSecondary)
                    }
                    .accessibilityLabel("Audiobook linked")
                    ReaderListenAlongBar(ebook: book, audiobook: linkedAudiobook, model: model)
                }
            }
            HStack(spacing: 18) {
                GlyphButton(systemImage: "list.bullet", label: "Contents") { tray = .contents }
                if showsAppearance {
                    GlyphButton(systemImage: "textformat.size", label: "Appearance") { tray = .appearance }
                }
                if isEPUB {
                    GlyphButton(systemImage: "magnifyingglass", label: "Search") { tray = .search }
                }
                if isEPUB || model.hasMediaOverlay {
                    moreMenu
                }
            }
            .padding(.top, 2)
        }
        .padding(.top, 30)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background { bottomVeilBackground }
    }

    @ViewBuilder
    private var bottomVeilBackground: some View {
        if shellNavigationStyle == .liquidGlass {
            HearthChromeBackground(
                shape: .rounded(28),
                fill: hearth.bg,
                stroke: hearth.hairline,
                tint: ambient,
                interactive: false,
                shadow: true
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        } else {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: hearth.bg.opacity(0.75), location: 0.22),
                    .init(color: hearth.bg, location: 0.5),
                    .init(color: hearth.bg, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var comicPositionControls: some View {
        if comicPageTotal > 0 {
            ComicPageScrubber(
                currentIndex: comicCurrentPageIndex,
                targetIndex: comicScrubTargetIndex,
                totalPages: comicPageTotal,
                isRightToLeft: model.isRightToLeftPageProgression,
                tint: ambient,
                onScrub: { target in
                    comicScrubTargetIndex = target
                },
                onCommit: { target in
                    comicScrubTargetIndex = nil
                    PlatformHaptics.selection()
                    model.setComicPage(target)
                }
            )
            .padding(.horizontal, 28)

            Text(comicStatusLine)
                .font(.hearthUI(13, weight: .medium).monospacedDigit())
                .foregroundStyle(hearth.textSecondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var readAloudBar: some View {
        if model.isReadAloudMode, let player = model.overlayPlayer {
            ReaderReadAloudBar(
                model: model,
                player: player,
                onBookmark: { bookmarkDraft = makeBookmarkDraft(readAloud: true) },
                onSettings: { tray = .readAloud },
                onStop: { model.toggleReadAloud() }
            )
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var moreMenu: some View {
        Menu {
            if isEPUB {
                Button {
                    tray = .tts
                } label: {
                    Label("Read to me", systemImage: "speaker.wave.2")
                }
            }
            if model.hasMediaOverlay {
                Button {
                    model.toggleReadAloud()
                } label: {
                    Label(model.isReadAloudMode ? "Stop Read Aloud" : "Read Aloud", systemImage: "waveform")
                }
                Button {
                    tray = .readAloud
                } label: {
                    Label("Read Aloud settings", systemImage: "slider.horizontal.3")
                }
            }
            if isEPUB {
                Button {
                    readerOpenLibrarian()
                } label: {
                    Label("Ask the librarian", systemImage: "books.vertical")
                }
                Button {
                    tray = .export
                } label: {
                    Label("Export notes", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button {
                    Task {
                        if model.isReadTogetherActive {
                            await model.stopReadTogether()
                        } else {
                            await model.startReadTogether()
                        }
                    }
                } label: {
                    Label(
                        model.isReadTogetherActive ? "Stop reading on Apple TV" : "Read together on Apple TV",
                        systemImage: model.isReadTogetherActive ? "appletv.fill" : "appletv"
                    )
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.hearthUI(17, weight: .semibold))
                .foregroundStyle(hearth.text)
                .frame(width: 44, height: 44)
                .background {
                    HearthChromeBackground(
                        shape: .circle,
                        fill: hearth.bgElevated,
                        stroke: hearth.hairline,
                        tint: hearth.bgElevated
                    )
                }
        }
        .accessibilityLabel("More")
    }

    private var isEPUB: Bool {
        switch model.state {
        case .readyEPUB, .readyFoliate: true
        default: false
        }
    }

    private var isComicReader: Bool {
        if case .readyComic = model.state { return true }
        return model.isComicBook && !model.comicPages.isEmpty
    }

    private var showsAppearance: Bool {
        switch model.state {
        case .readyEPUB, .readyFoliate, .readyPDF, .readyComic: return true
        default: return false
        }
    }

    private var statusLine: String? {
        var parts: [String] = []
        if let pages = model.pageSummaryText {
            parts.append(pages)
        }
        parts.append(model.percentSummaryText)
        if let minutes = model.minutesLeftInChapter, minutes > 0 {
            parts.append("\(Self.minutesText(minutes)) left in chapter")
        } else if let minutes = model.minutesLeftInBook, minutes > 0 {
            parts.append("\(Self.minutesText(minutes)) left in the book")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var comicPageTotal: Int {
        max(model.totalPages, model.comicPages.count)
    }

    private var comicCurrentPageIndex: Int {
        let maxIndex = max(0, comicPageTotal - 1)
        return min(max(0, model.currentComicPageIndex), maxIndex)
    }

    private var comicStatusLine: String {
        let displayIndex = min(max(0, comicScrubTargetIndex ?? comicCurrentPageIndex), max(0, comicPageTotal - 1))
        let progress = comicPageTotal > 1 ? Double(displayIndex) / Double(comicPageTotal - 1) : 1
        return "Page \(displayIndex + 1) of \(comicPageTotal) · \(Int(progress * 100))%"
    }

    private var isComicAtEnd: Bool {
        comicPageTotal > 0 && comicCurrentPageIndex >= comicPageTotal - 1
    }

    private var showsNextSeriesPrompt: Bool {
        model.appearance.showNextSeriesPrompt
            && isReaderAtEnd
            && nextSeriesIssue != nil
            && !dismissedNextSeriesPrompt
    }

    private var nextSeriesPromptAlignment: Alignment {
        model.appearance.nextSeriesPromptPlacement == .top ? .top : .bottom
    }

    private var nextSeriesPromptPaddingEdge: Edge.Set {
        model.appearance.nextSeriesPromptPlacement == .top ? .top : .bottom
    }

    private var nextSeriesPromptTransitionEdge: Edge {
        model.appearance.nextSeriesPromptPlacement == .top ? .top : .bottom
    }

    private var isReaderAtEnd: Bool {
        if isComicBook(book) {
            return isComicAtEnd
        }
        return (model.currentProgress ?? book.canonicalEbookProgress) >= 0.985
    }

    private var showsFullHeightTapZones: Bool {
        !chromeVisible
            && model.state.isReady
            && model.appearance.tapEdgesTurnPages
            && model.pendingSelection == nil
            && !model.isReadAloudMode
    }

    private func turnPageFromLeftEdge() {
        Task {
            if model.isRightToLeftPageProgression {
                await model.pageForward()
            } else {
                await model.pageBackward()
            }
        }
    }

    private func turnPageFromRightEdge() {
        Task {
            if model.isRightToLeftPageProgression {
                await model.pageBackward()
            } else {
                await model.pageForward()
            }
        }
    }

    private var nextSeriesPromptTitle: String {
        isComicBook(book) ? "Read the next issue?" : "Read the next book?"
    }

    private static func minutesText(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }

    private var ribbonTicks: [Double] {
        guard isEPUB else { return [] }
        let ticks = Array(Set(model.tocTickProgressions)).sorted()
        return ticks.count <= 60 ? ticks : []
    }

    @ViewBuilder
    private var floatingPills: some View {
        VStack(spacing: 10) {
            if !chromeVisible, readAloudControlsVisible, model.isReadAloudMode, model.overlayPlayer != nil {
                ReaderNarratePill(
                    model: model,
                    onBookmark: { bookmarkDraft = makeBookmarkDraft(readAloud: true) },
                    onPlaybackToggle: { showReadAloudControls(autoHide: true) },
                    onMore: { showDetailedReadAloudControls() }
                )
            }
            if !chromeVisible,
                ttsControlsVisible,
                model.ttsService.isPlaying || model.ttsService.isPaused
            {
                ReaderTTSPill(tts: model.ttsService) {
                    showTTSControls(autoHide: true)
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: model.isReadAloudMode)
    }

    private func annotateLayer(_ selection: ReaderSelectionSnapshot) -> some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissPendingSelection)

                ReaderAnnotateBar(
                    selectedColor: $inkColor,
                    onHighlight: { color in
                        inkColor = color
                        model.annotationController.addAnnotationFromSelection(style: .highlight, colorHex: color)
                        PlatformHaptics.impact(.light)
                    },
                    onUnderline: {
                        model.annotationController.addAnnotationFromSelection(style: .underline, colorHex: inkColor)
                        PlatformHaptics.impact(.light)
                    },
                    onStrikethrough: {
                        model.annotationController.addAnnotationFromSelection(style: .strikethrough, colorHex: inkColor)
                        PlatformHaptics.impact(.light)
                    },
                    onSquiggle: {
                        model.annotationController.addAnnotationFromSelection(style: .squiggly, colorHex: inkColor)
                        PlatformHaptics.impact(.light)
                    },
                    onNote: {
                        let current = currentEPUBSelection(fallback: selection)
                        noteDraft = ReaderNoteDraft(text: current.locator.text.highlight ?? "")
                    },
                    onCopy: { copySelection(currentEPUBSelection(fallback: selection)) },
                    onDefine: { handleDefine() }
                )
                .position(annotateBarPosition(for: selection.frame, in: geo.size))
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private func annotateBarPosition(for frame: CGRect?, in size: CGSize) -> CGPoint {
        let compact = size.width < 390
        let barWidth = min(size.width - 24, compact ? 348 : 500)
        let halfWidth = barWidth / 2
        let sideInset = (size.width - barWidth) / 2
        let barOffset: CGFloat = 54
        guard let frame, frame != .zero else {
            return CGPoint(x: size.width / 2, y: size.height - 140)
        }
        let x = min(max(frame.midX, sideInset + halfWidth), size.width - sideInset - halfWidth)
        let above = frame.minY - barOffset
        let y = above > 90 ? above : min(frame.maxY + barOffset, size.height - 110)
        return CGPoint(x: x, y: y)
    }

    private func readerOpenLibrarian() {
        if let message = EnveLibrarianService.shared.availabilityMessage() {
            librarianMessage = message
            return
        }
        showingLibrarian = true
    }

    private func handleDefine() {
        guard let entry = model.annotationController.vocabEntryFromSelection() else {
            dismissPendingSelection()
            return
        }
        let shouldAutoSave = LibraryDisplayPreferencesStore.shared.loadPreferences().vocabAutoLogLookups
        if shouldAutoSave {
            model.annotationController.saveVocab(entry)
        }
        defineRequest = ReaderDefineRequest(term: entry.word, vocabEntry: entry, initiallySaved: shouldAutoSave)
        dismissPendingSelection()
    }

    private func copySelection(_ selection: ReaderSelectionSnapshot) {
        let text = selection.locator.text.highlight?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            dismissPendingSelection()
            return
        }
        UIPasteboard.general.string = text
        PlatformHaptics.impact(.light)
        dismissPendingSelection()
    }

    private func currentEPUBSelection(
        fallback selection: ReaderSelectionSnapshot
    ) -> ReaderSelectionSnapshot {
        model.activeReaderEngineAdapter?.currentSelection ?? selection
    }

    private func dismissPendingSelection() {
        model.activeReaderEngineAdapter?.clearSelection()
        model.pendingSelection = nil
    }

    private func saveNote(draft: ReaderNoteDraft, note: String?) {
        if model.pendingSelection != nil {
            model.annotationController.addAnnotationFromSelection(style: .highlight, colorHex: inkColor, note: note)
        } else if !draft.text.isEmpty {
            model.annotationController.addAnnotation(text: draft.text, note: note, style: .highlight, colorHex: inkColor)
        }
        PlatformHaptics.impact(.light)
        dismissPendingSelection()
    }

    private func makeBookmarkDraft(readAloud: Bool) -> ReaderBookmarkDraft {
        ReaderBookmarkDraft(
            context: model.annotationSummaryText,
            readAloud: readAloud
        )
    }

    private func saveBookmark(draft: ReaderBookmarkDraft, note: String?) {
        if draft.readAloud {
            model.addReadAloudBookmark(note: note)
        } else {
            model.annotationController.addBookmark(note: note)
        }
        PlatformHaptics.impact(.light)
        showBookmarkToast(note == nil ? "Bookmark saved" : "Bookmark saved with note")
    }

    private func showBookmarkToast(_ message: String) {
        bookmarkToastTask?.cancel()
        bookmarkToast = message
        bookmarkToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.0))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) {
                bookmarkToast = nil
            }
        }
    }

    private func handleTap(_ point: CGPoint, viewSize size: CGSize) {
        initialChromeHideTask?.cancel()
        if model.isReadAloudMode, model.overlayPlayer != nil {
            if chromeVisible {
                hideReadAloudControls()
                withAnimation(.smooth(duration: 0.35)) {
                    chromeVisible = false
                }
            } else if readAloudControlsVisible {
                hideReadAloudControls()
            } else {
                showReadAloudControls(autoHide: true)
            }
            return
        }

        guard size.width > 0, model.appearance.tapEdgesTurnPages else {
            toggleChrome()
            return
        }
        let leftEdge = size.width * 0.13
        let rightEdge = size.width * 0.87
        if point.x < leftEdge {
            Task {
                if model.isRightToLeftPageProgression {
                    await model.pageForward()
                } else {
                    await model.pageBackward()
                }
            }
        } else if point.x > rightEdge {
            Task {
                if model.isRightToLeftPageProgression {
                    await model.pageBackward()
                } else {
                    await model.pageForward()
                }
            }
        } else {
            if chromeVisible {
                toggleChrome()
                if model.ttsService.isPlaying || model.ttsService.isPaused {
                    showTTSControls(autoHide: true)
                }
            } else if model.ttsService.isPlaying || model.ttsService.isPaused {
                if ttsControlsVisible {
                    hideTTSControls()
                } else {
                    showTTSControls(autoHide: true)
                }
            } else {
                toggleChrome()
            }
        }
    }

    private var pdfPageTurnGesture: some Gesture {
        DragGesture(minimumDistance: 28, coordinateSpace: .local)
            .onEnded { value in
                guard case .readyPDF = model.state, !model.appearance.pdfScrollEnabled else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > 48, abs(dx) > abs(dy) * 1.2 else { return }
                Task {
                    if dx < 0 {
                        if model.isRightToLeftPageProgression {
                            await model.pageBackward()
                        } else {
                            await model.pageForward()
                        }
                    } else {
                        if model.isRightToLeftPageProgression {
                            await model.pageForward()
                        } else {
                            await model.pageBackward()
                        }
                    }
                }
            }
    }

    private func toggleChrome() {
        initialChromeHideTask?.cancel()
        withAnimation(.smooth(duration: 0.35)) {
            chromeVisible.toggle()
        }
    }

    private func showReadAloudControls(autoHide: Bool) {
        readAloudControlsHideTask?.cancel()
        withAnimation(.smooth(duration: 0.25)) {
            readAloudControlsVisible = true
        }
        guard autoHide else { return }
        readAloudControlsHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.0))
            guard !Task.isCancelled,
                model.overlayPlayer?.isPlaying == true,
                tray == nil,
                bookmarkDraft == nil
            else { return }
            withAnimation(.smooth(duration: 0.25)) {
                readAloudControlsVisible = false
            }
        }
    }

    private func hideReadAloudControls() {
        readAloudControlsHideTask?.cancel()
        withAnimation(.smooth(duration: 0.25)) {
            readAloudControlsVisible = false
        }
    }

    private func showTTSControls(autoHide: Bool) {
        guard !ttsControlsVisible else { return }
        withAnimation(.smooth(duration: 0.25)) {
            ttsControlsVisible = true
        }
        guard autoHide else { return }
        let token = UUID()
        ttsControlsHideToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard token == ttsControlsHideToken else { return }
            withAnimation(.smooth(duration: 0.25)) {
                ttsControlsVisible = false
            }
        }
    }

    private func hideTTSControls() {
        ttsControlsHideToken = UUID()
        withAnimation(.smooth(duration: 0.25)) {
            ttsControlsVisible = false
        }
    }

    private func showDetailedReadAloudControls() {
        hideReadAloudControls()
        withAnimation(.smooth(duration: 0.35)) {
            chromeVisible = true
        }
    }

    private func beginSession() {
        model.updateSystemColorScheme(colorScheme)
        LastOpenedBookStore.shared.record(book)
        model.tapHandler = { handleTap($0, viewSize: $1) }
        model.doubleTapHandler = { [weak model] point in
            model?.handleReaderDoubleTap(at: point)
        }
        NotificationCenter.default.post(name: .ebookReaderPresented, object: nil)
        model.startIfNeeded()
        model.sessionStartDate = Date()
        model.sessionStartProgress = model.currentProgress ?? book.canonicalEbookProgress
        Task {
            await ReadingStatsTracker.shared.startSession(
                bookId: book.stableId,
                positionProgression: model.currentProgress ?? 0,
                location: model.currentSectionTitle
            )
        }
        Task { await HardcoverSyncService.shared.syncBookStarted(book: book) }
        Task {

            await SyncCoordinator.shared.pullOnOpen(
                book: book,
                domain: .ebook,
                excludingProvider: book.source == .storyteller
            )
            if EbookConflictStore.shared.contains(stableId: book.stableId) {
                showingConflict = true
            }
        }
        model.startAutoSaveTimer()
        Task { await model.annotationController.syncNotebookEntriesIfNeeded() }
        Task {
            await EbookAudiobookLinker.shared.rebuildCacheIfNeeded()
            linkedAudiobook = await EbookAudiobookLinker.shared.linkedAudiobookAsync(for: book)
        }
        Task { nextSeriesIssue = await findNextSeriesIssue() }
    }

    private func endSession() {
        bookmarkToastTask?.cancel()
        initialChromeHideTask?.cancel()
        readAloudControlsHideTask?.cancel()
        model.tapHandler = nil
        model.doubleTapHandler = nil
        NotificationCenter.default.post(name: .ebookReaderDismissed, object: nil)
        readerSyncAudiobookOnDismissIfNeeded()
        let wasReadAloud = model.isReadAloudMode && model.overlayPlayer != nil
        if wasReadAloud {
            model.flushProgressToServer(reason: "close")
        } else {
            model.saveProgress()
            model.flushProgressToServer(reason: "close")
        }
        model.cleanupOverlayPlayer()
        model.ttsService.tearDown()
        model.flushPendingAppearanceUpdate()
        model.stopAutoSaveTimer()
        model.endServerPageStreamingSession()
        model.saveReadingSpeedRecord()

        let progress = model.currentProgress ?? 0
        if progress >= 0.99 {
            Task {
                await HardcoverSyncService.shared.syncBookFinished(book: book)
                if LibraryDisplayPreferencesStore.shared.loadPreferences().autoDeleteFinishedBooks,
                    book.source != .local
                {
                    try? LocalEbookImporter.shared.deleteRemoteEbookArtifacts(forBookId: book.id)
                    AppState.shared.mutateBook(uniqueId: book.uniqueId) { $0.ebookFileURL = nil }
                }
            }
        } else if progress > 0 {
            Task { await HardcoverSyncService.shared.syncProgress(book: book, progress: progress) }
        }

        if book.source == .booklore {
            let capturedBook = book
            let startDate = model.sessionStartDate
            let startProgress = model.sessionStartProgress
            let locatorJSON = model.lastKnownLocatorJSON
            var bgTaskId: UIBackgroundTaskIdentifier = .invalid
            bgTaskId = UIApplication.shared.beginBackgroundTask {
                UIApplication.shared.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
            }
            Task {
                defer {
                    if bgTaskId != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTaskId)
                    }
                }
                guard let provider = AppState.shared.getProvider(capturedBook.providerId) as? BookloreProvider else { return }
                try? await provider.uploadEbookReadingSession(
                    for: capturedBook,
                    startDate: startDate,
                    startProgress: startProgress,
                    endProgress: progress,
                    epubLocator: locatorJSON
                )
            }
        }

        Task {
            await ReadingStatsTracker.shared.endSession(
                bookId: book.stableId,
                finalProgression: model.currentProgress,
                location: model.currentSectionTitle
            )
        }
    }

    private func readerSyncAudiobookOnDismissIfNeeded() {
        guard !book.isReadAloudBook, book.epub3Features?.hasMediaOverlay != true else { return }
        let playback = ActivePlayback.controller
        guard let audiobook = linkedAudiobook,
            playback.snapshot.currentBook?.stableId == audiobook.stableId,
            !playback.snapshot.isPlaying
        else { return }
        guard let chapterIndex = model.currentChapterIndex,
            let seekTime = EbookAudiobookLinker.shared.audiobookTimeForEbookChapter(chapterIndex, ebook: book)
        else { return }
        playback.seek(to: seekTime)
    }

    private func findNextSeriesIssue() async -> Book? {
        guard book.mediaType == .ebook, let series = book.series else { return nil }
        let siblings = DetailSeriesOrder.sorted(await AppState.shared.bookStore.books(inSeries: series))
            .filter { $0.mediaType == .ebook && (!isComicBook(book) || isComicBook($0)) }
        guard let currentIndex = siblings.firstIndex(where: { $0.stableId == book.stableId }) else {
            return nil
        }
        return siblings.dropFirst(currentIndex + 1).first
    }

    private func openNextIssue(_ issue: Book) {
        model.saveProgress()
        dismissedNextSeriesPrompt = true
        PlatformHaptics.selection()
        AppState.shared.presentation.selectedEbookForDetail = issue
    }

    private func dismissNextSeriesPrompt() {
        dismissedNextSeriesPrompt = true
        PlatformHaptics.impact(.light)
    }

    private func isComicBook(_ book: Book) -> Bool {
        if let format = book.ebookFormat?.lowercased(), ["cbz", "cbr", "cb7", "cbt"].contains(format) {
            return true
        }
        guard let ext = book.ebookFileURL?.pathExtension.lowercased() else { return false }
        return ["cbz", "cbr", "cb7", "cbt"].contains(ext)
    }
}

private enum ReaderTray: String, Identifiable {
    case contents, appearance, search, tts, readAloud, export
    var id: String { rawValue }
}

private struct ReaderNoteDraft: Identifiable {
    let id = UUID()
    let text: String
}

private struct ReaderFooterProgressPill: View {
    let progress: Double
    let tint: SwiftUI.Color
    let ticks: [Double]
    let statusLine: String?
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(spacing: 7) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(trackColor)
                        .frame(height: 5)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, geo.size.width * clamped), height: 5)
                    ForEach(ticks.filter { $0 > 0.005 && $0 < 0.995 }, id: \.self) { tick in
                        Rectangle()
                            .fill(hearth.bgElevated.opacity(0.9))
                            .frame(width: 1.5, height: 5)
                            .offset(x: geo.size.width * tick)
                    }
                    Circle()
                        .fill(tint)
                        .stroke(hearth.bgElevated, lineWidth: 2)
                        .frame(width: 13, height: 13)
                        .offset(x: thumbOffset(width: geo.size.width))
                }
                .frame(maxHeight: .infinity)
                Slider(
                    value: Binding(
                        get: { clamped },
                        set: { onScrub($0) }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing {
                            onCommit(clamped)
                        }
                    }
                )
                .labelsHidden()
                .opacity(0.01)
                .accessibilityLabel("Reading progress")
                .accessibilityValue(statusLine ?? "\(Int(clamped * 100)) percent")
                .accessibilityIdentifier("reader-progress-slider")
            }
            .frame(height: 20)

            if let statusLine {
                Text(statusLine)
                    .font(.hearthUI(13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background {
            HearthChromeBackground(
                shape: .capsule,
                fill: hearth.bgElevated.opacity(hearth.isInk ? 0.92 : 0.96),
                stroke: hearth.hairline,
                tint: tint,
                interactive: false,
                shadow: true
            )
        }
    }

    private var clamped: Double {
        min(max(progress, 0), 1)
    }

    private var trackColor: SwiftUI.Color {
        hearth.isInk ? .white.opacity(0.24) : .black.opacity(0.16)
    }

    private func thumbOffset(width: CGFloat) -> CGFloat {
        let diameter: CGFloat = 13
        return (width - diameter) * clamped
    }
}

private struct ReaderBookmarkDraft: Identifiable {
    let id = UUID()
    let context: String
    let readAloud: Bool
}

private struct ReaderDefineRequest: Identifiable {
    let id = UUID()
    let term: String
    let vocabEntry: VocabEntry?
    let initiallySaved: Bool
}

private struct ReaderToast: View {
    let message: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill")
                .font(.hearthUI(13, weight: .semibold))
            Text(message)
                .font(.hearthUI(13, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(hearth.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            HearthChromeBackground(
                shape: .capsule,
                fill: hearth.bgElevated,
                stroke: hearth.hairline,
                tint: hearth.bgElevated,
                shadow: true
            )
        }
    }
}

private struct ReaderNextSeriesPrompt: View {
    let book: Book
    let title: String
    let tint: SwiftUI.Color
    let onDismiss: () -> Void
    let onReadNext: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.hearthUI(18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Overline("Finished")
                    Text(title)
                        .font(.hearthDisplay(20, weight: .semibold))
                        .foregroundStyle(hearth.text)
                    Text(book.title)
                        .font(.hearthUI(13, weight: .medium))
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.hearthUI(12, weight: .semibold))
                        .foregroundStyle(hearth.textSecondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Dismiss next issue")
            }

            HStack(spacing: 10) {
                EmberButton(title: "Read next", systemImage: "arrow.forward.circle.fill", tint: tint, action: onReadNext)
                QuietButton(title: "Not now", systemImage: "clock", action: onDismiss)
            }
        }
        .padding(18)
        .background {
            HearthChromeBackground(
                shape: .rounded(Hearth.radiusCard),
                fill: hearth.bgElevated.opacity(hearth.isInk ? 0.94 : 0.98),
                stroke: hearth.hairline,
                tint: tint,
                shadow: true
            )
        }
    }
}

private struct ComicPageScrubber: View {
    let currentIndex: Int
    let targetIndex: Int?
    let totalPages: Int
    let isRightToLeft: Bool
    let tint: SwiftUI.Color
    let onScrub: (Int) -> Void
    let onCommit: (Int) -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.shellNavigationStyle) private var shellNavigationStyle

    var body: some View {
        GeometryReader { geo in
            let activeIndex = bounded(targetIndex ?? currentIndex)
            let readingProgress = progress(for: activeIndex)
            let thumbX = thumbPosition(for: activeIndex, width: geo.size.width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                    .frame(height: 4)
                Capsule()
                    .fill(tint)
                    .frame(width: max(4, geo.size.width * readingProgress), height: 4)
                    .frame(maxWidth: .infinity, alignment: isRightToLeft ? .trailing : .leading)
                Circle()
                    .fill(shellNavigationStyle == .liquidGlass ? hearth.bgElevated.opacity(0.42) : hearth.bgElevated)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(tint, lineWidth: 3))
                    .shadow(color: .black.opacity(hearth.isInk ? 0.28 : 0.12), radius: 8, y: 3)
                    .position(x: thumbX, y: geo.size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrub(index(for: value.location.x, width: geo.size.width))
                    }
                    .onEnded { value in
                        onCommit(index(for: value.location.x, width: geo.size.width))
                    }
            )
        }
        .frame(height: 28)
        .accessibilityLabel("Page scrubber")
        .accessibilityValue("Page \(bounded(targetIndex ?? currentIndex) + 1) of \(totalPages)")
    }

    private var trackColor: SwiftUI.Color {
        hearth.isInk ? .white.opacity(0.14) : .black.opacity(0.10)
    }

    private func bounded(_ index: Int) -> Int {
        min(max(0, index), max(0, totalPages - 1))
    }

    private func progress(for index: Int) -> Double {
        guard totalPages > 1 else { return 0 }
        return Double(bounded(index)) / Double(totalPages - 1)
    }

    private func thumbPosition(for index: Int, width: CGFloat) -> CGFloat {
        guard totalPages > 1 else { return width / 2 }
        let visualProgress = isRightToLeft ? 1 - progress(for: index) : progress(for: index)
        return min(max(9, width * visualProgress), max(9, width - 9))
    }

    private func index(for x: CGFloat, width: CGFloat) -> Int {
        guard width > 0, totalPages > 1 else { return 0 }
        let visualProgress = min(max(0, x / width), 1)
        let readingProgress = isRightToLeft ? 1 - visualProgress : visualProgress
        return bounded(Int((readingProgress * Double(totalPages - 1)).rounded()))
    }
}

private struct ReaderReadAloudBar: View {
    @ObservedObject var model: ClassicReaderModel
    @ObservedObject var player: MediaOverlayPlayer
    let onBookmark: () -> Void
    let onSettings: () -> Void
    let onStop: () -> Void

    @Environment(\.hearth) private var hearth

    private let speeds = ReaderCompanionSnapshot.readAloudSpeeds

    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.periodic(from: Date(), by: 0.5)) { _ in
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        let progress = readAloudProgress
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(hearth.text.opacity(0.12))
                                .frame(height: 4)
                            Capsule()
                                .fill(hearth.ember)
                                .frame(width: geo.size.width * progress, height: 4)
                                .animation(.easeInOut(duration: 0.25), value: progress)
                        }
                    }
                    .frame(height: 4)

                    HStack {
                        Text(timeText(player.currentTime))
                        Spacer()
                        Text(timeText(player.totalDuration))
                    }
                    .font(.hearthUI(11, weight: .medium).monospacedDigit())
                    .foregroundStyle(hearth.textSecondary)
                }
            }

            HStack(spacing: 8) {
                readAloudIconButton("backward.end.fill", label: "Previous Read Aloud segment") {
                    model.previousReadAloudSegment()
                }
                .accessibilityIdentifier("Reader.ReadAloud.Previous")

                readAloudIconButton("gobackward.15", label: "Rewind Read Aloud 15 seconds") {
                    model.skipReadAloudBackward()
                }

                Button {
                    model.toggleReadAloudPlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.hearthUI(17, weight: .bold))
                        .foregroundStyle(hearth.bg)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(hearth.ember))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(player.isPlaying ? "Pause Read Aloud" : "Play Read Aloud")
                .accessibilityIdentifier("Reader.ReadAloud.PlayPause")

                readAloudIconButton("goforward.30", label: "Skip Read Aloud 30 seconds") {
                    model.skipReadAloudForward()
                }

                readAloudIconButton("forward.end.fill", label: "Next Read Aloud segment") {
                    model.nextReadAloudSegment()
                }
                .accessibilityIdentifier("Reader.ReadAloud.Next")
            }

            HStack(spacing: 8) {
                readAloudIconButton("bookmark", label: "Bookmark current Read Aloud position") {
                    onBookmark()
                }

                readAloudIconButton("arrow.triangle.2.circlepath", label: "Sync audio to visible page") {
                    model.syncAudioToVisiblePage()
                }

                readAloudIconButton(
                    model.appearance.readAloudHighlightEnabled ? "eye.slash" : "eye",
                    label: model.appearance.readAloudHighlightEnabled ? "Hide Read Aloud highlight" : "Show Read Aloud highlight"
                ) {
                    model.toggleReadAloudHighlighting()
                }

                speedMenu

                readAloudIconButton("slider.horizontal.3", label: "Read Aloud settings") {
                    onSettings()
                }

                readAloudIconButton("xmark", label: "Stop Read Aloud") {
                    onStop()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            HearthChromeBackground(
                shape: .rounded(22),
                fill: hearth.bgElevated,
                stroke: hearth.hairline,
                tint: hearth.bgElevated,
                shadow: true
            )
        }
        .accessibilityIdentifier("Reader.ReadAloud")
    }

    private var speedMenu: some View {
        Menu {
            Section("Speed") {
                ForEach(speeds, id: \.self) { speed in
                    Button {
                        model.setReadAloudSpeed(speed)
                    } label: {
                        checkedMenuLabel(speedLabel(speed), isChecked: abs(player.playbackRate - speed) < 0.01)
                    }
                }
            }
            Section {
                Button {
                    model.toggleReadAloudHighlighting()
                } label: {
                    checkedMenuLabel("Highlight Words", isChecked: model.appearance.readAloudHighlightEnabled)
                }
                Button {
                    model.toggleReadAloudSkipSkippables()
                } label: {
                    checkedMenuLabel("Skip Footnotes & Sidebars", isChecked: player.skipSkippables)
                }
            }
        } label: {
            Text(speedLabel(player.playbackRate))
                .font(.hearthUI(12, weight: .bold).monospacedDigit())
                .foregroundStyle(hearth.text)
                .frame(minWidth: 50, minHeight: 34)
                .padding(.horizontal, 2)
                .background {
                    Capsule()
                        .fill(hearth.text.opacity(0.10))
                }
        }
        .accessibilityLabel("Read Aloud speed")
        .accessibilityIdentifier("Reader.ReadAloud.Speed")
    }

    @ViewBuilder
    private func checkedMenuLabel(_ title: String, isChecked: Bool) -> some View {
        if isChecked {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func readAloudIconButton(
        _ systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.hearthUI(14, weight: .semibold))
                .foregroundStyle(hearth.text)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    private var readAloudProgress: Double {
        if player.totalDuration > 0 {
            return min(max(player.currentTime / player.totalDuration, 0), 1)
        }
        guard model.overlayClipCount > 0 else { return 0 }
        return min(max(Double(player.currentClipIndex) / Double(model.overlayClipCount), 0), 1)
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds / 60) % 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func speedLabel(_ speed: Double) -> String {
        String(format: "%.2gx", speed)
    }
}

private struct ReaderNarratePill: View {
    @ObservedObject var model: ClassicReaderModel
    let onBookmark: () -> Void
    let onPlaybackToggle: () -> Void
    let onMore: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 4) {
            narrateButton("gobackward.15", label: "Rewind Read Aloud 15 seconds") {
                model.skipReadAloudBackward()
            }
            narrateButton(
                model.overlayPlayer?.isPlaying == true ? "pause.fill" : "play.fill",
                label: model.overlayPlayer?.isPlaying == true ? "Pause Read Aloud" : "Play Read Aloud",
                primary: true
            ) {
                model.toggleReadAloudPlayback()
                onPlaybackToggle()
            }
            narrateButton("goforward.30", label: "Skip Read Aloud 30 seconds") {
                model.skipReadAloudForward()
            }
            narrateButton("bookmark", label: "Bookmark current Read Aloud position") {
                onBookmark()
            }
            narrateButton("ellipsis", label: "Show Read Aloud controls") {
                onMore()
            }
        }
        .padding(.horizontal, 8)
        .background {
            HearthChromeBackground(
                shape: .capsule,
                fill: hearth.bgElevated,
                stroke: hearth.hairline,
                tint: hearth.bgElevated,
                shadow: true
            )
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func narrateButton(
        _ systemImage: String,
        label: String,
        primary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.hearthUI(primary ? 15 : 13, weight: .semibold))
                .foregroundStyle(primary ? hearth.text : hearth.textSecondary)
                .frame(width: 38, height: 42)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

private struct ReaderTTSPill: View {
    @ObservedObject var tts: EbookTTSService
    let onInteraction: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        if tts.isPlaying || tts.isPaused {
            HStack(spacing: 6) {
                Button {
                    onInteraction()
                    tts.togglePlayPause()
                } label: {
                    Image(systemName: tts.isPlaying && !tts.isPaused ? "pause.fill" : "play.fill")
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(tts.isPlaying && !tts.isPaused ? "Pause reading aloud" : "Resume reading aloud")
                Overline(tts.isPaused ? "Paused" : "Reading to you", color: hearth.text)
                Button {
                    onInteraction()
                    tts.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.hearthUI(13, weight: .semibold))
                        .foregroundStyle(hearth.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Stop reading aloud")
            }
            .padding(.horizontal, 10)
            .background {
                HearthChromeBackground(
                    shape: .capsule,
                    fill: hearth.bgElevated,
                    stroke: hearth.hairline,
                    tint: hearth.bgElevated,
                    shadow: true
                )
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
