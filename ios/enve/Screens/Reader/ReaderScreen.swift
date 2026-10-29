import Combine
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import SwiftUI
import UIKit
import WebKit

struct ReaderScreen: View {
    let book: Book

    private let profileSession: ProfileSession
    private var engine: EnveEngine { profileSession.engine }
    @StateObject private var model: ClassicReaderModel
    @Environment(\.hearth) private var inheritedHearth
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.shellNavigationStyle) private var shellNavigationStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let hinge = HingeStateStore.shared

    @State private var canvasSize: CGSize = .zero
    @State private var canvasFold: FoldLine?
    @State private var sideColumn: SideColumn?
    @State private var chromeVisible = false
    @State private var tray: ReaderTray?
    @State private var ambient: SwiftUI.Color = Hearth.accent
    @State private var inkColor = "#FFF59D"
    @State private var noteDraft: ReaderNoteDraft?
    @State private var bookmarkDraft: ReaderBookmarkDraft?
    @State private var bookmarkToast: String?
    @State private var bookmarkToastTask: Task<Void, Never>?
    @State private var readAloudControlsVisible = false
    @State private var readAloudControlsHideTask: Task<Void, Never>?
    @State private var ttsControlsVisible = false
    @State private var ttsControlsPresentedForSession = false
    @State private var initialChromeHideTask: Task<Void, Never>?
    @State private var ttsControlsHideTask: Task<Void, Never>?
    @State private var defineRequest: ReaderDefineRequest?
    @State private var progressConflict: EbookSyncConflict?
    @State private var linkedAudiobook: Book?
    @State private var showingLibrarian = false
    @State private var librarianMessage: String?
    @State private var comicScrubTargetIndex: Int?
    @State private var epubScrubProgress: Double?
    @State private var nextSeriesIssue: Book?
    @State private var dismissedNextSeriesPrompt = false
    @State private var restReminder = ReaderRestReminder()
    @State private var restPromptShowsSettingsHint = false
    @State private var showingRestReminderSettings = false
    #if DEBUG
    @State private var footnoteFixtureTriggered = false
    @State private var readAloudFixtureTriggered = false
    @State private var ttsPlaybackFixtureTriggered = false
    @State private var readerFontProbe: String?
    #endif

    init(book: Book, providerResolver: any LibraryProviderResolving, profileSession: ProfileSession = .owner) {
        self.profileSession = profileSession
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
                providerResolver: providerResolver,
                profileSession: profileSession
            )
        )
    }

    private var hearth: HearthPalette {
        let scheme = model.preferredColorScheme ?? colorScheme
        guard inheritedHearth.isInk != (scheme == .dark) else { return inheritedHearth }
        return Hearth.palette(
            for: scheme,
            oled: Hearth.oledEnabled,
            highContrast: ThemeManager.shared.isVisionMode || colorSchemeContrast == .increased,
            reduceTransparency: reduceTransparency
        )
    }

    var body: some View {
        readerLifecycle
            .environment(\.hearth, hearth)
            .environment(\.colorScheme, model.preferredColorScheme ?? colorScheme)
    }

    private var readerCanvas: some View {
        let lectern = lecternHalves
        // The page keeps one place in the tree whatever the pose, so folding the phone resizes the engine's
        // view above the controls instead of rebuilding it and losing its position.
        return ZStack {
            backdrop
            if let lectern {
                HearthSpineShadow(axis: .horizontal, depth: 1)
                    .frame(height: 84)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .offset(y: lectern.foldCenter - 42)
                    .ignoresSafeArea(edges: .horizontal)
            }
            ZStack {
                content
                if showsSpine {
                    HearthSpineShadow(axis: .vertical, depth: hinge.spineDepth(flat: 0.45))
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
                readerDimmer
            }
            .frame(height: lectern?.upperHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onGeometryChange(for: ReaderCanvasGeometry.self) {
            ReaderCanvasGeometry(size: $0.size, column: $0.hearthSideColumn(), fold: $0.hearthFold())
        } action: { geometry in
            canvasSize = geometry.size
            sideColumn = geometry.column
            var fold = geometry.fold
            #if DEBUG
            fold = fold ?? hinge.debugFold(canvas: geometry.size)
            #endif
            canvasFold = fold
        }
        .onChange(of: showsSpine, initial: true) { _, spread in
            model.setSpreadRequested(spread)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: showsSpine)
        .accessibilityIdentifier("reader-screen")
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if let readerFontProbe {
                Text(readerFontProbe)
                    .font(.caption2)
                    .opacity(0.01)
                    .accessibilityIdentifier("reader-font-probe")
            }
        }
        #endif
        .overlay(alignment: .top) {
            if chromeVisible, model.state.isReady {
                topVeil
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let lectern = lecternHalves {
                lecternPanel
                    .frame(height: lectern.lowerHeight)
            } else if chromeVisible, model.state.isReady {
                bottomVeil
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if chromeVisible, model.state.isReady, let column = chromeColumn {
                sideChrome(column: column)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if model.pendingSelection == nil || model.isReadAloudMode {
                floatingPills
                    .padding(.bottom, floatingPillsInset)
            }
        }
        .overlay(alignment: .top) {
            if model.isReadTogetherActive {
                ReaderTogetherBanner {
                    Task { await model.stopReadTogether() }
                }
                .padding(.top, (chromeVisible ? 64 : 8) + topChromeClearance)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlayPreferenceValue(ReaderNarrationControlsBoundsKey.self) { narrationBounds in
            if let selection = model.pendingSelection {
                annotateLayer(selection, narrationBounds: narrationBounds)
            }
        }
        .overlay {
            VolumeButtonNavigationCapture(
                isEnabled: model.appearance.volumeButtonsTurnPages && model.presentedIllustration == nil,
                onIncrease: { Task { await model.pageForward() } },
                onDecrease: { Task { await model.pageBackward() } }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
        .overlay {
            if model.presentedIllustration == nil {
                ReaderKeyboardNavigationCapture(
                    isRightToLeft: model.isRightToLeftPageProgression,
                    onForward: { Task { await model.pageForward() } },
                    onBackward: { Task { await model.pageBackward() } }
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
            }
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
                    .padding(.top, 72 + topChromeClearance)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if let preview = model.pinchResizePreview {
                ReaderPinchResizeBadge(fontSize: preview)
                    .padding(.top, 72 + topChromeClearance)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .overlay {
            if restReminder.isDue {
                ReaderRestPrompt(
                    minutes: restReminder.minutes,
                    colors: restPromptColors,
                    showsSettingsHint: restPromptShowsSettingsHint,
                    onOpenSettings: {
                        restReminder.dismiss()
                        showingRestReminderSettings = true
                    },
                    onDismiss: { restReminder.dismiss() }
                )
                .padding(.horizontal, 18)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
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
        .animation(.smooth(duration: 0.3), value: restReminder.isDue)
        .animation(.smooth(duration: 0.2), value: model.pinchResizePreview != nil)
    }

    private var readerNavigation: some View {
        readerCanvas
        .sheet(
            item: Binding(
                get: { model.annotationController.editingAnnotation },
                set: { model.annotationController.editingAnnotation = $0 }
            )
        ) { annotation in
            ReaderAnnotationEditorSheet(
                annotation: annotation,
                onSave: { style, color, note in
                    model.annotationController.updateAnnotation(
                        annotation,
                        style: style,
                        colorHex: color,
                        note: note,
                        replaceNote: true
                    )
                    PlatformHaptics.impact(.light)
                },
                onRemove: { model.annotationController.removeAnnotation(annotation) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .hearthPresentationBackground()
            .enveEnvironment()
        }
        .sheet(isPresented: $showingRestReminderSettings) {
            NavigationStack {
                RestReminderSettingsScreen(
                    appearance: Binding(get: { model.appearance }, set: { model.appearance = $0 })
                )
            }
            .enveEnvironment()
        }
        // Explicit captures avoid the reproduced iOS 17 sheet update loop.
        .sheet(item: $tray) { [model, ambient, book] presented in
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
        .fullScreenCover(
            item: Binding(
                get: { model.presentedIllustration },
                set: { if $0 == nil { model.dismissIllustration() } }
            )
        ) { [model] illustration in
            ReaderImageViewer(
                illustration: illustration,
                backdrop: model.effectiveAppearance.theme == .eink ? .white : .black,
                onDismiss: { model.dismissIllustration() }
            )
            .preferredColorScheme(model.preferredColorScheme)
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
    }

    private var readerEditors: some View {
        readerNavigation
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
        .sheet(item: $progressConflict) { conflict in
            ReaderProgressConflictSheet(
                book: book,
                conflict: conflict,
                onKeepLocal: {
                    profileSession.sync.resolveEbookConflict(bookStableId: book.stableId, useServer: false)
                },
                onUseRemote: {
                    let serverLocator = conflict.serverLocator
                    profileSession.sync.resolveEbookConflict(bookStableId: book.stableId, useServer: true)
                    if let json = serverLocator, !json.isEmpty {
                        model.navigateTo(locatorJSON: json)
                    } else {
                        Task { await model.seek(toProgress: conflict.serverProgress) }
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(model.preferredColorScheme)
            .enveEnvironment()
        }
    }

    private var readerPlaybackObservers: some View {
        readerEditors
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
        .onReceive(model.ttsService.$kokoroDownloadState) { state in
            #if DEBUG
            guard debugRoute == "kokoroplayback", state == .ready, model.state.isReady else { return }
            startTTSPlaybackFixture()
            #endif
        }
        .preferredColorScheme(model.preferredColorScheme)
        // On a folding phone the status bar's column is where the chrome stands, and hiding it would reflow
        // the pages every time the chrome toggles.
        .statusBarHidden(!chromeVisible && !hinge.isKnown)
    }

    private var readerLifecycle: some View {
        readerPlaybackObservers
        .onAppear(perform: beginSession)
        .onChange(of: restReminderInterval) { _, minutes in
            restReminder.update(minutes: minutes)
        }
        .onChange(of: restReminder.isDue) { _, isDue in
            guard isDue else { return }
            restPromptShowsSettingsHint = !model.appearance.restReminderIntroShown
            if restPromptShowsSettingsHint {
                model.appearance.restReminderIntroShown = true
                restReminder.keepPromptVisible()
            }
            PlatformHaptics.notification(.success)
            AccessibilityNotification.Announcement("Time to rest your eyes").post()
        }
        .onChange(of: colorScheme) { _, newValue in
            model.updateSystemColorScheme(newValue)
        }
        .onChange(of: model.pendingSelection != nil) { _, active in
            if active {
                initialChromeHideTask?.cancel()
                withAnimation(.smooth) { chromeVisible = false }
            }
            if model.isReadAloudMode {
                showReadAloudControls(autoHide: !active)
            }
            if !active, ttsControlsVisible {
                showTTSControls(autoHide: true)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.isReadAloudMode {
                showReadAloudControls(autoHide: model.pendingSelection == nil)
            } else {
                readAloudControlsHideTask?.cancel()
            }
            if phase == .active, ttsControlsVisible {
                showTTSControls(autoHide: model.pendingSelection == nil)
            } else if phase != .active {
                ttsControlsHideTask?.cancel()
            }
        }
        .onChange(of: tray) { _, presented in
            guard presented == nil,
                !chromeVisible,
                isTTSActive
            else { return }
            showTTSControls(autoHide: true)
        }
        .onChange(of: model.state.isReady) { _, ready in
            guard ready else { return }
            #if DEBUG
            if [
                "ttsvoices", "kokorodownload",
            ].contains(debugRoute) {
                tray = .tts
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
            if readerFontProbe == nil, ProcessInfo.processInfo.arguments.contains("--probe-reader-font") {
                probeOpenDyslexicFont()
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
                if tray == nil, model.pendingSelection == nil, !UIAccessibility.isVoiceOverRunning {
                    withAnimation(.smooth) { chromeVisible = false }
                }
            }
        }
        .onChange(of: model.isReadAloudMode) { _, active in
            if active {
                initialChromeHideTask?.cancel()
                withAnimation(.smooth) { chromeVisible = false }
                showReadAloudControls(autoHide: model.pendingSelection == nil)
            } else {
                hideReadAloudControls()
            }
        }
        .onDisappear(perform: endSession)
        .task {
            ambient = await AmbientColorStore(imageCache: profileSession.imageCache).resolve(for: book)
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
        case .loading, .readyEPUB, .readyFoliate:
            ZStack {
                if let adapter = model.activeReaderEngineAdapter {
                    ZStack {
                        ReaderEngineControllerBridge(
                            adapter: adapter,
                            onHighlight: {
                                withLiveSelection {
                                    model.annotationController.addAnnotationFromSelection(style: .highlight, colorHex: inkColor)
                                    PlatformHaptics.impact(.light)
                                }
                            },
                            onAnnotate: {
                                withLiveSelection {
                                    if let selection = adapter.currentSelection {
                                        model.pendingSelection = selection
                                        noteDraft = ReaderNoteDraft(text: selection.locator.text.highlight ?? "")
                                    }
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
                            isSelectionActive: model.pendingSelection != nil,
                            isPinchResizeEnabled: isPinchResizeEnabled,
                            onPinchResize: { model.handlePinchResize($0) }
                        )
                        .id(ObjectIdentifier(adapter.viewController))
                        .allowsHitTesting(model.state.isReady && !model.readerLayoutInProgress)
                        .ignoresSafeArea(edges: model.castingCanvasSize == nil ? .vertical : [])
                        .frame(width: model.castingCanvasSize?.width, height: model.castingCanvasSize?.height)
                        .scaleEffect(model.castingCanvasSize == nil ? 1 : 1.0 / 3.0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if model.state.isReady, model.isReadTogetherActive {
                            ReaderCastingCover(model: model, bookTitle: book.title)
                        }
                    }
                }
                if !model.state.isReady {
                    loadingView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(hearth.bg)
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
                pageData: { try await model.comicPageData(at: $0) },
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
            Text(book.isComic ? "Opening comic…" : "Opening book…")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
            ReaderCloseControl { dismiss in
                QuietButton(title: "Cancel", systemImage: "xmark") { dismiss() }
            }
            .padding(.top, 6)
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
            EmberButton(title: "Try again", systemImage: "arrow.clockwise") { model.retryOpen() }
            ReaderCloseControl { dismiss in
                QuietButton(title: "Close") { dismiss() }
            }
                .padding(.top, 6)
        }
        .padding(.horizontal, 40)
    }

    private var topVeil: some View {
        ZStack(alignment: .top) {
            Overline(book.title)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(book.title)
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
                .frame(minHeight: 44)
                .frame(maxWidth: 560)
                .padding(.horizontal, 76)
            if chromeColumn == nil {
                HStack {
                    Spacer()
                    closeButton
                }
                .padding(.trailing, 20)
            }
        }
        .padding(.top, 8 + topChromeClearance)
        .frame(maxWidth: .infinity)
    }

    private var closeButton: some View {
        ReaderCloseControl { dismiss in
            GlyphButton(systemImage: "xmark", label: "Close") {
                Task { @MainActor in
                    await model.saveProgressResolvingVisibleOverlay()
                    dismiss()
                }
            }
        }
    }

    // On a folding phone's outer display, and open sideways, the reader's buttons stand in the system's side
    // column like any toolbar: close at the top, the tools at the bottom where the thumb rests.
    private func sideChrome(column: SideColumn) -> some View {
        VStack(spacing: 10) {
            closeButton
            Spacer(minLength: 12)
            toolButtons(spacing: 10)
        }
        .padding(.top, column.statusBarBottom + 8)
        .padding(.bottom, 14)
        .frame(width: column.width)
        .frame(maxHeight: .infinity)
        .offset(x: column.width)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-side-chrome")
    }

    // The side column exists on the outer display and on the open display held sideways; the lectern keeps
    // its controls on the flat half instead.
    private var chromeColumn: SideColumn? {
        guard hinge.isKnown, !isLectern, !dynamicTypeSize.isAccessibilitySize else { return nil }
        return sideColumn
    }

    private var topChromeClearance: CGFloat {
        chromeColumn?.topClearance ?? 0
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            if isComicReader {
                comicPositionControls
            } else {
                ReaderFooterProgressRail(
                    progress: epubScrubProgress ?? model.currentProgress ?? 0,
                    tint: ambient,
                    ticks: ribbonTicks,
                    statusLine: epubScrubProgress.map { model.positionSummaryText(atProgress: $0) } ?? statusLine,
                    chapterStatusLine: model.chapterPageSummaryText.flatMap { composedStatusLine(pages: $0) },
                    // Narration keeps its own audio scrubber; a second book scrubber would compete with it.
                    showsTrack: !(model.isReadAloudMode && model.overlayPlayer != nil),
                    isScrubbing: epubScrubProgress != nil,
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
            if isTTSActive {
                ReaderTTSControls(tts: model.ttsService, onSpeechSettings: { tray = .tts })
            }
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
            if chromeColumn == nil {
                toolButtons(spacing: 18)
                    .padding(.top, 2)
            }
        }
        // The rail and controls stay a readable, reachable width on wide canvases; the veil itself spans the window.
        .frame(maxWidth: 720)
    }

    private func toolButtons(spacing: CGFloat) -> some View {
        let layout = chromeColumn == nil ? AnyLayout(HStackLayout(spacing: spacing)) : AnyLayout(VStackLayout(spacing: spacing))
        return layout {
            GlyphButton(systemImage: "list.bullet", label: "Contents") { tray = .contents }
            if showsAppearance {
                GlyphButton(
                    systemImage: isComicReader ? "slider.horizontal.3" : "textformat.size",
                    label: isComicReader ? "Comic settings" : "Appearance"
                ) { tray = .appearance }
            }
            if isEPUB {
                GlyphButton(systemImage: "magnifyingglass", label: "Search") { tray = .search }
            }
            if isEPUB || model.hasMediaOverlay {
                moreMenu
            }
        }
    }

    private var bottomVeil: some View {
        bottomControls
            .padding(.top, 30)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .background { bottomVeilBackground }
    }

    // The flat half of a device propped open on a table keeps the controls in reach the whole time, with page
    // turns first so the upright page never has to be reached for.
    private var lecternPanel: some View {
        VStack(spacing: 14) {
            lecternPageTurns
            bottomControls
        }
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color(model.effectiveAppearance.shellBackgroundColor)
                .ignoresSafeArea(edges: [.horizontal, .bottom])
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reading controls")
    }

    private var showsSpine: Bool {
        isEPUB
            && ReaderSpreadPolicy.showsSpine(
                canvas: canvasSize,
                columnMode: model.appearance.columnMode,
                scrollEnabled: model.appearance.scrollEnabled,
                isFixedLayout: model.isFixedLayoutBook,
                usesAccessibilityType: dynamicTypeSize.isAccessibilitySize
            )
    }

    // The left button always turns towards the left page, so a right-to-left book swaps the labels, not the glyphs.
    private var lecternPageTurns: some View {
        let isRightToLeft = model.isRightToLeftPageProgression
        return HStack(spacing: 28) {
            GlyphButton(systemImage: "chevron.left", size: 56, glyphSize: 19, label: isRightToLeft ? "Next page" : "Previous page") {
                turnPageFromLeftEdge()
            }
            GlyphButton(systemImage: "chevron.right", size: 56, glyphSize: 19, label: isRightToLeft ? "Previous page" : "Next page") {
                turnPageFromRightEdge()
            }
        }
        .accessibilityIdentifier("lectern-page-turns")
    }

    private var lecternHalves: FoldLine.Halves? {
        guard model.state.isReady, !dynamicTypeSize.isAccessibilitySize else { return nil }
        return ReaderSpreadPolicy.lecternHalves(canvas: canvasSize, pose: hinge.pose(for: canvasSize), fold: canvasFold)
    }

    private var isLectern: Bool { lecternHalves != nil }

    // On the lectern the pills sit at the foot of the page rather than over the controls.
    private var floatingPillsInset: CGFloat {
        if let lectern = lecternHalves {
            return canvasSize.height - lectern.upperHeight + 12
        }
        guard chromeVisible else { return 36 }
        return isTTSActive ? 228 : 172
    }

    private var isTTSActive: Bool {
        model.ttsService.isPlaying || model.ttsService.isPaused
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
            .ignoresSafeArea(edges: [.horizontal, .bottom])
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

    private var readAloudBar: AnyView {
        // Keep the inactive overlay's generic tree off the reader's main-thread stack.
        guard model.isReadAloudMode, let player = model.overlayPlayer else {
            return AnyView(EmptyView())
        }
        return AnyView(
            ReaderReadAloudBar(
                model: model,
                player: player,
                onBookmark: { bookmarkDraft = makeBookmarkDraft(readAloud: true) },
                onSettings: { tray = .readAloud },
                onStop: { model.toggleReadAloud() }
            )
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        )
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
                .accessibilityLabel("More reader options")
                .accessibilityIdentifier("Reader.MoreMenu")
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

    private var isPinchResizeEnabled: Bool {
        isEPUB && !model.isFixedLayoutBook && model.castingCanvasSize == nil
    }

    private var showsAppearance: Bool {
        switch model.state {
        case .readyEPUB, .readyFoliate, .readyPDF, .readyComic: return true
        default: return false
        }
    }

    private var statusLine: String? {
        composedStatusLine(pages: model.pageSummaryText)
    }

    private func composedStatusLine(pages: String?) -> String? {
        var parts: [String] = []
        if let pages {
            parts.append(pages)
        }
        if let minutes = model.minutesLeftInChapter, minutes > 0 {
            parts.append("\(Self.minutesText(minutes)) left in chapter")
        } else if let minutes = model.minutesLeftInBook, minutes > 0 {
            parts.append("\(Self.minutesText(minutes)) left in the book")
        }
        parts.append(model.percentSummaryText)
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
        if comicScrubTargetIndex == nil, let spread = model.visiblePageRange, spread.count > 1, spread.upperBound <= comicPageTotal {
            let progress = Double(spread.upperBound - 1) / Double(max(comicPageTotal - 1, 1))
            return "Pages \(spread.lowerBound)–\(spread.upperBound) of \(comicPageTotal) · \(Int(progress * 100))%"
        }
        let displayIndex = min(max(0, comicScrubTargetIndex ?? comicCurrentPageIndex), max(0, comicPageTotal - 1))
        let progress = comicPageTotal > 1 ? Double(displayIndex) / Double(comicPageTotal - 1) : 1
        return "Page \(displayIndex + 1) of \(comicPageTotal) · \(Int(progress * 100))%"
    }

    private var isComicAtEnd: Bool {
        comicPageTotal > 0 && max(comicCurrentPageIndex, model.lastVisibleComicPageIndex) >= comicPageTotal - 1
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
        // EPUB engines already route taps; overlaying them intercepts native text selection.
        !chromeVisible
            && !isEPUB
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
            if model.linkReturnLocatorJSON != nil {
                linkReturnPill
            }
            if !chromeVisible, readAloudControlsVisible, model.isReadAloudMode, model.overlayPlayer != nil {
                ReaderNarratePill(
                    model: model,
                    onBookmark: { bookmarkDraft = makeBookmarkDraft(readAloud: true) },
                    onPlaybackToggle: { showReadAloudControls(autoHide: model.pendingSelection == nil) },
                    onMore: { showDetailedReadAloudControls() }
                )
                .anchorPreference(key: ReaderNarrationControlsBoundsKey.self, value: .bounds) { $0 }
            }
            if !chromeVisible, !isLectern, ttsControlsVisible, isTTSActive {
                ReaderTTSControls(
                    tts: model.ttsService,
                    onInteraction: { showTTSControls(autoHide: true) },
                    onSpeechSettings: { tray = .tts },
                    onShowReaderControls: { showReaderControls() }
                )
            }
        }
        .animation(.smooth(duration: 0.3), value: model.isReadAloudMode)
        .animation(.smooth(duration: 0.25), value: model.linkReturnLocatorJSON != nil)
    }

    private var linkReturnPill: some View {
        HStack(spacing: 0) {
            Button {
                PlatformHaptics.selection()
                Task { await model.returnFromLinkJump() }
            } label: {
                Label("Back to reading", systemImage: "arrow.uturn.backward")
                    .font(.hearthUI(14, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            Button {
                model.dismissLinkReturn()
            } label: {
                Image(systemName: "xmark")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(hearth.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Stay here")
        }
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

    private func annotateLayer(
        _ selection: ReaderSelectionSnapshot,
        narrationBounds: Anchor<CGRect>?
    ) -> some View {
        GeometryReader { geo in
            ReaderAnnotateBar(
                selectedColor: $inkColor,
                onHighlight: { color in
                    inkColor = color
                    annotateLiveSelection(style: .highlight, colorHex: color)
                },
                onUnderline: { annotateLiveSelection(style: .underline, colorHex: inkColor) },
                onStrikethrough: { annotateLiveSelection(style: .strikethrough, colorHex: inkColor) },
                onSquiggle: { annotateLiveSelection(style: .squiggly, colorHex: inkColor) },
                onNote: {
                    withLiveSelection {
                        let current = currentEPUBSelection(fallback: selection)
                        noteDraft = ReaderNoteDraft(text: current.locator.text.highlight ?? "")
                    }
                },
                onCopy: { withLiveSelection { copySelection(currentEPUBSelection(fallback: selection)) } },
                onDefine: { withLiveSelection { handleDefine() } }
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reader-annotation-toolbar")
            .position(
                ReaderAnnotationToolbarLayout.position(
                    for: selection.frame,
                    in: geo.size,
                    narrationBounds: narrationBounds.map { geo[$0] }
                )
            )
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private func readerOpenLibrarian() {
        guard profileSession.isOwner else {
            librarianMessage = "Librarian is available in the adult profile."
            return
        }
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
        let shouldAutoSave = profileSession.preferences.loadPreferences().vocabAutoLogLookups
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

    private func withLiveSelection(_ action: @escaping () -> Void) {
        Task {
            await model.refreshEngineSelection()
            action()
        }
    }

    private func annotateLiveSelection(style: ReaderAnnotationStyle, colorHex: String) {
        withLiveSelection {
            model.annotationController.addAnnotationFromSelection(style: style, colorHex: colorHex)
            PlatformHaptics.impact(.light)
        }
    }

    private func currentEPUBSelection(
        fallback selection: ReaderSelectionSnapshot
    ) -> ReaderSelectionSnapshot {
        model.activeReaderEngineAdapter?.currentSelection ?? selection
    }

    private func dismissPendingSelection() {
        model.pendingSingleTapTask?.cancel()
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
        if model.pendingSelection != nil {
            dismissPendingSelection()
            return
        }
        initialChromeHideTask?.cancel()
        if model.isReadAloudMode, model.overlayPlayer != nil {
            if chromeVisible {
                hideReadAloudControls()
                withAnimation(.smooth(duration: 0.35)) { chromeVisible = false }
            } else if readAloudControlsVisible {
                hideReadAloudControls()
            } else {
                showReadAloudControls(autoHide: true)
            }
            return
        }

        guard size.width > 0, model.appearance.tapEdgesTurnPages else {
            handleCenterTap()
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
            handleCenterTap()
        }
    }

    private func handleCenterTap() {
        if chromeVisible {
            toggleChrome()
            if isTTSActive {
                showTTSControls(autoHide: true)
            }
        } else {
            showReaderControls()
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

    #if DEBUG
    private func probeOpenDyslexicFont() {
        readerFontProbe = "pending"
        let previous = model.appearance.fontFamily
        model.appearance.fontFamily = .openDyslexic
        Task { @MainActor in
            var result: String?
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                result = await model.readerFontProbeForTesting()
                if result?.contains("Enve OpenDyslexic") == true, result?.contains("loaded") == true { break }
            }
            readerFontProbe = result ?? "unavailable"
            model.appearance.fontFamily = previous
        }
    }
    #endif

    private func toggleChrome() {
        initialChromeHideTask?.cancel()
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
            chromeVisible.toggle()
        }
    }

    private func showReaderControls() {
        initialChromeHideTask?.cancel()
        ttsControlsHideTask?.cancel()
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
            chromeVisible = true
        }
    }

    private func showReadAloudControls(autoHide: Bool) {
        readAloudControlsHideTask?.cancel()
        withAnimation(.smooth(duration: 0.25)) { readAloudControlsVisible = true }
        guard autoHide else { return }
        readAloudControlsHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled,
                scenePhase == .active,
                model.isReadAloudMode,
                model.overlayPlayer?.isPlaying == true,
                model.pendingSelection == nil,
                tray == nil,
                bookmarkDraft == nil,
                !UIAccessibility.isVoiceOverRunning
            else { return }
            withAnimation(.smooth(duration: 0.25)) { readAloudControlsVisible = false }
        }
    }

    private func hideReadAloudControls() {
        readAloudControlsHideTask?.cancel()
        withAnimation(.smooth(duration: 0.25)) { readAloudControlsVisible = false }
    }

    private func showTTSControls(autoHide: Bool) {
        ttsControlsHideTask?.cancel()
        if !ttsControlsVisible {
            withAnimation(.smooth(duration: 0.25)) {
                ttsControlsVisible = true
            }
        }
        guard autoHide else { return }
        ttsControlsHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled,
                scenePhase == .active,
                model.ttsService.isPlaying,
                model.pendingSelection == nil,
                tray == nil,
                noteDraft == nil,
                bookmarkDraft == nil,
                defineRequest == nil,
                progressConflict == nil,
                !showingRestReminderSettings,
                !showingLibrarian,
                !UIAccessibility.isVoiceOverRunning
            else { return }
            withAnimation(.smooth(duration: 0.25)) {
                ttsControlsVisible = false
            }
        }
    }

    private func hideTTSControls() {
        ttsControlsHideTask?.cancel()
        withAnimation(.smooth(duration: 0.25)) {
            ttsControlsVisible = false
        }
    }

    private func showDetailedReadAloudControls() {
        hideReadAloudControls()
        showReaderControls()
    }

    private var restPromptColors: ReaderRestPrompt.Colors {
        if case .readyComic = model.state {
            let background = model.appearance.comicBackgroundColor
            let text: SwiftUI.Color = background == .white ? .black : .white
            return .init(background: background.swiftUIColor, text: text, tint: text)
        }
        let appearance = model.effectiveAppearance
        let text = SwiftUI.Color(appearance.shellTextColor)
        return .init(
            background: SwiftUI.Color(appearance.shellBackgroundColor),
            text: text,
            tint: appearance.theme == .eink ? text : hearth.ember
        )
    }

    private var restReminderInterval: Int {
        model.appearance.restReminderEnabled ? model.appearance.restReminderMinutes : 0
    }

    private func beginSession() {
        model.updateSystemColorScheme(colorScheme)
        profileSession.lastOpened.record(book)
        model.tapHandler = { handleTap($0, viewSize: $1) }
        model.doubleTapHandler = { [weak model] point in
            model?.handleReaderDoubleTap(at: point)
        }
        NotificationCenter.default.post(name: .ebookReaderPresented, object: nil)
        model.startIfNeeded()
        model.sessionStartDate = Date()
        model.sessionStartProgress = model.currentProgress ?? book.canonicalEbookProgress
        Task {
            await profileSession.readingStats.startSession(
                bookId: book.stableId,
                positionProgression: model.currentProgress ?? 0,
                location: model.currentSectionTitle
            )
        }
        Task { if profileSession.isOwner { await HardcoverSyncService.shared.syncBookStarted(book: book) } }
        Task {

            await profileSession.sync.pullOnOpen(
                book: book,
                domain: .ebook,
                excludingProvider: book.source == .storyteller
            )
            progressConflict = profileSession.ebookConflicts.find(stableId: book.stableId)
        }
        model.startAutoSaveTimer()
        Task {
            await profileSession.ebookLinker.rebuildCacheIfNeeded()
            linkedAudiobook = await profileSession.ebookLinker.linkedAudiobookAsync(for: book)
        }
        Task { nextSeriesIssue = await findNextSeriesIssue() }
        restReminder.start(minutes: restReminderInterval)
    }

    private func endSession() {
        guard !profileSession.isRetired else { return }
        bookmarkToastTask?.cancel()
        restReminder.stop()
        initialChromeHideTask?.cancel()
        readAloudControlsHideTask?.cancel()
        ttsControlsHideTask?.cancel()
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
        if progress >= Book.finishedProgressThreshold {
            Task {
                if profileSession.isOwner { await HardcoverSyncService.shared.syncBookFinished(book: book) }
                if profileSession.preferences.loadPreferences().autoDeleteFinishedBooks,
                    book.source != .local
                {
                    try? profileSession.ebooks.deleteRemoteEbookArtifacts(forBookId: book.id)
                    profileSession.appState.mutateBook(uniqueId: book.uniqueId) { $0.ebookFileURL = nil }
                }
            }
        } else if progress > 0 {
            Task { if profileSession.isOwner { await HardcoverSyncService.shared.syncProgress(book: book, progress: progress) } }
        }

        let capturedBook = book
        let startDate = model.sessionStartDate
        let startProgress = model.sessionStartProgress
        let locatorJSON = model.lastKnownLocatorJSON
        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        if book.source == .booklore, profileSession.progress.syncProgressToServer {
            bgTaskId = UIApplication.shared.beginBackgroundTask {
                UIApplication.shared.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
            }
        }
        let finalProgression = model.currentProgress
        let sectionTitle = model.currentSectionTitle
        Task {
            defer {
                if bgTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskId)
                }
            }
            let session = await profileSession.readingStats.endSession(
                bookId: capturedBook.stableId,
                finalProgression: finalProgression,
                location: sectionTitle
            )
            guard bgTaskId != .invalid, let session,
                let provider = profileSession.appState.getProvider(capturedBook.providerId) as? BookloreProvider
            else { return }
            try? await provider.uploadEbookReadingSession(
                for: capturedBook,
                startDate: startDate,
                activeSeconds: session.durationSeconds,
                startProgress: startProgress,
                endProgress: progress,
                epubLocator: locatorJSON
            )
        }
    }

    private func readerSyncAudiobookOnDismissIfNeeded() {
        guard !book.isReadAloudBook, book.epub3Features?.hasMediaOverlay != true else { return }
        let playback = profileSession.playback.composition.controller
        guard let audiobook = linkedAudiobook,
            playback.snapshot.currentBook?.stableId == audiobook.stableId,
            !playback.snapshot.isPlaying
        else { return }
        guard let chapterIndex = model.currentChapterIndex,
            let seekTime = profileSession.ebookLinker.audiobookTimeForEbookChapter(chapterIndex, ebook: book)
        else { return }
        playback.seek(to: seekTime)
    }

    private func findNextSeriesIssue() async -> Book? {
        if let sequence = engine.readerOpen.readingSequence,
            let index = sequence.firstIndex(of: book.uniqueId) {
            for id in sequence.dropFirst(index + 1) {
                if let next = await engine.library.book(uniqueId: id) { return next }
            }
            return nil
        }
        guard book.mediaType == .ebook, let series = book.series else { return nil }
        if book.isComic, let aggregate = await engine.library.seriesAggregate(for: book) {
            var offset = 0
            var foundCurrent = false
            while !Task.isCancelled {
                let page = await engine.library.seriesBooksPage(for: aggregate, mediaScope: ["ebook"], offset: offset, limit: 200)
                for issue in page {
                    if foundCurrent { return issue }
                    if issue.uniqueId == book.uniqueId { foundCurrent = true }
                }
                if page.count < 200 { return nil }
                offset += page.count
            }
            return nil
        }
        let siblings = DetailSeriesOrder.sorted(await profileSession.appState.bookStore.books(inSeries: series))
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
        engine.playback.openEbook(issue, readingSequence: engine.readerOpen.readingSequence)
    }

    private func dismissNextSeriesPrompt() {
        dismissedNextSeriesPrompt = true
        PlatformHaptics.impact(.light)
    }

    private func isComicBook(_ book: Book) -> Bool {
        if book.isComic { return true }
        if let format = book.ebookFormat?.lowercased(), ["cbz", "cbr", "cb7", "cbt"].contains(format) {
            return true
        }
        guard let ext = book.ebookFileURL?.pathExtension.lowercased() else { return false }
        return ["cbz", "cbr", "cb7", "cbt"].contains(ext)
    }
}

private nonisolated struct ReaderCanvasGeometry: Equatable, Sendable {
    var size: CGSize
    var column: SideColumn?
    var fold: FoldLine?
}

// Keep dismiss out of the sheet presenter to avoid an iOS 17 update loop.
private struct ReaderCloseControl<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let content: (DismissAction) -> Content

    var body: some View {
        content(dismiss)
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

private struct ReaderFooterProgressRail: View {
    let progress: Double
    let tint: SwiftUI.Color
    let ticks: [Double]
    let statusLine: String?
    let chapterStatusLine: String?
    let showsTrack: Bool
    let isScrubbing: Bool
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("reader.showsChapterPages") private var showsChapterPages = false

    var body: some View {
        VStack(spacing: 0) {
            if showsTrack {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(trackColor)
                            .frame(height: 3)
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, geo.size.width * clamped), height: 3)
                        ForEach(ticks.filter { $0 > 0.005 && $0 < 0.995 }, id: \.self) { tick in
                            Rectangle()
                                .fill(hearth.bgElevated.opacity(0.9))
                                .frame(width: 1.5, height: 3)
                                .offset(x: geo.size.width * tick)
                        }
                        Circle()
                            .fill(tint)
                            .stroke(hearth.bgElevated, lineWidth: 2)
                            .frame(width: 11, height: 11)
                            .offset(x: thumbOffset(width: geo.size.width))
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                onScrub(ReaderScrubGeometry.progress(at: value.location.x, width: geo.size.width))
                            }
                            .onEnded { value in
                                onCommit(ReaderScrubGeometry.progress(at: value.location.x, width: geo.size.width))
                            }
                    )
                }
                .frame(height: 44)
                .accessibilityElement()
                .accessibilityLabel("Reading progress")
                .accessibilityValue(statusLine ?? "\(Int(clamped * 100)) percent")
                .accessibilityAdjustableAction { direction in
                    let step = 0.02
                    switch direction {
                    case .increment: onCommit(min(1, clamped + step))
                    case .decrement: onCommit(max(0, clamped - step))
                    @unknown default: break
                    }
                }
                .accessibilityIdentifier("reader-progress-slider")
            }

            if let chapterStatusLine {
                let showsChapter = showsChapterPages && !isScrubbing
                Button {
                    guard !isScrubbing else { return }
                    showsChapterPages.toggle()
                } label: {
                    caption(showsChapter ? chapterStatusLine : statusLine ?? chapterStatusLine)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .top)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isScrubbing)
                .accessibilityValue(showsChapter ? "Pages in chapter" : "Pages in book")
                .accessibilityHint(showsChapterPages ? "Show pages in book" : "Show pages in chapter")
                .accessibilityIdentifier("reader-page-scope-toggle")
            } else if let statusLine {
                caption(statusLine)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.hearthUI(13, weight: .semibold).monospacedDigit())
            .foregroundStyle(hearth.text)
            .multilineTextAlignment(.center)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.82)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var clamped: Double {
        min(max(progress, 0), 1)
    }

    private var trackColor: SwiftUI.Color {
        hearth.isInk ? .white.opacity(0.24) : .black.opacity(0.16)
    }

    private func thumbOffset(width: CGFloat) -> CGFloat {
        let diameter: CGFloat = 11
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
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
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

private struct ReaderRestPrompt: View {
    struct Colors {
        let background: SwiftUI.Color
        let text: SwiftUI.Color
        let tint: SwiftUI.Color
    }

    let minutes: Int
    let colors: Colors
    let showsSettingsHint: Bool
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "eye")
                    .font(.hearthUI(18, weight: .semibold))
                    .foregroundStyle(colors.tint)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("REST YOUR EYES")
                        .font(.hearthUI(11, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(colors.text.opacity(0.65))
                    Text("Look up for a moment")
                        .font(.hearthDisplay(20, weight: .semibold))
                        .foregroundStyle(colors.text)
                    Text("You've been reading for \(minutes) minutes. Look at something far away for about 20 seconds.")
                        .font(.hearthUI(13, weight: .medium))
                        .foregroundStyle(colors.text.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.hearthUI(12, weight: .semibold))
                        .foregroundStyle(colors.text.opacity(0.65))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Dismiss rest reminder")
            }

            if showsSettingsHint {
                Text("Turn this reminder off or customize it in Settings.")
                    .font(.hearthUI(13, weight: .medium))
                    .foregroundStyle(colors.text.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onOpenSettings) {
                    Label("Rest reminder settings", systemImage: "gearshape")
                        .font(.hearthUI(14, weight: .semibold))
                        .foregroundStyle(colors.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .overlay(Capsule().strokeBorder(colors.text.opacity(0.28), lineWidth: 1))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(18)
        .background {
            let shape = RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
            shape
                .fill(colors.background)
                .overlay(shape.fill(colors.text.opacity(0.06)))
                .overlay(shape.strokeBorder(colors.text.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        }
        .accessibilityElement(children: .contain)
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
        .frame(height: 44)
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
    @State private var scrubTime: TimeInterval?

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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard player.totalDuration > 0 else { return }
                                    scrubTime = ReaderScrubGeometry.time(
                                        at: value.location.x,
                                        width: geo.size.width,
                                        duration: player.totalDuration
                                    )
                                }
                                .onEnded { value in
                                    guard player.totalDuration > 0 else { return }
                                    let target = ReaderScrubGeometry.time(
                                        at: value.location.x,
                                        width: geo.size.width,
                                        duration: player.totalDuration
                                    )
                                    model.seekReadAloud(toTime: target)
                                    scrubTime = nil
                                }
                        )
                    }
                    .frame(height: 44)
                    .accessibilityElement()
                    .accessibilityLabel("Read Aloud position")
                    .accessibilityValue("\(timeText(displayTime)) elapsed, \(timeText(remainingTime)) remaining")
                    .accessibilityAdjustableAction { direction in
                        let step: TimeInterval = 30
                        switch direction {
                        case .increment: model.seekReadAloud(toTime: min(player.totalDuration, displayTime + step))
                        case .decrement: model.seekReadAloud(toTime: max(0, displayTime - step))
                        @unknown default: break
                        }
                    }

                    HStack {
                        Text(timeText(displayTime))
                        Spacer()
                        Text("\(timeText(remainingTime)) left")
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
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
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

            // Narrow widths such as compact Slide Over cannot fit six 44pt targets in one row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    positionControls
                    playbackOptionControls
                }
                VStack(spacing: 8) {
                    HStack(spacing: 8) { positionControls }
                    HStack(spacing: 8) { playbackOptionControls }
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

    @ViewBuilder
    private var positionControls: some View {
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
    }

    @ViewBuilder
    private var playbackOptionControls: some View {
        speedMenu

        readAloudIconButton("slider.horizontal.3", label: "Read Aloud settings") {
            onSettings()
        }

        readAloudIconButton("xmark", label: "Stop Read Aloud") {
            onStop()
        }
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
                .frame(minHeight: 44)
                .contentShape(Rectangle())
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
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    private var readAloudProgress: Double {
        if player.totalDuration > 0 {
            return min(max(displayTime / player.totalDuration, 0), 1)
        }
        guard model.overlayClipCount > 0 else { return 0 }
        return min(max(Double(player.currentClipIndex) / Double(model.overlayClipCount), 0), 1)
    }

    private var displayTime: TimeInterval {
        scrubTime ?? player.currentTime
    }

    private var remainingTime: TimeInterval {
        max(0, player.totalDuration - displayTime)
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
        String(format: "%gx", speed)
    }
}

enum ReaderAnnotationToolbarLayout {
    static let barHeight: CGFloat = 54
    static let controlsGap: CGFloat = 10

    static func position(
        for frame: CGRect?,
        in size: CGSize,
        narrationBounds: CGRect?
    ) -> CGPoint {
        let compact = size.width < 390
        let barWidth = min(size.width - 24, compact ? 348 : 500)
        let halfWidth = barWidth / 2
        let sideInset = (size.width - barWidth) / 2
        let barOffset: CGFloat = 54
        let x: CGFloat
        let preferredY: CGFloat
        if let frame, frame != .zero {
            x = min(max(frame.midX, sideInset + halfWidth), size.width - sideInset - halfWidth)
            let above = frame.minY - barOffset
            preferredY = above > 90 ? above : min(frame.maxY + barOffset, size.height - 110)
        } else {
            x = size.width / 2
            preferredY = size.height - 140
        }
        // Resolve the actual pill in the annotation layer's coordinate space, including
        // safe-area insets. Bottom selections must leave both toolbars accessible.
        let y: CGFloat
        if let narrationBounds {
            y = max(barHeight / 2, min(preferredY, narrationBounds.minY - barHeight / 2 - controlsGap))
        } else {
            y = preferredY
        }
        return CGPoint(x: x, y: y)
    }
}

private struct ReaderNarrationControlsBoundsKey: PreferenceKey {
    nonisolated static var defaultValue: Anchor<CGRect>? { nil }

    nonisolated static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-narration-controls")
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
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

private struct ReaderTTSControls: View {
    @ObservedObject var tts: EbookTTSService
    var onInteraction: () -> Void = {}
    let onSpeechSettings: () -> Void
    var onShowReaderControls: (() -> Void)?

    @Environment(\.hearth) private var hearth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSpeaking: Bool { tts.isPlaying && !tts.isPaused }

    private var rateText: String {
        "\(Double(tts.rate).formatted(.number.precision(.fractionLength(0...2))))×"
    }

    var body: some View {
        if tts.isPlaying || tts.isPaused {
            HStack(spacing: 2) {
                control("backward.fill", label: "Previous paragraph") {
                    onInteraction()
                    tts.previousParagraph()
                }
                control(
                    isSpeaking ? "pause.fill" : "play.fill",
                    label: isSpeaking ? "Pause reading aloud" : "Resume reading aloud",
                    primary: true
                ) {
                    onInteraction()
                    tts.togglePlayPause()
                }
                control("forward.fill", label: "Next paragraph") {
                    onInteraction()
                    tts.nextParagraph()
                }
                Rectangle()
                    .fill(hearth.hairline)
                    .frame(width: 1, height: 22)
                    .accessibilityHidden(true)
                Button(action: onSpeechSettings) {
                    HStack(spacing: 5) {
                        Image(systemName: "person.wave.2")
                        Text(rateText)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .font(.hearthUI(13, weight: .semibold))
                    .foregroundStyle(hearth.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Voice and speed")
                .accessibilityValue(rateText)
                if let onShowReaderControls {
                    control("chevron.up", label: "Show reader controls", action: onShowReaderControls)
                }
            }
            .padding(.horizontal, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reader-tts-controls")
            .background {
                HearthChromeBackground(
                    shape: .capsule,
                    fill: hearth.bgElevated,
                    stroke: hearth.hairline,
                    tint: hearth.bgElevated,
                    shadow: true
                )
            }
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func control(
        _ systemImage: String,
        label: String,
        primary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.hearthUI(primary ? 15 : 13, weight: .semibold))
                .foregroundStyle(primary ? hearth.text : hearth.textSecondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}
