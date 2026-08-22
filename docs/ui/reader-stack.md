# Ebook Reader + Read-Along Stack

All paths below are relative to `enve/` unless noted.

---

## 0. Architectural north star: Thorium

Thorium is the reader backend reference for this branch. The goal is not to copy its TypeScript/Electron code, but to match its boundary:

- Publication import, storage, streamer/opening, session registration, persisted locator/config, and sync live behind a reader engine boundary.
- The UI consumes a compact reader session snapshot and sends commands into the engine instead of owning publication lifecycle and persistence.
- Hot navigator callbacks update locator/session state first, then publish only coarse UI-facing changes.
- Decorations, search, TTS/media-overlay, annotations, and publication config are engine services with narrow UI command surfaces.

The Thorium Reader project is the architectural reference. Useful Thorium files:

- `src/main/redux/reducers/win/session/reader.ts` registers per-reader sessions by publication/window.
- `src/common/redux/states/renderer/readerRootState.ts` defines compact reader session/persistence state (`config`, `locator`, notes, media overlay, TTS, PDF config).
- `src/renderer/reader/redux/reducers/readerLocator.ts` keeps locator state separate from React chrome.
- `src/main/storage/publication-data.ts` persists publication-scoped reader data.

Swift mapping for Enve:

- `ClassicReaderModel` is the current bridge and should shrink toward a `ReaderSessionEngine` facade.
- `ReaderSessionSnapshot` is the first Thorium-style session state object: progress, visible page range, section title, TOC entry, and reading-time estimates are now one compact published snapshot.
- `ReaderLocatorProgress` is the locator persistence core, shared by the reader engine, read-aloud, and `ReaderProgressController`.
- `ReaderProgressController` is the single owner of server-position hydration/restoration and progress save, flush, and server sync.
- `ReaderArtifactsAdapter`, `ReaderSearchModel`, `ReaderReadAloudController`, `ReaderCompanionController`, `ReaderProgressController`, `ReaderPublicationSession`, `ReaderPagedContentController`, and `ReaderInitialLocationResolver` are engine services, not SwiftUI view state.

---

## 1. EPUB renderer

**Readium Swift toolkit is the only EPUB renderer in use.**

- SPM dependency `https://github.com/readium/swift-toolkit.git`, minimum `upToNextMajorVersion 3.11.0`, **resolved 3.11.0** (`enve.xcodeproj/.../swiftpm/Package.resolved`). Products linked: `ReadiumShared`, `ReadiumStreamer`, `ReadiumNavigator`, `ReadiumOPDS`, `ReadiumAdapterGCDWebServer`, plus Readium's `ReadiumZIPFoundation` fork.
**Reader view hierarchy today:**

```
BookDetailScreen
└── ReaderScreen (Screens/Reader/ReaderScreen.swift)
    └── ClassicReaderModel (Reader/Engine/ClassicReaderModel.swift)
        state: enum State {
          case readyEPUB(EPUBNavigatorViewController)   → EPUBNavigatorBridge → AnnotationResponderBridge (UIViewControllerRepresentable, EbookReaderView.swift:1432/1288)
          case readyPDF(PDFKit.PDFDocument)             → PDFReaderBridge → PDFReaderController (EbookReaderView.swift:1472/1480)
          case readyComic                               → ComicReaderBridge (Reader/Engine/ComicReaders.swift — UIPageViewController paged + scroll modes, zoom, RTL, spreads)
          case readyHTML(WKWebView)                     → HTMLReaderBridge (MOBI last-resort fallback)
          case failed(Error)
        }
```

`ClassicReaderModel` owns the `EPUBNavigatorViewController`, coordinates the navigator, and delegates focused state to reader controllers. Its supporting types live in `Reader/Engine/`; the SwiftUI presentation lives in `Screens/Reader/`.

---

## 2. The reader-engine contract a new UI would drive

Primarily on `ClassicReaderModel` (`Reader/Engine/ClassicReaderModel.swift`):

