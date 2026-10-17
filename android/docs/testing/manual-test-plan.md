# Manual Test Plan

On-device checklist for release verification. Automated builds and unit tests prove the code compiles and its logic holds; they do not prove the app works. Run the sections that cover what changed, and run the whole plan before tagging a release.

Install and launch a debug build:

```sh
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am force-stop com.enve.app.debug
adb shell am start -n com.enve.app.debug/com.enve.app.MainActivity
```

Keep `adb logcat --pid=$(adb shell pidof com.enve.app.debug)` running throughout. A pass requires a clean log — no `FATAL`, Hilt, Room, or Compose recomposition errors.

Several sections need setup that a bare device cannot provide: a live server with real books, a multi-track and a single-file audiobook, a media-overlay (SMIL) book for read-aloud, and an e-ink device. Record those as blocked rather than skipping them silently.

## Setup

- [ ] A live server connection (Audiobookshelf, Grimmory, Komga, Plex, or Storyteller) with real books
- [ ] At least one multi-track audiobook, one single-file audiobook, and one EPUB
- [ ] A media-overlay book for read-aloud
- [ ] An e-ink device attached and visible to `adb devices`

## Shell and navigation

- [ ] MantelBar shows the Hearth, Library, and Journal tabs; tapping switches; the selected tab is ember
- [ ] With a book playing, the bar shows the now-playing pill with cover, progress ring, title, and chapter subtitle
- [ ] Tapping the pill opens the player; tapping its play/pause toggles without opening the player
- [ ] The pill disappears when playback stops
- [ ] Player, detail, and settings overlays open and dismiss with both the close control and system back
- [ ] The configured start tab is honored on cold launch

## Home

- [ ] Greeting reflects time of day; the gear opens Settings
- [ ] The hero shows the most recent in-progress book with cover, title, author, progress ribbon, and time left
- [ ] The primary action starts the book — audio goes to the player, ebook to the reader
- [ ] Tapping the hero cover or a shelf cover opens book detail
- [ ] In-progress and recently-added shelves populate correctly and respect the configured shelf order
- [ ] Pull-to-refresh triggers a library refresh
- [ ] Empty state shows with no library or connections

## Library

- [ ] Search filters as you type across title, author, series, and narrator
- [ ] Status chips filter correctly
- [ ] The sort menu reorders the grid
- [ ] Books, Series, and Authors facets each drill down and return with back
- [ ] Covers show the progress ribbon overlay once started
- [ ] Grid density matches the configured column count
- [ ] Large library: scrolling stays smooth with no jank or OOM

## Book detail

- [ ] Cover, title, subtitle, author, narrator, and series link render
- [ ] Progress ribbon and status line are correct; the primary action is media-aware
- [ ] Description expands and collapses; the details grid is populated
- [ ] The in-series shelf appears for series books and re-navigates
- [ ] Listen or Read starts playback or reading

## Player

- [ ] Starting an audiobook shows cover, chapter overline, title, and author
- [ ] Play/pause and skip forward/back work
- [ ] The chapter scrubber seeks, shows chapter boundaries, and updates elapsed and remaining
- [ ] Speed selection applies live
- [ ] Sleep timer counts down, cancels, and stops playback at zero; end-of-chapter works
- [ ] Chapters sheet highlights the current chapter and seeks on tap
- [ ] Bookmarks add at position, list, jump, and delete
- [ ] Multi-track audiobooks report continuous position; seek lands correctly across track boundaries
- [ ] Switching from book A to book B never shows A's progress on B
- [ ] Queue: Play All, add next, add last, reorder, and remove behave
- [ ] Media notification and lock-screen controls work; audio focus is released for calls and other apps
- [ ] Resume position is correct on reopen

## Reader

- [ ] An EPUB opens from Hearth into the reader
- [ ] Tapping the center toggles chrome; chrome auto-hides after idle
- [ ] Back closes; the Librarian action opens
- [ ] The progress ribbon seeks and the page/percentage/chapter line updates on page turn
- [ ] Appearance: theme cards change the page live; text size, line height, and margin steppers apply; typeface picker applies; paged and scrolled both work
- [ ] Contents: TOC navigates, bookmarks add/jump/delete, highlights jump/delete
- [ ] Search returns results and jumps to a match
- [ ] Selection annotate bar applies highlights, underline, strike, and save-to-vocabulary; annotations persist
- [ ] Read-aloud on a media-overlay book: narration starts, sentence highlight follows, skip works, pages auto-turn
- [ ] Progress persists across close and reopen; pull-on-open resolves cross-device position
- [ ] PDF and comic readers open and page correctly

