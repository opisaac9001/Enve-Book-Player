# Apple TV read-along

Updated 2026-10-24. The television reader uses the EPUB's existing SMIL alignment. Highlight granularity follows the publication's sentence or paragraph anchors.

## Behavior

- Cover artwork, chapter progress and remaining time sit beside centered, scrolling text. The current passage stays bright; surrounding passages are dimmed. The artwork supplies the background wash.
- Up/down browses aligned passages without moving the audio. Select seeks a browsed passage while preserving the playing or paused state. Left/right skips 15 seconds on the narration clock, carrying the remaining distance across audio files and chapters.
- Select on the current reading surface opens the controls. They provide previous/next passage, play/pause, 15-second skips, speed, narrated chapters and text size. Follow narration returns to the reading surface.
- Controls hide after five seconds only in the reading mode while playing, with no chapter picker, passage browsing or VoiceOver interaction. Paused or focused controls stay visible. Reduce Motion disables animated scrolling; increased contrast brightens contextual text.
- Text size persists. Local television resume positions preserve the chapter-qualified fragment and offset into its audio clip, saving on pause, navigation, exit and every 15 seconds while playing. A newer locator on the supplied book takes precedence. This change does not add cross-device progress publishing.
- Read Along on TV is available for media-overlay and Storyteller books before a local file exists. Preparation uses the existing `UnifiedDownloadService.prepareReaderAsset` path.

## Alignment and preparation

Clip identity includes both canonical chapter href and fragment ID. Audio-clock reconciliation handles skipped callbacks and sample rounding at a paused seek. Global clip ranges are half-open; gaps between aligned clips do not highlight the next passage early.

The loader follows OPF spine order and declared media-overlay links, preserving SMIL order within a chapter. XHTML parsing keeps an aligned element's complete text, including nested formatting and line breaks. Audio retains its EPUB directory structure. Missing files fail during preparation; playback errors pause narration. Extraction uses a staged cache with a source size/modification-time fingerprint.

References fetched and reviewed before implementation:

- Silveran Reader `origin/main`: `669a56903316fa51bf9c2850bdc89d9bbcac37dc` — `SMILPlayerActor`, `SMILTextPlaybackViewModel`, tvOS `TVPlayerView`.
- Storyteller `origin/main`: `b821e0f4eb6c7c960386c90fa5cc1c7c84bfcd2d` — SMIL model/lookup, media-overlay seek tests and entry-boundary tests.

Both checkouts were clean and already at the fetched upstream `main`. The changes adapt their behavioral contracts without copying their source.

## Commands and results

From the app repository root, with `ENVE_BUILD_DIR` pointing to the external build directory:

```sh
./scripts/test-tv-readalong
```

47 regression checks passed. These compile the production SMIL/timeline/text-parser and progress-store sources directly, checking repeated fragment IDs, encoded paths, exact boundaries, sample rounding, cross-chapter skips, silent gaps, audio reuse, OPF ordering, nested anchors, verse, omitted `clipBegin`, and persisted resume isolation.

```sh
xcodebuild -project enve.xcodeproj -scheme enve-tvOS \
  -destination 'platform=tvOS Simulator,id=<tv-simulator-udid>' \
  -derivedDataPath "$ENVE_BUILD_DIR/DerivedData-tvOS" build
```

The Apple TV 4K simulator uses tvOS 27.0, arm64. The build succeeds without source-exclusion command-line overrides. The target now excludes the iPhone-only `HearthTabStack`, `HingeStateStore` and `KokoroTTSVoice` sources. Existing CloudKit `Sendable` and App Intents metadata-extraction warnings remain; the changed sources introduce no warnings. The initial baseline also reported existing libsmb2 C conversion warnings.

```sh
xcodebuild -project enve.xcodeproj -scheme enve -testPlan AllTests \
  -destination 'platform=iOS Simulator,id=<iphone-air-simulator-udid>' \
  -derivedDataPath "$ENVE_BUILD_DIR/DerivedData-main" \
  -resultBundlePath /tmp/enve-tv-readalong-ios-tests.xcresult \
  -parallel-testing-enabled NO -quiet test
```

`xcresulttool get test-results summary` reports **Passed**: 1,639 tests passed, 35 skipped, zero failures and zero runtime warnings. Parameterized cases produce 1,937 passing executions on iPhone Air.

## Runtime verification

The debug root accepts `-tvReadAlongBook <title fragment>` for a library book, or `-tvReadAlongFile <absolute EPUB path>` for a local fixture. Optional fixture arguments are `-tvReadAlongTitle`, `-tvReadAlongAuthor` and `-tvReadAlongCover`. Fixture books use separate IDs based on their filenames. Copy fixtures into the simulator's current app data container after installing; reinstalling can change the container path.

