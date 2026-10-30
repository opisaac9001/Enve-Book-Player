# Apple TV read-along and reader audit

Date: 2026-10-26. Scope: native tvOS read-along, publication reading, resume, detail actions and Read Together recovery. The findings below preserve the original audit; the follow-up fixes and verification are recorded first.

The audit used the isolated services documented in the ignored local lab guide. Production services were not accessed. No credentials, server addresses or downloaded publications are included here.

## Follow-up fixes

All seven findings have code fixes:

1. Resolve the remote anchor before comparing timestamps. A missing, malformed or unmatched remote locator retains a valid local fragment and offset. A newer valid remote locator still wins.
2. The ordinary reader now uses the existing XML package parser and decoded, package-relative paths.
3. Extraction checks source size/modification time and stages replacement content before replacing the old cache. Page/character offsets are reset on a detected replacement. This fingerprint cannot detect a replacement that preserves both size and modification time.
4. SMIL parsing throws on malformed XML. The loader distinguishes damaged alignment from absent alignment.
5. Detail actions recognize actual audio tracks and linked audiobooks. Further call-chain review found that the TV starter still rejected undownloaded Storyteller audio; it now uses the provider's existing authenticated manifest session, including all tracks and the resolved server position.
6. A failed discovery browser is cancelled and released so Try again can create another one. Callbacks from retired browsers cannot affect the replacement. If an active phone session later disconnects after discovery has failed, the receiver presents retry instead of claiming to be searching.
7. Read-along preparation errors offer Read Text Only, which opens the ordinary reader without auto-routing back into narration. Automatic detection of narration in downloaded publications is preserved.

Verification after fixes:

- `scripts/test-tv-readalong`: **50 passed**, including truncated and trailing-invalid SMIL.
- `scripts/test-tv-epub`: **1,872 passed**.
- `scripts/test-tv-playback <booted-tvOS-UDID>`: **22 passed, zero failed** on tvOS 27. This reproducible harness compiles the production playback class into a temporary app and removes that app afterward. It includes the original two failing resume checks plus malformed JSON, missing chapter/fragment, empty fragments, older remote and obsolete local anchors.
- iOS `AllTests` on iPhone Air: **1,662 test cases passed, 36 skipped, zero failures** (1,973 successful executions including parameterized cases).
- tvOS build: **succeeded, zero errors, zero new warnings**. Existing CloudKit Sendable and AppIntents metadata warnings remain.
- Installed-app reproductions: single-quoted package and encoded filename now render; replacing revision ONE at the same identity displays revision TWO; truncated SMIL displays the damaged-alignment error; missing narration exposes Read Text Only.
- Live lab: the combined Storyteller edition's listen manifest and all three audio resources returned HTTP 200.
- Production streaming proxy on tvOS: all three lab tracks returned valid HTTP 206 byte ranges. The original lab files contain MP3 audio inside MP4; native AVFoundation reports zero duration even for a bundled local copy, so they cannot prove Audio Only playback. A locally converted AAC control reports 19.994 seconds and plays through the unchanged production proxy on tvOS. The lab files were not modified.
- Discovery recovery: **eight injected lifecycle checks passed** in an isolated tvOS app compiling the production receiver and decoder. Checks cover failed-browser release, replacement, stale callbacks, a surviving connection, subsequent disconnect and retry with an existing browser. The harness used a separate test Bonjour service name and no phone connection.
- All 13 TV branding assets retain valid catalog references and regenerate identically.

The Mac remained locked during the follow-up. Remote focus/button activation, signed-in Audio Only from the detail screen and physical phone pairing remain unverified. Rendering and direct engine checks do not substitute for those interactions. The feature gaps listed in the original audit remain outside these bug fixes.

## Upstream implementation comparison

References were fetched again before fixing; both clean checkouts remained at the revisions listed below. Online source review also checked Foliate and Apple's discovery lifecycle documentation:

- [Silveran Reader: SMILTextPlaybackViewModel](https://github.com/kyonifer/silveran-reader/blob/669a56903316fa51bf9c2850bdc89d9bbcac37dc/SilveranKit/Sources/AppleKit/Shared/SMILTextPlaybackViewModel.swift) restores a usable locator and gates progress writes until restoration and user progress. This supports preserving a usable local anchor when a remote position cannot resolve.
- [Storyteller: media overlay cache](https://gitlab.com/storyteller-platform/storyteller/-/blob/8641b51102e0b5d58ea4185ef1b0f7505d97ad49/applications/web/src/progress/mediaOverlays.ts) keys persisted indexes by publication identity and fingerprint and writes through a temporary file. Enve retains its existing extraction design and adds source invalidation to the ordinary reader.
- [Foliate: EPUB and media overlay implementation](https://github.com/johnfactotum/foliate-js/blob/main/epub.js) parses package and SMIL XML, rejects XML parser errors, resolves relative resource URLs and decodes paths. Its media overlay player manages narration separately from the section documents. These patterns support the package-parser fix and text-only recovery path.
- [Apple: failed NWBrowser state](https://developer.apple.com/documentation/network/nwbrowser/state-swift.enum/failed(_:)) documents failure as fatal. Enve now releases the failed browser before retrying.

Behavior was adapted to the existing Enve types; no upstream implementation was copied wholesale.

## Findings

### 1. P1 — A newer, unusable server position destroys the TV resume point

Location: `enve-tvOS/TVStorytellerAudioPlayer.swift:51`.

`restorePosition(for:)` discards the local position whenever `book.lastUpdate` is newer. It then restores only a locator with an exact chapter href and overlay fragment. If that locator is absent or cannot be matched, playback remains at clip zero. Starting playback saves that position over the previous local position.

This is reachable with Grimmory: `BookloreProvider+BookMapping.swift:156` leaves EPUB locators nil, while `:180` takes `lastUpdate` from server timestamps including `lastReadTime`. Using another client can therefore make the TV lose its saved place.

**Reproduced against the production playback class:** saved chapter two at narration time 1.75 seconds, reloaded with a newer server timestamp and nil locator, and observed chapter one at zero. Playing then overwrote the saved chapter-two position with chapter one. The two corresponding assertions failed; fourteen other transport assertions passed.

Resolve a usable remote target before comparing timestamps. If a newer remote position cannot be resolved, retain the local position rather than committing a restart.

### 2. P2 — Ordinary EPUB reading rejects valid package syntax and paths

Locations: `enve-tvOS/EbookReaderView_tvOS.swift:283` and `:294`.

The ordinary EPUB loader uses regular expressions that recognize only double-quoted XML attributes. A valid EPUB with single-quoted `full-path`, `id`, `href` or `idref` attributes fails. Chapter hrefs are also appended as filesystem paths without percent decoding.

**Reproduced in the installed app:** a single-quoted package reports a missing rootfile, and `chapter%20one.xhtml` referencing an existing `chapter one.xhtml` reports no readable text. Both controlled publications contain readable text and valid XML.

Use the existing XML package parser and normalized EPUB path resolution already used by the read-along loader. The standalone parser tests currently do not cover this ordinary-reader path.

### 3. P2 — Replaced EPUBs continue displaying stale extracted content

Location: `enve-tvOS/EbookReaderView_tvOS.swift:269`.

The extraction cache is accepted whenever `META-INF/container.xml` exists. It never compares the current source file with the cached source.

**Reproduced in the installed app:** opened revision ONE, replaced the EPUB at the same path and identity with revision TWO, relaunched, and still read revision ONE. This also prevents an updated or repaired server publication from reliably taking effect.

Use source fingerprinting and staged extraction, as the read-along extraction path already does. Preserve reading offsets only when meaningful for the replacement content.

### 4. P2 — A truncated SMIL file is accepted as partial narration

Location: `enve-tvOS/TVStorytellerSMIL.swift:109`.

`parseAndReturn()` ignores `XMLParser.parse()` failure and returns clips collected before the XML error. The loader can then accept the shortened clip list because its validation checks the returned clips, rather than whether the entire overlay parsed.

**Reproduced with production parser code:** malformed XML returns `false` from XMLParser, while `TVSmilXMLParser` returns one accepted clip and a ten-second timeline. A controlled EPUB containing a truncated overlay and valid audio also opens as a shortened read-along instead of displaying a preparation error.

Propagate parsing failure and reject the complete overlay. Keep missing alignment distinct from malformed alignment in the error message.

### 5. P2 — Combined Storyteller editions lose the Audio Only action

Locations: `enve-tvOS/BookDetailView_tvOS.swift:25`, `:149`; `enve/Networking/Providers/StorytellerProvider.swift:1589`.

Storyteller maps a read-aloud edition to `.ebook`, even when it also has a standalone audiobook. The TV detail view determines audio availability only from `.audiobook` or `.podcast`, so its Audio Only action is hidden for this combined edition.

**Source-confirmed:** the lab catalog includes an aligned edition with both ebook and audiobook assets, matching this mapping. The corresponding signed-in TV detail screen was not exercised because interactive sign-in was blocked.

Determine available actions from the edition's actual available formats or resolved audio companion, rather than its primary media category alone.

### 6. P2 — Read Together retry cannot restart failed discovery

Locations: `enve-tvOS/CompanionReceiverService_tvOS.swift:56`, `:76`; `enve-tvOS/ReadTogetherView_tvOS.swift:118`.

When NWBrowser fails, the receiver publishes an error but retains `browser`. Try again calls `startDiscovering()`, which immediately returns because `browser` is non-nil. The visible recovery action cannot create a replacement browser.

**Source-confirmed; failure not injected on a device.** Clear/cancel failed discovery or provide a restart operation that replaces it before retrying.

### 7. P2 — Automatic read-along routing can block otherwise readable text

Locations: `enve-tvOS/TVBookReaderView.swift:19`, `:99`; `enve-tvOS/StorytellerReaderView_tvOS.swift:126`.

If server metadata does not advertise narration, Read on TV passes `textOnly: false`. Discovering an overlay in the downloaded EPUB automatically switches to read-along. A missing audio file then produces Retry and Done, without a text-only reading action.

**Reproduced in the installed app:** a valid text EPUB with a declared overlay and missing narration was launched through the ordinary publication route. It displayed the narration-file error with no way to continue reading its text. The detail view offers explicit text-only reading when narration is already known; this failure affects automatically discovered narration.

Offer Read Text Only after read-along preparation fails, or retain an explicit text-only route for the original Read on TV action.

## Feature coverage and limitations

| Area | Result |
| --- | --- |
| Storyteller service authentication, catalog and aligned-file download | Verified through live lab API calls |
| Grimmory service authentication, catalog and publication downloads | Verified through live lab API calls; catalog contained 30,285 records |
| Aligned narration and passage highlighting | Verified in the installed app with downloaded Storyteller content |
| Paused seek, rate change, next/previous passage, cross-file skips, rapid seek ordering | Passed direct production-engine checks |
| Automatic audio-file transition, pause clock, local offset resume, completion and restart | Passed direct production-engine checks |
| Newer resolvable server locator | Passed direct production-engine check |
| Newer unresolvable server locator | Failed: finding 1 |
| Missing narration and unaligned publication | Actionable error displayed; text fallback has finding 7 |
| Ordinary EPUB and PDF rendering | Verified with downloaded Grimmory samples |
| CBZ and right-to-left comic metadata | Three-page comic opens and reports right-to-left navigation |
| CBR-labelled lab sample | Opens, but its actual container is ZIP; genuine RAR-backed CBR remains untested |
| Plain EPUB compatibility and cache refresh | Failed controlled cases: findings 2 and 3 |
| Native reading/read-along progress publishing | Not implemented: TV stores local positions; it does not publish these sessions through provider sync or mark server completion |
| Read-along sleep timer, bookmarks and annotations | Not exposed by the standalone read-along player |
| Plain EPUB TOC, search and appearance controls | Not exposed; rendering is a text-only presentation with fixed reader font settings |
| Siri, AirPlay/Bluetooth interruptions, VoiceOver speech, physical remote focus, live phone pairing | Require interactive/device verification |

The transport harness calls production player methods directly. It does not substitute for focus/navigation tests. Existing scene-phase handling pauses read-along when the app leaves the active phase; audio-route and interruption behavior still needs a physical test before asserting a defect there.

## Verification and evidence

- `scripts/test-tv-readalong`: **47 passed**.
- `scripts/test-tv-epub`: **1,872 passed**.
- Temporary tvOS playback harness: **14 passed, 2 failed**, both failures demonstrating finding 1. It compiled the unmodified production playback class, timeline and progress store into an isolated test app with generated silent audio. The temporary app and its data were removed after testing.
- tvOS `enve-tvOS` simulator build: **succeeded, zero errors and zero warnings in this audit's incremental build**.
- Additional malformed-SMIL probe: malformed XML was accepted as one clip; the installed app accepted a truncated-overlay fixture as a shortened read-along.
- The existing AllTests iOS plan was not rerun: this audit changed no application behavior.

Build command:

```sh
xcodebuild -project enve.xcodeproj -scheme enve-tvOS \
  -destination 'platform=tvOS Simulator,id=<tvOS-simulator-udid>' \
  -derivedDataPath /tmp/EnveBookTV-DerivedData \
  COMPILER_INDEX_STORE_ENABLE=NO build
```

Live service authentication/download checks and app rendering checks were separate: downloaded lab publications were opened through the app's existing debug launch routes. The Mac remained locked, so the signed-in server connection UI, remote interaction and end-to-end phone pairing were not verified. No locked authentication source was read or changed. No service configuration, production library or remote progress was modified.

The upstream reference checkouts were fetched before review and were clean/current:

- Silveran Reader: `669a56903316fa51bf9c2850bdc89d9bbcac37dc` — `SMILPlayerActor`, `SMILTextPlaybackViewModel`, `TVPlayerView`.
- Storyteller: `8641b51102e0b5d58ea4185ef1b0f7505d97ad49` — overlay lookup, locator/time mapping and progression contracts.

An independent read-only review was checked against these sources and the local reproduction results. Unconfirmed hypotheses are not counted as findings.