## Settings

- [ ] Theme mode switches the whole app live; OLED toggle applies; accent swatches change the ember
- [ ] UI text scale and reduce motion apply
- [ ] Playback skip intervals and default speed persist and apply to new playback
- [ ] E-Ink mode chips, bold text, and refresh strength persist and take effect
- [ ] Connected libraries list shows each connection with enable toggle and remove
- [ ] Sync now refreshes; About shows the expected version
- [ ] About opens the website and Privacy Policy at `envemedia.com`
- [ ] Open-source licenses opens, shows the resolved dependency list, and opens every bundled notice

## Android Auto

Run these checks through a compatible vehicle or the supported Desktop Head Unit, using the same APK as the phone checks. MediaBrowser instrumentation and unit tests are supplemental evidence.

- [ ] Listen on the phone, continue from the car, pause in the car, disconnect, and reopen on the phone; resume at the latest car checkpoint
- [ ] Seek while paused, including an intentional rewind to zero and a seek across audiobook files; pause, stop, and disconnect retain the chosen absolute position
- [ ] Repeat with downloaded audio while offline, reopen, reconnect, and confirm the latest checkpoint reaches the provider without replaying an older position
- [ ] Delay or fail a server progress response while advancing or rewinding; a late acknowledgement cannot replace the local checkpoint
- [ ] Recreate the playback service, remove the phone task, and recreate the app process through supported user flows; resume from the persisted checkpoint (allow the five-second interval during uninterrupted playback)
- [ ] Use books with matching provider IDs on different connections and confirm progress remains scoped to the selected book
- [ ] Reconcile a newer remote checkpoint on both phone and car; unresolved conflicts retain local playback and the phone offers the existing conflict choice
- [ ] With server sync disabled, car progress still saves locally and sends no provider write
- [ ] Disable or remove connection A while its write waits; an enabled connection B with the same source must receive no request
- [ ] Disable the active connection, then stop/clear and switch profile; local checkpoint/history shutdown completes without sending a provider request or hanging
- [ ] Refresh the catalog during car playback, including a pending offline zero rewind; refreshed metadata must retain the current local checkpoint
- [ ] After a successful normal push, open a newer checkpoint from another device; an acknowledged pending row must not hold local playback indefinitely
- [ ] Reopen a zero checkpoint through both the Hearth phone player and the legacy phone player when the provider session suggests a positive position
- [ ] Block a local checkpoint save, stop and clear the queue, then destroy the service through supported user flows; the captured terminal checkpoint must persist
- [ ] With a fixture containing future server last-read metadata, seek to zero, pause, stop and reopen; fresh local checkpoints must persist
- [ ] Use injected checkpoint times to simulate wall-clock rollback without changing the device clock; elapsed-time throttling, zero rewind and shutdown saves must still work
- [ ] Block the session state mutex after capturing 120 seconds, save a newer zero seek, then release it; the older snapshot must be superseded and must not acknowledge a newer pending snapshot
- [ ] Hold local persistence after capturing a zero seek while an earlier automatic remote pull completes; the remote mirror must yield and the zero must still save. An explicit remote choice may replace an earlier local capture, but a seek captured after that choice must win
- [ ] Commit a zero checkpoint and pending push between the resolver cache/pending reads; opening returns the coherent zero checkpoint
- [ ] Submit REMOTE in the phone conflict prompt, then seek to zero before its continuation runs; that later seek must prevent the mirror and remain saveable
- [ ] Delay ABS session close, native listening-history upload, or Silo session progress while resetting or marking an audiobook finished; the final provider and phone position must reflect the latest intended operation


- [ ] Enve appears in the media launcher on a compatible car or Desktop Head Unit
- [ ] Recently played, downloads, and provider/library browsing load without unsafe or dead-end rows
- [ ] Selecting a playable book starts playback and updates title, author, artwork, duration, and position
- [ ] Play/pause, previous/next, rewind, and fast-forward controls drive phone playback
- [ ] Voice search finds a book and either plays the requested result or presents safe browsable results
- [ ] Artwork content URIs resolve from the car process and never expose an authentication token
- [ ] Disconnecting and reconnecting restores the active media session without duplicating queue items

## Sources and providers

