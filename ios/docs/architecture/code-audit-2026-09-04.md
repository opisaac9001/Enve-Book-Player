# iOS Book Player audit — September 4, 2026

## Assessment and scope

The app has real integration and reliability defects; it is not ready for an unconditional clean bill of health. This audit made focused reliability, transport and OAuth corrections, added regression coverage, compared provider contracts with vendored servers and peer clients, ran native tests and disposable-service checks, and exercised the iPhone UI. Open findings below remain unmodified.

This is a broad, risk-led audit, not a claim that every line or every possible service configuration has been verified. The inventory covered 641 unprotected main-app Swift files, two shared Swift files and the existing 77 test files. Structural scans covered that inventory; detailed reading concentrated on providers, sync, storage, playback, reader boundaries, and representative UI. The owner subsequently authorized bypassing the audit locks. The protected authentication, Keychain, TLS, mTLS, OAuth and browser-login sources were then reviewed, including a bounded independent review of `LoginDelegates.swift`. Lock markers remain intact. Static review does not establish that every interactive sign-in, expired-token or certificate configuration works.

Repository: `Enve-Book-Player-iOS`, branch `main`. Existing modifications to `PlexProvider.swift`, `AudiobookPlaybackCoordinator.swift`, and the untracked `PlexAlbumGroupingTests.swift` were preserved. Nothing was committed, pushed or published. Reference repositories were read-only. Claude CLI review could not authenticate; two bounded read-only Codex reviews supplemented the primary review. The primary agent inspected the findings and owns the builds, tests and UI checks.

## Corrections made