Verification uses a two-chapter EPUB containing locally synthesized narration, a nonzero audio lead-in, inter-passage gaps, reversed manifest order, repeated `s1`/`s2` fragment IDs and a generated cover. Missing-audio and corrupt-audio variants exercise failure states. No downloaded library content or credentials are checked in.

Confirmed with simulator HID keyboard events routed through the tvOS controls:

- Aligned narration advances into the second chapter with its own repeated fragment IDs.
- Play/pause stops the displayed clock; next-passage and chapter selection preserve pause.
- Browsing does not seek until Select, and the selected passage highlights while paused.
- Select opens the transport controls. The chapter picker, speed menu and text-size controls are reachable through directional focus. Selecting 1.5× updates the speed without starting paused audio.
- Missing narration produces an actionable preparation error with Retry and Done.
- Controls disappear during uninterrupted playback and reappear on pause; a focused control stays available.
- After terminating and relaunching, the saved third passage resumed at 0:12 rather than the beginning. A paused 30-second skip crossed into chapter two at 0:07; a 15-second rewind returned to chapter one at 0:27, retaining pause.
- A corrupt first audio file displays an error and retains chapter one at 0:00 / 0%, rather than silently skipping to chapter two. The position remains stable on a later snapshot.

The initial simulator tests used a local aligned EPUB. Physical Grimmory playback was subsequently verified below. VoiceOver speech and a live Storyteller server download remain device/account verification gates.

## Physical Apple TV installation

On 2026-10-23, built and installed the signed Debug `enve-tvOS` app on an Apple TV 4K (3rd generation), running tvOS 27.0:

```sh
xcodebuild -project enve.xcodeproj -scheme enve-tvOS -configuration Debug \
  -destination 'platform=tvOS,id=<paired-device-udid>' \
  -derivedDataPath "$ENVE_BUILD_DIR/DerivedData-tvOS-device" \
  -allowProvisioningUpdates build
```

The first physical launch exposed an existing startup crash: the owner profile tried creating its database and audiobook folders under Documents and Application Support, which the device sandbox rejected with Cocoa error 513. `ProfileStorageLocations` now defaults those roots to Caches on tvOS. Explicitly supplied roots and the iOS defaults retain their existing behavior. The device successfully created `Library/Caches/BookStore.sqlite` and the profile's folders, and Enve reached Connect a library. Files in Caches remain purgeable by tvOS; this does not implement permanent offline storage.

The Home Screen banner previously placed the logo against the left edge, where tvOS cropped it. `scripts/generate-tv-top-shelf` now exports the layered `BuildSupport/AppIcon/enve-book-player-tv.svg` into centered landscape icons and both banner sizes at 1× and 2×, using `rsvg-convert`. The banners pair the mark with Book Player typography, following the Video Player layout. The earlier centered banner was verified on the physical Home Screen; the 2026-10-26 branding refresh has simulator and generated-artwork verification only. Installation updated the app in place without uninstalling it or clearing its data.

After the storage change, AllTests passed again: 1,639 passed, 35 skipped, zero failures and zero runtime warnings. The 47 read-along regression checks passed again. The physical target builds with zero errors and no new warnings; the final incremental artwork build reported no warnings.

The source-publication check `./scripts/verify-provenance` remains blocked by an existing machine-specific path in `docs/testing/kokoro-on-device.md`, outside this change.

## Connection sharing and sign-in

Physical iPhone-to-TV verification exposed two CloudKit failures: an empty library-selection array could not initialize a new field, and querying connections required an unavailable `recordName` index. All-libraries records now explicitly clear the selection field, and connection bootstrap reads paginated zone changes. Both shared server connections reached the TV after updating the apps in place.

The saved logins were not usable on the TV. Grimmory was verified through the TV's username/password form: authentication succeeded, the library populated, and book details remained available after relaunch. Signing in to an existing server account updates its connection instead of adding a duplicate. Audiobookshelf's connection transferred, but its authentication still needs verification.

The final shared-code AllTests run passed: 1,642 tests passed, 35 skipped, zero failures and zero runtime warnings, with 1,940 parameterized executions. Three new regression tests cover initial and cleared CloudKit library selections. Both physical app targets built with zero errors and no new warnings; the subsequent TV sign-in form change also built successfully and was exercised on the physical TV.

## Server editing and publication reading

On 2026-10-24, added a selectable editor to saved server rows. The editor preserves the connection UUID, library selection, saved credentials and other settings; blank password/token fields keep the current credential. Address or account changes require credentials again. SSO and certificate-backed addresses stay managed on iPhone. The TV's add-server list now displays Grimmory while retaining the persisted provider identifiers. Physical verification opened the existing Grimmory connection, edited its name field, restored its original name, and saved with the password field blank. The connection remained present once and the authenticated library continued loading.