- [ ] Add a connection for each provider under test and complete its auth flow
- [ ] Libraries refresh and books appear after adding
- [ ] Re-auth works when a token expires
- [ ] Two accounts on the same host route to the correct server — no cross-connection bleed
- [ ] Disabling a connection hides its books; re-enabling restores them
- [ ] Removing a connection removes its books and credentials

## Journal

- [ ] Stat cards match reality
- [ ] Library-at-a-glance counts are correct
- [ ] The finished shelf appears when finished books exist and opens detail on tap

## E-ink

- [ ] On an EPD device the palette is pure black and white on every screen
- [ ] No shadows, gradients, glow, or animation
- [ ] Navigation triggers a full refresh with no ghosting
- [ ] Reader page turns follow the configured refresh strength; margin taps turn pages
- [ ] The library falls back to the dense single-column list
- [ ] Vendor detection picks the right profile
- [ ] Forced check on a normal phone: Settings → E-Ink → On flips the whole UI to black and white; reset to Auto afterward

## Downloads and offline

- [ ] Downloading an audiobook succeeds and it plays offline from local tracks
- [ ] Downloading an ebook succeeds and it opens offline
- [ ] Covers are cached; the Downloaded filter reflects state
- [ ] Interrupting a download and resuming continues rather than restarting
- [ ] Airplane mode: cached books open and play; uncached books fail gracefully
- [ ] Close and immediately reopen a streamed comic; pages remain available after cleanup

## Sync and progress

- [ ] Audio position and ebook locator push to the server after playing or reading
- [ ] Advance on one device, open on another: pull-on-open offers or applies the newer position
- [ ] Finished status syncs
- [ ] Offline progress queues and flushes on reconnect
- [ ] Sync Center's pending count changes when persistent retries are added or cleared
- [ ] Connect two Grimmory servers with the same book ID; progress and narrator backfills remain independent
- [ ] Edit a KOReader link while another book syncs; both links survive

`PublicSourceRegressionTest` covers these cases with isolated profiles and local server fixtures. `ProfilePersonalStoresTest` verifies profile persistence and late writes without changing the owner's data.

## Wear companion

- [ ] The watch app reaches the phone app and shows the current book, position, and recent books
- [ ] Play/pause and skip on the watch drive phone playback
- [ ] Opening a recent book from the watch starts it on the phone
- [ ] Starting and cancelling the sleep timer from the watch is reflected on the phone

## Stability

- [ ] Rapid tab switching and overlay open/close leaves no stuck state
- [ ] Rotation does not crash
- [ ] Backgrounding during playback keeps audio; returning restores state
- [ ] Process death and relaunch restores the last book and the now-playing pill
- [ ] Long titles and author names ellipsize on every screen

## TorBox verification — 2026-10-10

Tested the debug app on a connected Pixel 7a with one real TorBox account and one available 20-track MP3 audiobook. The download contains 518.7 MB of audio with a measured total duration of 577.14 minutes. The release app was not replaced.

### Device UI results

| Workflow | Result |
|---|---|
| Valid token sign-in, folder discovery, selecting folders, Use All | Passed |
| Empty token form and rejected token | Passed; rejected token stays on sign-in with a clear error |
| Source and library filters | Passed |
| Search for an existing title and a missing title; clear search | Passed |
| Grid column changes and list layout | Passed |
| Manual and repeated refresh | Passed; one book and 20 tracks remain |
| Refresh without Wi-Fi or mobile data, then reconnect | Passed; cached book remains and refresh recovers |
| Streaming, pause/resume, 30-second skips, next/previous chapter | Passed |
| Chapter selection and chapter progress slider | Passed |
| Playback speed | Passed at 1.5×; restored to 1× |
| Bookmark creation, persistence through restart, jump, deletion | Passed; test bookmark removed |
| End-of-chapter sleep timer | Passed; playback pauses at the boundary |
| Download, cancel/restart, network interruption/recovery, completion | Passed |
| Remove-download confirmation, cancel removal, confirmed removal | Passed |
| Download persistence after process restart | Passed |
| Offline playback | Passed; sampled every one of the 20 tracks through UI chapter controls with Wi-Fi and mobile data disabled |
| Offline cold-start resume | Passed at 3:18:57 in the book, preserving the chapter and track offset |
| Screen-off playback and media play/pause controls | Passed |
| API artwork | Passed; HTTP 200 image/jpeg, Coil decode succeeds, artwork renders in library, mini-player and full player |