**Open / lifecycle**
- `init(book: Book, initialChapterSelection: EbookReaderInitialSelection? = nil)`
- `func startIfNeeded()` — kicks off `open()` plus `ReaderProgressController.beginHydration()` / `beginRestorationWhenReady()` (`hydrateServerPositionIfNeeded()` → `ProgressConflictResolver` → `applyHydratedServerPositionWhenReady()` jumps the navigator only if the user hasn't turned a page)
- `func startAutoSaveTimer()` / `stopAutoSaveTimer()` (30 s), `func saveProgress()`, `func flushProgressToServer(reason: String = "close")` — thin forwarders onto `ReaderProgressController`; `func cleanupOverlayPlayer()` tears down the whole session (TTS tasks, bridge session, engine adapter, read-aloud) and calls `ReaderPublicationSession.cleanup()` and `ReaderProgressController.cleanup()` as one step
- Publication opening lives in `ReaderPublicationSession` (see section 7); `ClassicReaderModel` applies the opened publication and builds the navigator with `EPUBNavigatorViewController(publication:initialLocation:config:)`, `navigator.delegate = self`

**Published state for UI binding**
`state`, `currentProgress: Double?`, `totalPages`, `visiblePageRange: ClosedRange<Int>?`, `currentSectionTitle`, `tocEntries: [ClassicTOCEntry]`, `pendingSelection: Selection?` (Readium type), `appearance: ClassicReaderAppearance`, `isFixedLayoutBook`, `minutesLeftInChapter/Book`, `readingSpeedDisplay`; computed `pageSummaryText`, `currentChapterIndex`. The page-index surface (`comicPages: [URL]`, `currentComicPageIndex`, `pdfController`, `isComicBook`, `effectiveComicLayout`, `isRightToLeftPageProgression`, `setComicPage`, `endServerPageStreamingSession`) forwards to `ReaderPagedContentController` (see section 7); the controller calls back before UI-visible paged state changes so the model still republishes to SwiftUI.

`ReaderAnnotationController` owns bookmarks, annotations, vocabulary capture, decoration inputs, and provider notebook synchronization.

**Navigation**
- `func pageForward() async` / `pageBackward() async` — `nav.goForward()/goBackward()` for EPUB, page index for PDF/comic (RTL + landscape 2-page spread aware)
- `func navigateTo(locator: Locator)`, `func navigateTo(link: ReadiumShared.Link) async`, `func navigateToTOCEntry(_ entry: ClassicTOCEntry) async`, `func seekToBookmark(_ bookmark: Bookmark) async`, `func setComicPage(_ index: Int, shouldRecordStats: Bool = true)`
- Tap zones (13 % edges), volume-button page turns (`VolumeButtonNavigationCapture`), `tapHandler/doubleTapHandler/longPressHandler` closures

**Locator / position model**
- Canonical position = Readium **Locator JSON** persisted on `Book.epubLocator` + fraction on `Book.ebookProgress`. PDF locator `{"page":N}`, comic locator `cbz-page:N` (`ReaderLocatorProgress.swift` — snapshot/restore/parse helpers; mid-page text-anchor enrichment lives on `ReaderProgressController`)
- `navigator(_:locationDidChange:)` drives progress, stats ticks, section title, read-aloud resync, companion broadcast, chapter-boundary server flush
- Sync fan-out on save: SwiftData `bookStore.updateEbookProgress`, `SyncCoordinator.shared.pushProgress`, `KOReaderSyncService.shared.pushIfLinked`, `StorytellerProvider.updateEbookProgress`, linked-audiobook time mirror

`Reader/Engine/ReaderProgressController.swift` owns everything position-persistence in this stack:

- **Hydration/restoration** — `beginHydration()` pulls the server position (`EbookProgressPulling`, or `StorytellerPositionSyncService` for Storyteller read-aloud) through `ProgressConflictResolver` with backward-progress protection; `beginRestorationWhenReady()` waits for the engine adapter, then jumps only when neither `noteUserNavigation()` nor `ReaderLocationController.locationsDiffer` shows the reader already moved off `noteInitialLocation(_:)`. `hasResolvedInitialHydration` gates every save.
- **EPUB bridge restore** — `ReaderBridgeWriteGate` (pure, `Equatable`) arms a checkpoint write only after a user interaction has been rendered; `noteRelocation(_:readiumNavigator:)` confirms the restore, escalating to `ReadiumPortableAnchorScript` when the target carries a portable anchor.
- **Save scheduling** — the 30 s autosave timer, the 450 ms post-relocation `scheduleProgressSave()`, and the 280 ms `scheduleLocatorEnrichment(locator:navigator:)` that upgrades the stored locator with a visible mid-page text anchor.
- **Save and flush** — `saveProgress()` and `flushProgressToServer(reason:)` own the single pending `serverSyncTask`, so a debounced save, a chapter-boundary flush, and a read-aloud commit can never race each other.
- **Read-aloud commits** — `commitReadAloudPosition(_:)` persists a `ReaderReadAloudPositionCommit`; the controller resolves a synthetic StoryAlign/Storyteller book back to its real library book before sync and mirroring.

It reaches the navigator, publication, engine adapter, bridge session, and reader page state through `ReaderProgressHosting`, which `ClassicReaderModel` implements. `ClassicReaderModel` keeps the UI-facing `startAutoSaveTimer/stopAutoSaveTimer/saveProgress/saveProgressResolvingVisibleOverlay/flushProgressToServer` as thin forwarders.

**TOC**: `publication.tableOfContents()` flattened into `ClassicTOCEntry { id, link: ReadiumShared.Link?, depth, displayTitle, href }` (EbookReaderView.swift:1262); positions from `publication.positionsByReadingOrder()` → `totalPages`.

**Selection / highlights / annotations**
- Readium `SelectableNavigator`: `navigator(_:shouldShowMenuForSelection:)` sets `pendingSelection`; `addAnnotationFromSelection(style:colorHex:note:)`, `addAnnotation(text:note:style:colorHex:)`, `updateAnnotation(...)`, `removeAnnotation(...)`, `addBookmark(title:note:)`, `removeBookmark(_:)`, `vocabEntryFromSelection()`
- Rendered as Readium **Decorations** (`navigator.apply(decorations:in:)`) with custom `HTMLDecorationTemplate`s for strikethrough/squiggly/note-indicator (ClassicReaderModel.swift:312)
- Persistence: `Services/Reader/ReaderArtifactsStore.swift` (`ReaderArtifactsStore.shared` — `save/loadBookmarks(bookId:)`, `save/loadAnnotations(bookId:)`, `save/loadCachedChapters(bookId:)`; this is the "BookmarksStore") fronted per-book by `ReaderArtifactsAdapter` (also mirrors into SwiftData `AppState.shared.bookStore` and schedules Obsidian export). Models: `Models/Reader/Bookmark.swift` (`position: TimeInterval` = progression 0–1 for ebooks, `locator: String?` = Locator JSON), `Models/Reader/ReaderAnnotation.swift`. Remote sync: Booklore notebook merge in-model (`syncNotebookEntriesIfNeeded`) + `Services/Reader/AnnotationSyncService.swift`.

**Search**: `func search(query: String)` → `ReaderSearchModel` → `Services/Reader/EbookSearchService.swift`, which uses Readium's search service and returns locator-backed results.

---

## 3. Theming — Readium preferences API + JS injection (both)

- Settings struct: `ClassicReaderAppearance` (`Reader/Engine/ClassicReaderAppearance.swift`), persisted under `enve.ebookReaderAppearance.v2`. `ReaderAppearance.swift` remains for migration.
- Applied via **Readium preferences**: `appearance.readiumPreferences` / `readiumPreferencesForFixedLayout` build `EPUBPreferences`; live changes go through `nav.submitPreferences(...)` (debounced 100 ms Combine pipeline on `$appearance`). Theme maps to Readium `.light/.sepia/.dark` + explicit `backgroundColor/textColor` for paper/eink.
- **JS/CSS injection on top** (per chapter, re-run on `locationDidChange`): custom-font `@font-face` base64 injection (`injectCustomFontCSS`), bionic reading (`ReaderBionicScript.makeScript`), safe-area CSS fix. Fonts: `Services/ReaderFontLibrary.swift` — Google Fonts download/import, `readiumDeclarations: [AnyHTMLFontFamilyDeclaration]` fed into `EPUBNavigatorViewController.Configuration(fontFamilyDeclarations:)`.
- UI chrome colors (`shellBackgroundColor`, `accentColor`, `panelBackgroundColor`, …) are computed on the appearance struct so the SwiftUI shell matches the page.

---

## 4. Read-along (audio–text sync) — EPUB 3 Media Overlays end to end

There is no `Services/ReadAlong` folder; the stack is:

- **`Services/Reader/EPUB3SMILParser.swift`** parses SMIL and extracts per-book audio.
- **`Services/Reader/MediaOverlayPlayer.swift`** plays and navigates media-overlay clips.
- **`Reader/Engine/ReaderReadAloudAdapter.swift`** holds `ReadAloudPlaybackCoordinator`, the read-aloud state store: player, clips, timeline, clip/fragment index maps, follow flags, and the page-follow and decoration throttles.
- **`Reader/Engine/ReaderReadAloudController.swift`** owns read-aloud and media-overlay behavior on top of that store: SMIL preparation, playback transport, overlay decorations, page follow and pre-flip, visible-fragment queries, media-overlay timeline and player-position calculation, and position restoration. It reaches the navigator, publication, progress, and Storyteller activity through `ReaderReadAloudHosting`, which `ClassicReaderModel` implements. `syncPositionNow` computes the spoken position and hands it to `ReaderProgressController` as a `ReaderReadAloudPositionCommit`; it does not persist or push progress itself.
- **Pipeline**: `ReaderReadAloudController.beginPreparation(publication:navigator:force:)` starts SMIL preparation, which wires `player.$currentFragmentId` → `applyOverlayDecoration` (Readium Decorations in group `"read-aloud-overlay"`; sentence highlight + word underline, granularity modes auto/word/sentence, configurable color) → `autoPageToFragmentIfNeeded` (scrolls or `nav.go(to:)` to keep the spoken fragment visible) → `schedulePagePreflipIfNeeded` (turns the page `readAloudPageTurnLeadMs` before the last visible clip ends). `ClassicReaderModel` keeps the UI-facing API and forwards it: `toggleReadAloud()`, `syncAudioToVisiblePage()`, `handleReadAloudTap(at:in:)` (tap a sentence → seek audio), the transport commands, `hasMediaOverlay`, `overlayClipCount`, `currentOverlayClipIndex`, `overlayPlayer`, `isReadAloudMode`.
- **Manual page turn behavior**: `locationDidChange` while read-aloud is active and not audio-initiated calls `readAloud.markManualNavigationIfNeeded(at:)` — bumps a generation counter, cancels pending pre-flips, sets `userDidPageTurn` (auto-reset after 1 s); if `appearance.readAloudSkipOnPageTurn`, `syncAudioToVisiblePage()` seeks the audio to the first visible fragment (300 ms debounce, generation-checked).
- **StoryAlign (local alignment, iOS 26+)**: `LocalPackages/StoryAlign/` (StoryAlignCore + vendored ZIPFoundation, using Apple SpeechAnalyzer; `richwaters/StoryAlign` port). `Services/StoryAlignService.swift` (`@available(iOS 26.0, *)`): `downloadAndConvert(ebook:audiobook:)` → `AlignmentSession` + `StoryAligner().alignStory(session:)` → **an aligned EPUB with generated SMIL overlays** → `registerReadAloudBook` creates a synthetic `Book` (`id: "storyalign_<id>"`, `epub3Features.hasMediaOverlay = true`, `readAloudSourceStableId`, library "Read Aloud"). The reader then treats it as any overlay EPUB. Gate: `Services/StoryAlignAvailability.swift`.
- **Storyteller server variant**: `StorytellerProvider.downloadReadaloud(for:)` fetches a server-aligned EPUB; `Services/StorytellerReadaloudOfflinePrep.swift` extracts its audio for offline; `open()` prefers cached readaloud EPUBs first.
- **Audio-only mode**: `Services/Reader/MediaOverlayPlaybackService.swift` maps overlay audio time to ebook locators.
- **Listen Along**: `Services/Metadata/EbookAudiobookLinker.swift` and `Services/Reader/EbookChapterSyncService.swift` map ebook chapters to linked audiobook time.

---

## 5. ReadAloud TTS (synthesized)

`Services/Reader/EbookTTSService.swift` wraps Readium's speech synthesizer. Its UI lives in `Screens/Reader/ReaderTTSSheet.swift`.

## 6. CompanionReading services

`Services/CompanionReading/` = the "Read together" Apple-TV casting feature:
- `CompanionBroadcasterService` — Bonjour + NWListener, single TV receiver; `start(book:)`, `sendPage(image:pageIndex:totalPages:chapterTitle:)`, `sendHighlight(rect:pageSize:pageIndex:)`, `sendMediaOverlayState(isPlaying:)`, `stop(reason:)`; handlers for TV→phone `pageCommandHandler`, `viewportInfoHandler`, read-aloud commands.
- `CompanionReadingProtocol.swift` — wire types (`CompanionMessageEnvelope`, `PageFramePayload`, `HighlightPayload`, `PageCommandPayload`, `ViewportInfoPayload`, video-stream messages).
- `CompanionScreenCapture` / `CompanionVideoEncoder` — live video mirror mode.
- `ServerConnectionCloudKitSync`, `SharedKeychainStore` — share server connections/credentials with the tvOS app.

`Reader/Engine/ReaderCompanionController.swift` owns the phone side of the session: `CompanionBroadcasterService` handler registration and teardown, TV→phone page and read-aloud commands, the receiver-viewport column policy, the video mirror, navigator snapshots, and page/read-aloud-state/highlight broadcasting. `ReaderCompanionSnapshot` is its state store (active flag, screen capture, video-stream flag, column override, highlight throttle) and `ReaderCompanionLayoutPolicy` holds the pure aspect-ratio and page-index math.

The controller reaches the navigator, appearance application, page navigation, and read-aloud transport through `ReaderCompanionHosting`, which `ClassicReaderModel` implements. `ClassicReaderModel` keeps the UI-facing API and forwards it: `startReadTogether()`, `stopReadTogether()`, `isReadTogetherActive`, `castingCanvasSize`. It also keeps `effectiveReflowablePreferences`, which folds the controller's column override into the Readium preferences it builds for the navigator.

## 7. Book → open flow, formats, comics

`Reader/Engine/ReaderPublicationSession.swift` owns the opening resources for one reader session: the `AssetRetriever` / `PublicationOpener(parser: DefaultPublicationParser(...), onCreatePublication: TokenSearchInstaller.publicationTransform)` pair, the resolved asset URL, the active `Publication`, the Grimmory EPUB streaming session, the streamed-positions task, and the open task. It hands `ClassicReaderModel` an `Opened { publication, fileURL }` result; the model applies publication-backed state, configures the EPUB engine, and builds the navigator.

`Reader/Engine/ReaderPagedContentController.swift` owns the page-index reading engine — every format whose position is a page number rather than a locator. It holds the comic page list and page index, the server-reported ebook format, the PDF page index plus the last stable PDF page, the `PDFReaderController`, and the ComicInfo direction with the appearance baseline that invalidates it. It owns page-family detection (`isComicBook`, image-folder detection, server-page-streaming eligibility), the effective comic layout and RTL progression, the landscape spread step, the server format refresh, the streamed/archive/PDF/image-folder opens, page stepping and bookmark seeks, PDF page observation, comic page setting with its stats and prefetch side effects, page-index restore, and the streamed-session teardown. `ReaderPagedPagePolicy` holds the pure spread, clamping, layout, and detection math.

`Reader/Engine/ReaderInitialLocationResolver.swift` answers one question for an opened EPUB: where should this publication open? It receives `Book`, `LibraryBookCache`, `ReaderTOCIndex`, and `ReaderReadAloudController` at construction, and takes the `Publication`, the pending `EbookReaderInitialSelection`, the EPUB bridge checkpoint, the active `ReaderEngineKind`, and the media-overlay position flag as call inputs. It returns a `ReaderInitialLocation { locator, locatorJSON }` and owns nothing else: `ClassicReaderModel` still clears `pendingInitialChapterSelection`, writes `epubBridgeSession.setRestoreTarget(...)`, and calls `progress.noteInitialLocation(...)` after the decision.

Its ranking, in order: an explicit chapter selection (its own locator JSON, then the TOC entry, then the chapter position locator); a bridge checkpoint that is still current for the book record; then the stored-position ranking. `ReaderInitialLocationPolicy` holds the pure thresholds and the ranking itself — checkpoint freshness (a one-second clock-skew grace before `Book.lastUpdate`), the 0.02 Foliate raw-locator tolerance, and `storedRanking(...)`, which returns `[.overlayRestore]` for a media-overlay book (so a progress locator can never override the overlay timeline), `[.progressLocator]` when synced progress beats the stored locator by more than 0.02 and clears the 0.001 floor, and otherwise `.snippetSearch` (highlights of eight characters or more) before `.progressLocator` before `.storedLocator`. A linked-audiobook calibration hint is tried ahead of that ranking when the book is not read-aloud-like, has no stored locator, and the linked audio position is at least as recent as the ebook. `validating(_:readingOrderHrefs:)` drops a locator whose href is no longer in the reading order and clears its locator JSON with it, then backfills the JSON for a locator that survived.

The paged controller reaches reader state, the session snapshot, artifact loading, and the tap handler through `ReaderPagedContentHosting`, which `ClassicReaderModel` implements. The model keeps `State`, `totalPages`, `visiblePageRange`, and `pendingInitialChapterSelection`, passing that selection into each local paged open; streamed comics continue restoring persisted progress instead. The controller calls `pagedWillChange()` before mutating state that was previously `@Published`, so the model still republishes it to SwiftUI. The model's `ReaderProgressHosting` conformance reads comic and PDF state from the controller.

`ClassicReaderModel.open()` starts with the server-format refresh, then **server page streaming** for comics without a local file (`ReaderPagedContentController.openServerStreamedComicIfAvailable()` → `ServerPageStreamingService.shared.streamedPages(for:provider:)`, providers with `.serverPageStreaming` capability — Komga). That step opens the comic and returns before any asset resolution; otherwise the model asks `ReaderPublicationSession.resolveAsset(openStreamed:)` for the asset. Resolution order inside the session:
1. Cached readaloud EPUB (`LocalEbookImporter.shared.cachedReadaloudEpub(forBookId:)`)
2. StoryAlign narrated EPUB (`StoryAlignService.shared.cachedNarratedEpubURL`, iOS 26+)
3. Local file (`LocalEbookImporter.shared.resolveExistingLocalEbookURL(bookIdentifier:ebookFileURL:filePath:)`)
4. Storyteller readaloud download (`StorytellerProvider.downloadReadaloud`)
5. Provider download fallback (`provider.downloadEbook(for:onProgress:)`), then `AppState.mutateBook` to store the path.

Steps 4 and 5 are both reached through `UnifiedDownloadService.prepareReaderAsset(for:)`.

A Grimmory streamed EPUB is attempted after step 3 misses and before the step 5 download, and it *opens* there: the `openStreamed` callback runs inside that branch so a failed streamed open still falls through to the download path. `resolveAsset` returns `.streamed`, `.file(URL)`, `.downloadFailed`, `.notFound`, or `.cancelled`; the model owns the error alert and `State` for each. `Services/Reader/ReaderOpenCoordinator.swift` is the separate *pre-presentation* download coordinator and is not part of the in-reader session.

Formats (`enum EbookFormat`, `Models/LocalLibrary.swift:396`): `epub`, `pdf`, `cbz`, `cbr`, `mobi`, `azw3`, `azw`, `imagefolder`.
- **MOBI/AZW/AZW3** → `Services/Import/MobiConverter.swift` + `KF8Reader.swift` (native Swift PalmDB/KF8 parser) `convertMobiToEpub` → opened by Readium; DRM detected (`MobiConversionError.encrypted`); fallback `extractHTMLForWebKit` → `readyHTML` WKWebView.
- **CBZ/CBR/imagefolder** → `Services/ComicArchiveService.swift` (ZIPFoundation + `LocalPackages/UnrarKit`; reads ComicInfo.xml manga direction) → `[URL]` pages → `ComicReaderBridge` (paged UIPageViewController with RTL/spread/zoom, or vertical scroll mode), opened and owned by `ReaderPagedContentController`. Comics never go through Readium.
- **PDF** → PDFKit directly (`PDFReaderController`, also owned by `ReaderPagedContentController`).
- **EPUB** → Readium (`openPublication(at:)`), with `copyToCanonicalLocation` retry for local imports.

---

## The contract a new reader UI would code against

A new UI can be built **without touching the engine** by treating these as the API surface:

1. **`ClassicReaderModel`** (rename/move aside, it is UI-agnostic apart from `UIApplication` orientation checks): construct with `Book` (+ optional `EbookReaderInitialSelection`), call `startIfNeeded()`, render by switching on `state`, embed the `EPUBNavigatorViewController` in your own representable, observe the `@Published` set, and call: `pageForward/pageBackward`, `navigateTo(locator:/link:)`, `navigateToTOCEntry`, `seekToBookmark/seekToAnnotation`, `addBookmark/addAnnotationFromSelection/updateAnnotation/removeAnnotation`, `search(query:)` + `searchService.results/next/previousResult`, `appearance` (set the struct; engine persists + applies), `toggleReadAloud/syncAudioToVisiblePage/handleReadAloudTap`, `startTTS` + `ttsService`, `startReadTogether/stopReadTogether`, `saveProgress/flushProgressToServer`, `cleanupOverlayPlayer` on dismiss.
2. **Persistence/sync contracts already wired inside the model** (a new UI gets them for free): `ReaderArtifactsStore`/`ReaderArtifactsAdapter`, `ReaderLocatorProgress`, `BookProgressStore`/`SyncCoordinator`/`KOReaderSyncService` fan-out, server hydration + conflict resolution, ReadingStats/ReadingSpeed trackers, Obsidian export. All of the position half is owned by `ReaderProgressController`.
3. **Locator invariants**: positions are Readium Locator JSON (use `locator.jsonString` — property, not method, on Readium 3.11); never mint CFIs for Booklore/Grimmory (use `EpubLocationBridge` percentage form).

## Renderer recommendation

**Build the new reader UI on the existing Readium 3.11 `EPUBNavigatorViewController` stack and reuse `ClassicReaderModel` as the engine.** Reasons:

- The read-along pipeline (SMIL parsing, fragment→Decoration highlight, auto-page/pre-flip, StoryAlign output) is built directly against Readium navigator APIs (`go(to:)`, `apply(decorations:in:)`, `evaluateJavaScript`).
- Keep Readium rendering in `enve/Reader/Engine/`, reader services in `enve/Services/Reader/`, and presentation in `enve/Screens/Reader/`.