| Severity | Defect and correction | Code / verification |
| --- | --- | --- |
| P1 | A completed outbox request could delete a newer queued position; a failed old request could suspend, drop or back off that newer position. Check the exact entry before sending and again after awaiting the response. | `PendingSyncQueueFlusher.swift:105`. Tests cover success, 401, 404, transient failure, and replacing a later entry while an earlier request is suspended. |
| P1 | Store initialization deleted the original SQLite files even if backup failed. Recovery now requires a successful backup before deletion. Backup pruning happens only after a complete copy, partial failed copies are removed, and unique names prevent same-second collisions. | `BookStoreManager.swift:68`, `StoreBackup.swift`. Tests cover repeated backups, store/WAL contents, and retaining the previous backup after destination creation fails. Actual disk-full startup recovery was not fault-injected. |
| P1/P2 | Hardcover combined `.convertFromSnakeCase` with explicit snake-case CodingKeys, so selected mutation results could decode as nil. Remove the conflicting, now-redundant CodingKeys. | `HardcoverService.swift`, `HardcoverResponseDecodingTests.swift`. Native tests use real response DTOs and representative snake-case payloads. |
| P2 | Hardcover reading-progress, edition, rating, review and read-completion methods discarded mutation-level errors. Validate the returned payload; read creation requires a positive returned ID rather than treating missing data as ID zero. | `HardcoverService.swift`. Tests reject nested errors and missing results. No authenticated Hardcover writes were made. Existing server-schema compatibility fallback paths remain outside this correction. |
| P2 | A superseded playback request could start after its asynchronous persisted-book lookup and clear the newer request. Recheck cancellation and request identity after the lookup. | `PlaybackQueueCoordinator.swift:249`. Existing playback tests pass; manual playback/seek/chapter checks pass. The exact disk-lookup race was established from code, not deterministically reproduced in the simulator. |
| P2 | Automatic sleep calculated a local clock time by adding elapsed seconds to midnight, moving the window on daylight-saving transition days and potentially rearming it. Construct the local hour/minute using Calendar. | `AutoSleepService.swift:16`. Tests cover both 2026 Los Angeles transition nights and continuity after midnight. |
| P1 | Public hostnames such as `10.example.com` inherited the private-IP certificate-trust exception. Require four numeric IPv4 octets within range; reject ambiguous leading-zero forms. | `NetworkHostUtils.swift`, `AuthenticationStorageTests.swift`. Covers public names, malformed addresses, allowed private/CGNAT ranges and range boundaries. No live hostile-certificate interception test was performed. |
| P2 | Saving and decoding OAuth tokens reset their issue time, extending apparent validity on every launch. Encode and restore `issued_at`; fresh server responses without it use receipt time. | `OAuthManager.swift`, `AuthenticationStorageTests.swift`. Expired-token round trip and fresh-response cases. Previously saved tokens contain no recoverable issue time and need a successful refresh or reauthorization before this persistence correction applies. |
| P2 | OAuth token requests used URL-query escaping for form bodies, which leaves reserved `+`, `&` and `=` characters incorrectly encoded. Use a shared form-body encoder for code exchange and refresh. | `OAuthManager.swift`, `AuthenticationStorageTests.swift`. Reserved delimiters, spaces, percent signs and Unicode tested against an exact expected body. Removed a user-facing error that instructed users to edit the Swift source. [OAuth specification, Appendix B](https://www.rfc-editor.org/rfc/rfc6749#appendix-B). |

The changes use existing owners and contracts. No dependency, architecture, signing, entitlement or design system was changed. The private-IP TLS exception was narrowed to actual IPv4 addresses; the existing local DNS suffix policy was preserved.

## Open findings

These are audit findings, not completed fixes. They need focused implementation and regression/live verification before they can be closed.

1. **P1/P2 — Incomplete WebDAV scans are returned as complete catalogs.** `WebDAVProvider.swift:1031` catches a directory PROPFIND failure and omits that subtree. `fetchBooks` consumes the scan, and `WholeSnapshotCatalogProvider` in `LibraryProvider.swift:410` packages the returned books as a completed snapshot. A temporary directory failure can therefore produce a known-incomplete mirror and authorize removal of absent rows. Required directory failures should fail the snapshot and preserve the old mirror. Cancellation deserves the same treatment.
2. **P2 — OPDS pagination is capped by navigation depth.** `OPDSProvider.swift:159–194` uses a depth limit of four and increments it for each `next` page, so a flat acquisition feed can silently stop after five pages. It also silently limits navigation branches to 24. A full-import capability must not equate these bounded partial results with a complete catalog. Separate page iteration from navigation depth and make incomplete traversal explicit. This was found in source; a six-page fixture was not run.
3. **P2 — ABS delta imports omit the ebook half of dual-format items.** `AudiobookshelfProvider.swift:1308` calls `convertItemToBook`; full catalog mapping at line 738 calls `convertItemToBooks`, which creates the `_ebook` companion at lines 1806–1835. `LibraryCatalogCoordinator.swift:997` actively uses delta refresh between complete reconciliations. New dual-format items can lack the readable companion until a full refresh. Reuse the plural mapping and test incremental/full parity.
4. **P2 — Komga collection membership uses series IDs as book IDs.** `KomgaProvider.swift:181–198` copies `seriesIds` into `Collection.books`. `LibraryEngine.swift:1093–1106` looks those up as provider-scoped book IDs, with no series expansion. The reference `komga-client/.../collection/KomgaCollection.kt:20` explicitly identifies them as series IDs. Expand series to book memberships with complete pagination before committing the collection snapshot.
5. **P2 — Kavita collections decode a nonexistent membership field.** `KavitaProvider.swift:128–145` expects `seriesMetadatas`, defaults to an empty array, and imports a zero-book collection. The vendored `Kavita.Server/Controllers/CollectionController.cs:42–46` returns `AppUserCollectionDto`, which has `ItemCount` and no `seriesMetadatas`. Membership needs a separate filtered series query; the server enum defines `CollectionTags = 7`. Verify populated and empty collections separately.
6. **P2 — Kavita stored-token expiry is not recovered.** `KavitaProvider.swift:296–297` accepts any non-nil JWT; `send` at 347 has no 401 refresh/re-authentication path. The vendored `Kavita.Services/TokenService.cs:51` issues a ten-day token. Fresh lab login passed, which does not exercise an expired persisted token. Authentication changes need a separate verified flow.
7. **P2 — Komga series stop at the first 500 results.** `KomgaProvider.swift:203–226` requests only page zero of a paginated endpoint. Reference `komga-client/.../series/KomgaSeriesClient.kt:18–21` and `HttpSeriesClient.kt:24–28` confirm paging. Follow all pages and test a library with more than 500 series.
8. **P2 — Exhausted transient retries silently discard pending progress.** `PendingSyncQueueStore.swift:104–114` removes the entry after the retry budget. This conflicts with the documented outbox promise that failed user mutations remain queued until acknowledged. Preserve exhausted updates with an explicit recoverable state rather than making them eligible for replacement by a server pull. The race correction above does not change this retry policy.
9. **P2 — KOReader bulk merge is capped and forward-only.** `KOReaderSyncService.swift:180` reads only the first 5,000 ebooks; line 210 accepts only a higher percentage, ignoring a newer rewind/reset. The native KOReader client considers timestamps and allows explicitly pulled backward progress (`plugins/kosync.koplugin/main.lua:839–877`). Establish the intended conflict policy, then cover rewind, reread, reset, stale response and large-library cases. The local wire implementation uses the expected auth headers, document hash, percentage and device fields; that alone does not establish interoperability of every locator.
10. **P2 accessibility — Compact navigation speaks icon names.** `MantelBar.swift:173–216` has icon-only compact/liquid tab buttons with identifiers but no destination labels. Simulator accessibility snapshots reported “Flame,” “books.vertical,” “Radio,” and “Lyrics.” Use the existing `HearthTab.title` and expose selection state. This was observed in the running UI.


11. **P1 security/storage — Restoring an archived Plex account writes its token into UserDefaults.** `ServerConfigStore.swift:18–20` JSON-encodes `BackendConfig` directly; that model includes `token`, `password` and `customHeaders`. The active restoration path in `PlexSessionLifecycleService.swift:70–86` populates `token` and calls this method. This bypasses the documented Keychain-only policy. Move secrets to scoped Keychain entries and migrate/remove persisted plaintext through a tested storage change. SMB configurations do not contain passwords and use the separate Keychain path.
12. **P2 — mTLS session credentials are not scoped to the challenged host.** `MTLSManager.swift:235–243` resolves one identity for a URLSession; `MTLSURLSessionDelegate` supplies it to every client-certificate challenge without comparing the host. Storyteller and Silo construct these sessions. A redirected or other cross-origin request using that session can present the client identity to another server. Restrict presentation to the configured origin and test redirects with two controlled TLS endpoints. No live certificate-disclosure test was performed.
13. **P2 — Concurrent ABS 401 responses can cancel each other's refresh.** `ABSCredentials.swift:128–141` cancels the existing task in `forceRefresh`, while every task unconditionally clears `refreshTask` in its defer. A cancelled older task can clear the reference to its replacement; callers can also observe cancellation instead of sharing a refresh. Coalesce forced refreshes and test simultaneous unauthorized responses with token rotation. This interleaving was established from source, not reproduced against the lab.
14. **P2 — Storyteller and Emby login discard custom headers.** `LoginDelegates.swift:1288–1309` and `1326–1344` omit them from Storyteller's temporary and returned connections, despite `StorytellerProvider.swift:131–134` supporting them. The Emby path at `832–869` neither sends nor retains them. Servers requiring proxy/API headers can fail login or subsequent requests. Test password and browser-token completion with required headers; successful unprotected lab login does not cover this.
15. **P2 — Malformed Grimmory OIDC issuer can crash login.** `LoginDelegates.swift:353` force-unwraps a URL derived from server-provided `issuerUri` after only checking nonemptiness. Validate the discovery URL at this network boundary and return a configuration error. PKCE/state concerns were not labeled as proven bypasses: the ABS reference server validates state, and backend verification matters.
16. **P2 — Credential replacement deletes before adding.** `KeychainHelper.swift:12–24`, `SecureTokenStorage.swift:63–80`, and `SharedKeychainStore.swift:164–169` delete an existing item before adding its replacement. A failed add can lose the previous credential; `KeychainHelper` also discards the failure status. Prefer `SecItemUpdate` and add only for a missing item. Ordinary replacement tests alone do not prove behavior when Keychain writes fail; no real credentials were fault-injected.

The unused Dropbox OAuth configuration also inherits Google's `access_type=offline`; Dropbox requires `token_access_type=offline` to issue a refresh token ([official Dropbox OAuth guide](https://developers.dropbox.com/oauth-guide)). No call site for `OAuthConfig.dropbox()` was found, so this is dormant configuration debt, not a reproduced user-facing Dropbox failure. The mTLS identity picker deduplicates using the first 32 DER bytes rather than a certificate hash, which can collapse distinct identities with the same prefix; a multi-certificate fixture is still needed. Browser cookie extraction uses path-prefix matching rather than path-segment boundaries. These were recorded without expanding the patch into untested authentication rewrites.

## Live service results

The existing `ProviderLiveSyncTests` harness ran on the arm64 iPhone Air, iOS 26.4.1, using the ignored disposable-lab document. Credentials remained in memory and were not copied into the test plan, repository, report or prompt. The harness restores selected fixture progress and closes test sessions; server timestamps/history are not rolled back. These tests do not cover every catalog item except where explicitly noted, collections, token expiry, background execution or interactive login.

| Service | Current result | Limit |
| --- | --- | --- |
| Audiobookshelf | Passed: login, sample catalog, ebook download, 42%/finished/reset, audio ranges/seek and 23s/reset round trip | Dual-format delta parity, podcast and background playback not covered |
| Jellyfin | Passed: login, 30,275 catalog entries, ebook download, audio range/seek and position/reset | No native ebook-progress capability; expiry not exercised |
| Emby | Passed: login, catalog and ebook download | Lab exposes only one ebook; no native audiobook playback verified |
| Plex | **Failed progress round trip:** sent 23s, read back 0s; catalog and byte-range playback passed | Followup UI investigation found that the server is now claimed and the app has an authenticated source, while CLAUDE.local.md and the harness still use anonymous access. This failure describes the anonymous test identity; authenticated UI sync remains under investigation |
| Komga | Passed: login, sample catalog, download and page-quantized progress/finished/reset | 42% resolves to 25% for the four-page fixture; collections and >500-series behavior not tested |
| Kavita | Passed: login, sample catalog, download and page-quantized progress/finished/reset | 42% resolves to 33.33%; collections and expired-token recovery not tested |
| Grimmory | Passed: login, sample catalog, download, ebook round trip and audio range/seek/position/reset | Reset can return no progress record; large catalogs and all compatibility tiers not covered |
| Storyteller | Passed: login, sample catalog, download, ebook round trip and audio range/seek/position/reset | Interactive OAuth and SMIL/read-aloud alignment not covered |
| BookOrbit | Passed: all three libraries, all 19 catalog/detail records, download, ebook round trip and audio range/seek/position/reset | No populated-collection or large-library limit test |
| Silo | Latest rerun passed: authentication, one library / ten ebooks, download, 42%/finished/reset round trip | The first run failed authentication. No Silo auth correction was made; the earlier failure remains unexplained. No native audio fixture exercised |

Latest rerun after the TLS correction: **9 passing and 1 failing parameterized service cases**, zero reported runtime warnings. Plex is the remaining failure (23 seconds sent, zero read back). The earlier run passed eight and failed Plex plus Silo; the Silo change in outcome is not attributed to a verified fix. The first selector attempt executed zero tests and is not counted as verification. The corrected selector and final rerun each executed all ten cases. Real-Debrid, Premiumize, standalone WebDAV/OPDS server round trips, Hardcover account mutations, SMB, cloud-drive providers, iCloud and physical-device integrations were not comprehensively live-tested in this audit.

## Peer/reference comparisons

Reference folders have moved into `Other apps/Book Servers & Sync/` and `Other apps/Book Readers & Players/`; old flat router paths were translated.

- Audiobookshelf server `MediaProgress.js` and `PlaybackSessionManager.js`; ShelfPlayer `Network/API+Progress.swift` and `API+Sessions.swift`: progress, episode identity, session payloads and units. The ABS `isFinished` mapping into an older field named `isAbandoned` is misleading, but downstream code presently folds both into completion; it was not presented as a proven abandonment bug.
- Storyteller `web/src/app/api/v2/books/[bookId]/positions/route.ts`: sampled locator/timestamp payload, 204 success and 409 reconciliation match.
- Komga Kotlin client: series versus book identity and collection/series pagination.
- Kavita server DTOs, collection controller, filter enum and token service: concrete mismatches recorded above.
- Grimmory controller routes: sampled app-book detail, progress and status routes match. Its entire 6,993-line provider and every auxiliary client were not exhaustively validated.
- KOReader server `app/controllers/1/syncs_controller.lua` and reader `plugins/kosync.koplugin/main.lua`: wire shape and timestamp-aware pull behavior.
- BookPlayer `BookPlayer/Player/PlayerManager.swift:205–218`: cancellation after asynchronous asset preparation corroborates the playback ownership safeguard.
- Softcover `ReadingProgressWidget/HardcoverService.swift`: selected Hardcover mutation payloads and nested results corroborate the response-shape review. Peer source is prior art, not proof that every current hosted API version matches.

## Code quality and authorship

There is no reliable way to identify authorship from coding style. The useful bar is whether behavior, ownership and failure handling are clear and tested.

The scan did not find widespread TODO/FIXME stubs, generated walkthrough comments or decorative warning banners in the application Swift inventory. Normal UIKit unavailable coder initializers, fixed-choice UI actions and deliberately unsupported provider capabilities were not mislabeled as unfinished features. `@unchecked Sendable` and large files require contextual concurrency/ownership review; they are not evidence of AI authorship by themselves.

There are concrete maintainability concerns: duplicated metadata/chapter fallback work in Real-Debrid and Premiumize, large coordination/storage types, a legacy completion field with misleading naming, and dead retained state (`PlayerSleepTimerService.fadeOutTask`, `PlayerProgressService.storageService`). These are lower priority than the behavioral defects. No mass formatting or speculative extraction was performed. Redundant Hardcover CodingKeys were removed as part of the relevant correction.

## Verification and artifacts

- Baseline `enve` simulator build: exit 0; quiet log contained no warning/error diagnostics.
- Final `AllTests` after the protected-file corrections: **519 passed, one opt-in test skipped, zero failures, zero runtime warnings**. Counting dynamic parameter cases, Xcode reports 523 successful executions. The earlier pre-authentication pass was 513 tests. New coverage includes host classification, OAuth expiry/form encoding and isolated synthetic Keychain replacement through both stores; both ordinary replacement cases pass. Real credentials were not read or modified by those regression tests.
- App build/install/launch after the initial authentication corrections: succeeded, with no reported build warnings/errors. The earlier app run emitted one warning while extracting **EnveWatch** App Intents metadata: `Metadata extraction skipped, no AppIntents.framework dependency found`. The Watch target was not changed; the earlier warning is retained here rather than implying every audit build was warning-free.
- An initial targeted authentication test attempt stalled in simulator diagnostic collection and was interrupted; it is not counted as a test result. The full retry used `ARCHS=arm64` and `-parallel-testing-enabled NO` and passed.
- `git diff --check`: passed. `./scripts/verify-provenance`: passed.
- Simulator: Hearth, settings, add-source entry, library source/media filters and book details opened. Played/paused the lab multi-disc audiobook, sought forward 15 seconds, and selected Chapter 2 at 0:45 while paused. This does not reproduce the cancellation race or prove server persistence; Plex's server round trip failed separately.
- OPDS reader: opened Alice's Adventures in Wonderland, rendered the cover, navigated through Contents to Chapter II, closed and reopened at location 10 of 82 / 10%. Local reading position was changed by this check. The lab audiobook's local paused position was also changed by manual dogfooding. Lab automated tests restore progress; the manual UI checks do not undo local history.
- Dynamic Type, VoiceOver speech, both shell styles/themes, physical-device/background playback, CarPlay, Watch runtime and tvOS remain unverified.

Commands, from the iOS app root, with `ENVE_BUILD_TMP` set to a writable build-artifact directory:

```sh
xcodebuild -project enve.xcodeproj -scheme enve \
  -destination 'platform=iOS Simulator,id=C971D187-A76A-44A4-A625-7E54F18B0525' \
  -derivedDataPath "$ENVE_BUILD_TMP/DerivedData-main" -quiet build

xcodebuild -project enve.xcodeproj -scheme enve -testPlan AllTests \
  -destination 'platform=iOS Simulator,id=C971D187-A76A-44A4-A625-7E54F18B0525' \
  -derivedDataPath "$ENVE_BUILD_TMP/DerivedData-main" \
  -parallel-testing-enabled NO ARCHS=arm64 \
  -resultBundlePath "$ENVE_BUILD_TMP/Audit-20260904-AuthAfter.xcresult" -quiet test

xcodebuild test-without-building \
  -xctestrun "$ENVE_BUILD_TMP/DerivedData-main/Build/Products/enve_AuditLive.xctestrun" \
  -only-testing:enveTests/ProviderLiveSyncTests \
  -destination 'platform=iOS Simulator,id=C971D187-A76A-44A4-A625-7E54F18B0525' \
  -parallel-testing-enabled NO \
  -resultBundlePath "$ENVE_BUILD_TMP/Audit-20260904-AuthLive.xcresult" -quiet
```

The local `enve_AuditLive.xctestrun` copies the generated test configuration and sets only the lab-document/event-file paths; it contains no copied lab credentials. App build/run and UI checks used XcodeBuildMCP after configuring the same project, scheme and simulator.

Local artifacts: `$ENVE_BUILD_TMP/Audit-20260904-AllTests.xcresult`, `Audit-20260904-Fixes.xcresult`, and `Audit-20260904-LiveRetry.xcresult`. Quiet logs use `$TMPDIR/enve-ios-audit-*.log`. Do not publish raw runtime/service artifacts without checking them for private data.

Protected-file followup artifacts: `$ENVE_BUILD_TMP/Audit-20260904-AuthAfter.xcresult` (519 passing tests), `$TMPDIR/enve-audit-auth-after.log`, `$ENVE_BUILD_TMP/Audit-20260904-AuthLive.xcresult` (nine passing service cases, Plex failure), and `$TMPDIR/enve-audit-auth-live.log`. The interrupted `$ENVE_BUILD_TMP/Audit-20260904-AuthBefore.xcresult` is not verification evidence.

Followup: the full UI investigation is recorded in [ui-lab-audit-2026-09-04.md](ui-lab-audit-2026-09-04.md). The Plex server now reports `claimed=true`, correcting the stale unclaimed-server description inherited from CLAUDE.local.md.