Wi-Fi and mobile data were restored. Playback is paused near the original position with the original three-column library layout and empty search. The downloaded audiobook remains available on the debug install.

### Automated results

- 848 unit tests passed: app 194, engine 606, Hearth UI 48; zero failures or errors.
- `TorBoxLibraryLoadingTest`: 3 device tests passed. Covers concurrent source scans and selected folders, rejected-token credential preservation, and native Android duration extraction when the API provides no duration.
- Unit fixtures cover logical API failures, authentication failures, bounded network/server retries, numeric/date Retry-After handling, cancelled and superseded scans, failed-scan pruning prevention, account isolation, and API/WebDAV identity and artwork merging.
- Debug and minified release builds passed with no new compiler or R8 warnings.

### Coverage limits

- TorBox currently supplies audiobooks only. EPUB/PDF reading through TorBox is not implemented.
- Real playback coverage is the available multi-track MP3 book. Other audio formats, WebDAV-only playback, and additional real accounts need suitable test data; M4B file discovery/merging is covered by fixtures, not a real M4B UI playback test.
- No cast receiver, Android Auto head unit, or watch was exercised in this pass.
- The account has one available audiobook, so a real multi-book queue transition was not tested.
- Backend rate limits and server outages were simulated in unit fixtures; the UI connection-loss test used disabled device networking.


## Android app UI audit — 2026-10-10

Tested the debug app on a physical Pixel 7a, using the existing TorBox account and original local EPUB, three-page PDF, three-page CBZ, and two short MP3 fixtures. The release app was not changed. This supplements the TorBox results above.

### Fixes verified on the phone

- Profiles now exits through both the screen Back button and Android Back when opened as a settings bridge.
- Licenses respects the status bar; all 24 bundled notices opened without a missing-notice error.
- Reader theme labels select the theme along with their preview tiles.
- Local scans preserve completion, reader position, and continue-reading visibility; a finished PDF remained finished after refresh.
- The landscape player scrolls to expose speed, chapters, and More; More opens its tools. Portrait controls remain visible.
- Returning from a settings bridge preserves the original tab and settings category.
- Sync Center says Updates pending while queued progress exists. One pending item remained after manual sync; this pass did not establish delivery of that item.
- Disabled sources disappear from book lists and library counts; re-enabling the fixture source restored all six cached sample entries and their completion flags.

The TorBox refresh test now waits for its obsolete folder scan to start before invalidation, avoiding a test setup race where cancellation occurred before the loader ran.

### UI coverage

| Area | Checks completed |
|---|---|
| Navigation | All four tabs, all seven settings categories, bridge return state, Profiles setup and Back |
| Appearance | Paper and Ink themes, accent changes, extra-large app text, forced e-ink mode, startup tab persistence through cold start |
| Library | Refresh, source enable/disable, sort priority, audio and finished-book filters, local folder picker/import |
| EPUB | Open/reopen position, page flow, contents jump, search results, font and size changes, theme-label selection, bookmarks, saved bookmark note, highlight creation and deletion |
| PDF | Next/previous pages, final-page completion, reopened position, portrait and landscape rendering |
| Comics | Page swipes, scroll mode, theme changes, reopened position |
| Audio | Local play/pause, persisted skip intervals, Play Next and queue removal, automatic transition between two sample audiobooks, portrait and landscape player |
| Podcasts | Browse, show details, follow/unfollow, streamed episode confirmed playing through Android media session, pause |
| Downloads and tools | Download list and storage rendering, opening a downloaded book from settings; metadata/server summaries; reader/custom-font settings; Sync Center; KOReader/CrossPoint setup; Obsidian annotation count |
| Other screens | Journal, stats and insights; sleep-health setup; vocabulary and dictionaries empty states; Hidden Books; StoryAlign empty inputs; Hardcover sign-in; About and all 24 bundled notices |

### Automated verification

- Debug and minified release builds passed; no new compiler or R8 warnings.
- Unit suite: 1,144 tests discovered, 1,143 passed, zero failures/errors, one skipped live Grimmory format-sync test requiring a lab server.
- 73 device tests passed: Room migrations and cache queries, isolated profile stores and switching, public-source regression, TorBox loading, and read-aloud lyrics.
- Changes remain local and uncommitted.

### Remaining coverage