TV covers now use the existing authenticated image/cache path in library cards, details, the player, mini-player and read-along. Covers were verified on the physical TV, including the user-requested Grimmory book *Two Twisted Crowns*. Its Read Along action downloaded and played the aligned EPUB, advanced highlighted passages and crossed into the prologue. Narration was paused after verification.

The reading entry point inspects the prepared publication rather than assuming every file is EPUB. PDFs render through Core Graphics; CBZ/CBR use the existing comic archive service, now linked into the TV target. Image pages fit inside the safe reading area, support the native Reader Controls panel for zoom and page navigation, and retain local page progress. Zoomed pages can be panned to their bottom edge. ComicInfo reading direction controls manga page turns. These caches remain purgeable by tvOS.

For ordinary EPUBs, Core Text lays out and draws the same fitted page frame in the measured space between the chapter heading and footer. Source-page and UTF-16 offsets preserve the exact reading position when pages reflow; existing chapter/page positions still decode. Narration is discovered from the EPUB's declared media overlays on preparation, including when the server's listing lacks a read-aloud flag. Known narrated books also offer text-only reading. This requires an aligned read-aloud EPUB, not an unrelated audiobook and ebook pair.

Verification:

- The final iPhone Air AllTests run passed: **1,642 passed, 35 skipped, zero failures and zero runtime warnings** (1,940 parameterized executions).
- `./scripts/test-tv-epub` passed **1,872 checks**, including glyph bounds, complete text coverage, Unicode boundaries, long prose, verse, resized viewports and larger type.
- `./scripts/test-tv-readalong` passed **47 checks** again.
- Simulator interaction verified complete PDF portrait/landscape pages, page turns, saved page restoration, 150% zoom, panning to the bottom, CBZ and CBR decoding, and right-to-left manga navigation. Long prose continued exactly on the next fitted EPUB page; chapter navigation reached the verse chapter without hiding its bottom lines.
- A synthetic aligned EPUB with Audiobookshelf source identity and no narration metadata automatically opened the read-along player and advanced its highlight. This checks post-download detection; live ABS authentication/download remains unverified because that account is not signed in on the TV.
- Both TV simulator and physical builds succeeded. Changed app sources introduce no warnings. Existing CloudKit conformance and App Intents metadata warnings remain; the first TV compile of the existing Unrar library also reports its existing C++ warnings.

The DEBUG-only `-tvReadFile <absolute path>` opens a local EPUB, PDF, CBZ or CBR fixture through the same reader entry point. `-tvReadSource audiobookshelf` can assign a provider identity without creating a connection or using real credentials. Fixtures and device logs remain outside the repository. Final device launch uses normal app arguments.

## Hearth palette refresh — 2026-10-26

The tvOS shell, connection flows, player, reader chrome and text now use the Book Player's implemented Hearth Ink palette: brown surfaces, cream text and the existing custom ember accent. Cover images, PDF/comic pages and mirrored publication content retain their original colors. Native controls retain system focus foregrounds.

Before the color-only read-along changes, fetched and reviewed Silveran Reader `669a56903316fa51bf9c2850bdc89d9bbcac37dc` (`ReaderTheme`, tvOS `TVPlayerView`) and Storyteller `8641b51102e0b5d58ea4185ef1b0f7505d97ad49` (`applications/mobile/lib/theme.ts`, `colors.ts`). Silveran was current; the clean Storyteller checkout was fast-forwarded to upstream main. Palette work leaves alignment, narration, pagination and progress behavior unchanged.

Validation: `scripts/test-tv-epub` passed 1,872 checks; `scripts/test-tv-readalong` passed 47. All 13 branding PNGs match catalog dimensions and references, and regeneration is deterministic. The tvOS simulator build succeeded using:

```sh
xcodebuild -project enve.xcodeproj -scheme enve-tvOS \
  -destination 'platform=tvOS Simulator,id=83C83CE8-DC0A-4177-BBAF-2E6B463575DE' \
  -derivedDataPath /tmp/EnveBookTV-DerivedData \
  COMPILER_INDEX_STORE_ENABLE=NO build
```

The final build reported zero errors and no new warnings; the existing CloudKit Sendable and App Intents metadata-extraction warnings remain. The clean baseline also reported existing dependency warnings. Build output moved to the internal drive after the games volume ran out of space; only the failed task-created build directory was removed.

Installed and launched the tvOS app and inspected Home, Settings, plain EPUB rendering and the read-along screen with local synthetic content. The centered landscape icon is visible in the simulator launcher; generated standard/wide Top Shelf images were inspected separately. Interactive remote/focus verification and physical Apple TV parallax verification remain pending: the Mac was locked during this task.

## Feature audit — 2026-10-26

See [Apple TV read-along and reader audit](tvos-readalong-audit.md) for seven findings, live lab verification, playback-engine checks and remaining device gates. The highest-priority finding is loss and overwrite of local TV resume when a newer remote position cannot be resolved. Application behavior was not changed during the audit.
