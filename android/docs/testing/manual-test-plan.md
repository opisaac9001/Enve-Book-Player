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