- This was one phone, not a tablet, other Android versions/OEMs, a real e-ink panel, or a TalkBack audit.
- Other providers need live accounts for authentication, catalog, playback, and sync verification. Profiles setup was inspected without changing the owner's profile configuration; isolated profile behavior was covered by device tests.
- DRM books, complex/large documents, full synchronized narration, other audio formats, multitouch comic zoom, and large catalogs were not exercised.
- Cast, Android Auto, Wear hardware, phone-call audio focus, and headset controls still need the corresponding devices or conditions.
- Health authorization, alignment jobs, external vault export, purchases, and support submissions were not performed.
- TorBox ebook support remains unimplemented. No claim is made that every app state or device combination is glitch-free.

### End state

Removed the fixture source and folder, its cached library entries, its downloaded comic, all four test annotations, and the temporary podcast subscription. The original TorBox source and downloaded audiobook remain; playback is paused, and the library is back to three columns with default filters. Appearance, text size, startup tab, skip intervals, and rotation settings were restored. Short sample reading/listening history and the sampled podcast episode position may remain in the debug app; user history was not cleared. Final process log check: zero fatal exceptions, ANRs, playback exceptions, or IllegalStateExceptions.


## Boox read-aloud report — 2026-10-10

### Changes

- Keep the EPUB viewport and read-mode header insets constant while Android's system bars appear/disappear. Showing controls no longer changes pagination.
- Block the underlying EPUB gesture detector while read mode owns touches. A single tap shows/hides controls; double-tapping a sentence deliberately selects that clip.
- Preserve an existing read-aloud media session when selecting another sentence. Previously the reader cleared the shared player before attempting to seek, causing lost playback and a chapter-start reset.

### Verification

- Physical Pixel 7a with forced e-ink mode and an original EPUB containing 15 SMIL segments and five minutes of embedded audio. This was not a physical Boox test.
- Ordinary EPUB controls: visible paragraph bounds stayed identical while controls were shown and hidden.
- Read mode: paused at sentence 6, tapped another sentence to show/hide controls, and confirmed clip 6 and visible line bounds remained unchanged.
- Double-tapped sentence 8: selected clip 8 at approximately 2:20, played, then paused through the UI without a source error or chapter-start reset.
- Underline annotations: selected a word, used Underline, reopened its editor to confirm the saved style, and visually confirmed the underline in the reader. The temporary annotation was removed. Automatic narration currently offers highlighting; an underline narration preference was not added because the report's meaning remains unclear.
- Six read-mode device tests passed, covering single-tap control actions without seeking, double-tap selection, close, narrated lines, blank lines, and empty chapters.
- All 194 app unit tests passed, with zero failures/errors/skips.
- Debug and minified release builds passed; the final build had no compiler or R8 warnings.

The changes remain local and uncommitted. The public prerelease has not been updated. Physical Boox behavior still needs confirmation.

Temporary narration books, their source folder and cached library entries, the test underline annotation, and the instrumentation package were removed. E-ink mode was restored to Auto. The original TorBox source and download remain. Final process check found zero fatal exceptions, ANRs, playback errors, or IllegalStateExceptions.

## Read-aloud page-turn controls — 2026-10-10

- Added a persisted “Skip audio on page turn” switch, independent of “Turn pages with read aloud.” Its default preserves the previous enabled behavior.
- Read-mode controls stay visible until explicitly hidden; entering read mode cancels the normal reader's auto-hide timer.
- Pixel 7a, narrated EPUB fixture: disabled skipping preserved paused audio at 74,912 ms across page changes and playing audio continued from 74,916 to 78,011 ms without seeking. Enabled skipping moved playback to 200,016 ms when navigating to the last page.
- Reinstalled the final debug APK and cold-started the app: both disabled page-turn settings persisted. With automatic page turning enabled and skipping disabled, manual page changes left playback above 220 seconds; narration subsequently returned the reader to the active sentence's page.
- Read-mode controls remained available beyond 20 seconds while narration played. Single taps hid/revealed controls without changing the paused audio position. Final APK also checked with narration paused.
- Verification: debug and minified release builds succeeded; 194 app unit tests and six HearthReadAloudLyrics device tests passed. No Kotlin/R8 warnings; Gradle emitted an SDK XML tooling version warning (SDK XML v4 versus command-line support for v3).
- Physical Boox behavior remains unverified; this device check used the Pixel 7a. Removed the temporary local source and fixture folder and restored both page-turn settings to enabled.

### Follow-up UI run — forced e-ink and rotation

- Ran the narrated EPUB through the actual Pixel 7a UI with e-ink forced on. Normal reader sentence bounds remained identical when controls were hidden/revealed. Read-mode controls stayed visible beyond the former 15-second timeout.
- Paused at 41,292 ms: single taps on another sentence hid and revealed controls without changing playback or foreground sentence bounds. Double-tapping sentence 5 selected clip 5 and started playback at 80,028 ms.
- Disabled both page-turn settings: a paused page turn retained 92,425 ms; turning to the last page while playing continued at 95,546 ms. Re-enabled audio skipping: navigating away from the current clip moved playback to the first page at 0 ms.
- Rotated portrait/landscape: read-mode transport buttons remained visible and the paused position was retained. Found and fixed a separate layout issue: ReadAloudSheet now scrolls, so lower preferences and chapter clips are reachable in landscape. Installed the rebuilt APK and verified scrolling to clips and toggling both page-turn settings there.
- Debug and minified release builds passed, with 194 app unit tests passing. No Kotlin/R8 warnings; the existing SDK XML tooling warning remains. Runtime log counters for fatal exceptions, ANRs, ExoPlaybackException, and IllegalStateException were zero.
- Restored portrait/automatic rotation, automatic e-ink detection, and both enabled page-turn preferences. Removed the temporary fixture source and folder. Physical Boox hardware has not been tested.

### Bigme hardware run — 2026-10-10

- Connected Bigme identifies as HiBreak, Android 14, 1264×1680. Installed the debug APK alongside the existing release app; release app data was not accessed or changed.
- Automatic e-ink detection selected the monochrome Hearth layout. Imported an original narrated EPUB into an isolated temporary local source.
- Read-mode controls remained visible while narration advanced beyond 40 seconds. Paused at 46,395 ms: single taps hid/revealed controls without changing audio position or foreground sentence bounds. Double-tapping sentence 5 started clip 5 at 80,089 ms.
- With audio skipping disabled, a page-edge tap changed from sentences 1–8 to 9–15 while paused playback stayed at 84,626 ms. Fast swipes also changed pages. With skipping enabled and narration playing, a page-edge turn selected clip 9 at 160 seconds; subsequent playback advanced to 166,128 ms.
- Paused playback survived portrait/landscape rotation. Read-mode controls were accessible in landscape; the settings sheet scrolled to the lower toggles and clip list.
- Disabled settings persisted across a cold start. Restored both page-turn settings to enabled, original automatic rotation, and portrait orientation. Removed the temporary source and its fixture folder.
- Runtime counters for fatal exceptions, ANRs, ExoPlaybackException, and IllegalStateException were zero. Actual Boox hardware remains untested; this run used Bigme hardware.
- All six HearthReadAloudLyrics instrumentation tests passed on the Bigme (16.739 seconds). Uninstalled the instrumentation package and left the debug app installed for further testing.


## BookOrbit SSO — 2026-10-10

- Configured BookOrbit 3.2.0 with a dedicated Authentik confidential client in the private lab. Authorization-code and refresh-token grants, RSA signing, native callback allowlist, and existing-account linking are configured. Credentials and endpoint addresses remain in ignored local instructions. Lab doctor passed.
- On the connected Bigme, the debug app completed identity-provider sign-in and returned through `bookorbit://oauth2-callback`, saved the BookOrbit connection, and loaded 794 books across four libraries. The connection survived installing the final APK and restarting the app.
- Streamed the chaptered M4B fixture, sought to the previous chapter, observed advancing PLAYING state with full buffering, and paused at 55 seconds.
- Reproduced HTTP 401 opening an EPUB through the unauthenticated reader client. After switching EPUB/PDF downloads to the authenticated profile client with the book connection scope, the namespace-prefix EPUB rendered Unicode text and a server highlight; the synthetic PDF rendered page 1 of 1.
- AuthBrowserCallbackTest and OAuthCallbackIntentFilterTest passed on the Bigme (2 tests). Android debug and minified release builds passed, and all 194 app unit tests passed with no new warnings. The installed debug APK hash matched the final build.
- iOS already uses the native callback. Callback state/code validation and enabled-provider selection were tightened, and authorization-endpoint query items are preserved. Swift parsing passed. The iOS build and live UI test remain blocked by existing Booklore access-control compile errors; approval to repair those unrelated files is pending.
- The live identity provider was Authentik. Pocket-ID and an expired-token refresh were not exercised.
