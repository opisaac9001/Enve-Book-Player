# Service sync validation — 2026-08-30

Validated against the disposable services in the ignored `CLAUDE.local.md`, using the LAN endpoints and an arm64 iPhone Air simulator on iOS 26.4.1. No production server was used. The initial checks left lab configuration unchanged; the subsequent BookOrbit update is recorded below.

## Live results

| Service | Verified | Limits / remaining work |
| --- | --- | --- |
| Audiobookshelf | Login, three libraries, ebook download, ebook partial/finished/reset round trips; audiobook streaming, byte-range seeking, position/reset round trips | Fixtures: Synthetic EPUB and Chaptered M4B Book. Podcast playback was not exercised in this run. |
| Jellyfin | Login, two book libraries, 30,275 catalog entries, ebook download; audiobook streaming, seeking, position/reset round trips | Native ebook percentages are not persisted by the server. Removed the unsupported ebook sync capability; reading and downloads remain available. |
| Emby | Login, book catalog, ebook download; direct audio API position/reset round trip using a short audio fixture | The configured book library exposes one ebook and no audiobooks. Native audiobook playback remains unverified. No native ebook-position sync is advertised. |
| Plex | Anonymous connection, audiobook catalog, streaming and seeking | **Progress round trip fails:** writes return HTTP 200 but a subsequent metadata request has no saved offset. Reproduced with direct `timeline` and `progress` requests. Track offsets are enabled on the audiobook library. The documented server is unclaimed; an authenticated test identity is needed to distinguish this setup limitation from a client defect. |
| Komga | Login, two libraries, comic download, partial/finished/reset round trips | Fractional progress is quantized to server pages; the four-page RTL fixture returns 25% for a 42% request. |
| Kavita | Login, two libraries, ebook download, partial/finished/reset round trips | Progress uses the first chapter selected by the existing download implementation, with server-page granularity. Exact Readium locators are not exchanged. |
| Grimmory | Login, three libraries, ebook download and partial/finished/reset round trips; audiobook streaming, seeking, position/reset round trips | Ordinary endpoint exercised through Enve. mTLS checked separately below. |
| Storyteller | Login, catalog, ebook download and partial/finished/reset round trips; audiobook streaming, seeking, position/reset round trips | Provider transport exercised. Interactive read-aloud alignment and OAuth browser login were not exercised. |
| BookOrbit | Login, three libraries, ebook download and partial/finished/reset round trips; multi-file audiobook details, streaming, seeking, position/reset round trips | Null progress responses are treated as no saved position; actual transport/decoding failures now propagate. |
| Silo | Login, ebook library, download, partial/finished/reset round trips, including restarting a completed book | The lab exposes only an ebook library. Audiobook transport remains unverified. |
| WebDAV | Authenticated PROPFIND listing, HTTP 207 | File transport has no native reading-progress protocol. |
| OPDS | Authenticated Komga OPDS catalog, HTTP 200 | Read-only catalog; no native reading-progress protocol. |
| KOReader / ABS-KOSync bridge | Authentication and direct partial/finished/reset round trips | Reset removes the progress record. Enve's existing linked-book merge UI was not exercised. |

Selected books' original progress was restored after each test. Tests use independent connection IDs without adding or replacing the simulator's saved connections. Progress restoration updates server timestamps; it is not a rollback of reading history. Streaming test sessions are closed by the harness.

## Infrastructure checks

- Lab health check passed before and after validation.
- Grimmory mTLS: valid identity accepted, missing/expired/untrusted identities rejected, authenticated login passed.
- Authentik: discovery passed for all four documented clients; machine client-credentials token issuance passed. Interactive authorization-code, device-code, and refresh flows were not exercised.
- Music, video, and game-only services received health checks, not Book Player integration tests.

## Regression coverage

`ProviderLiveSyncTests` runs the native provider checks above and reports nine passing service cases and the outstanding Plex case. It is disabled in ordinary test runs. To opt in, set `ENVE_LAB_DOCUMENT` to the absolute path of the local lab document in the test target's environment (or its generated `.xctestrun` `EnvironmentVariables`). The harness restricts endpoints to the document's lab hosts and reads credentials in memory. Never copy the credentials into a test plan or fixture. Optional `ENVE_LAB_EVENTS` names a pre-created file for credential-free progress events.

For authenticated Plex validation, add a `Plex token` row to the ignored local document, with its value in backticks. The harness uses it only for that lab endpoint.

The ordinary `AllTests` run passed 493 tests, with only the opt-in live test skipped, and no runtime warnings. New contract tests cover Kavita pagination/progress and Jellyfin's persisted audio updates and leaf-item playback routing. Existing sync tests cover source isolation, pending local writes, finished/reset records, and refresh coverage beyond the old recent-item cap.

After that run, the ABS finished-state correction was also applied to the two existing bulk/podcast refresh-service call sites. The initial rerun could not install the test host because the Mac's internal disk was full. After disk space became available, the complete suite passed with those corrections and the BookOrbit fix included: 494 passed, one opt-in live test skipped, zero failures, and zero runtime warnings.

These checks exercise providers on Simulator and server APIs; they do not replace interactive reader/player dogfooding or a TestFlight check on the reported device. No release was committed, pushed, or deployed.

## BookOrbit update and empty-library regression

Updated only BookOrbit to v2.8.1 (`latest`, image digest `sha256:cc1ecc94135464888313e599467f5f3834325edfaf47c5cf2f96d5c7c92ceca8`). Preserved the previous image, PostgreSQL dump, and data archive in the lab's private `artifacts/bookorbit-update-20260831T055538Z` directory. The current Compose file had omitted BookOrbit and its database; restored only those two definitions from the saved configuration after verifying the environment matched the running service. The database container and media files were not replaced. Both containers are healthy and `bin/lab doctor` passes.

The updated server returns `seriesIndex` as a JSON string. Enve's numeric-only catalog and detail DTOs rejected it, failing an entire catalog page when any book had a series number. Both DTOs now accept textual and numeric series indices, preserving textual sequence labels. `BookOrbitCatalogTests` covers full import, recent books, and details with strings, numbers, decimals, null/missing values, and range labels.

Verified against v2.8.1:

- Login, all three libraries, all 19 catalog entries, and all 19 detail responses.
- Cover retrieval and ebook download (HTTP 200); audio start and seek ranges (HTTP 206).
- Ebook progress at 42%, 100%, and 0%; audiobook position at 23 seconds and reset. Original progress was restored afterward.
- A standalone Swift executable using DTO declarations and the date decoder extracted from the actual provider decoded all 22 live catalog/detail responses. Restoring the former `Double?` declaration reproduced failures in the comic catalog and its series-numbered book detail. Six additional text/numeric sequence cases passed.
- `build-for-testing` succeeded without errors or warnings. The first iPhone Air test run could not install the test host: `No space left on device`. A subsequent check showed 17 GiB available, and the native simulator rerun passed as recorded below.

The live harness now imports the entire BookOrbit catalog and fetches every book's details instead of sampling only recent items. Set `ENVE_LAB_SERVICE=BookOrbit` alongside `ENVE_LAB_DOCUMENT` to select it without running other services. Local validation artifacts are under `$ENVE_BUILD_TMP/LiveSyncValidation/`.

### Simulator rerun — August 30, 23:09 PDT

On the arm64 iPhone Air simulator running iOS 26.4.1, `BookOrbitCatalogTests` and the BookOrbit case of `ProviderLiveSyncTests` both passed, with zero runtime warnings. The native provider authenticated against v2.8.1, imported all three libraries and 19 books, loaded every book's details, downloaded the synthetic comic (837 bytes), round-tripped 42%/100%/0% reading progress, streamed and sought the Alice in Wonderland audiobook with HTTP 206 range responses, and round-tripped 23-second/zero audio positions. The harness restored original progress afterward.

The complete `AllTests` plan then passed 494 tests with zero failures or runtime warnings; only the opt-in live suite was skipped in that ordinary run. The app also launched normally after testing. These are automated native provider tests, not manual BookOrbit connection/reader UI dogfooding.

Result bundles: `BookOrbitRetry.xcresult` and `AllTestsAfterBookOrbit.xcresult` under the local validation artifacts directory above. Build log: `bookorbit-retry-build.log` (no warnings or errors).

### Interactive simulator checks — August 30, 23:14–23:40 PDT

Exercised the installed app through simulator taps, text entry, and player/reader controls on the same iPhone Air. Added `BookOrbit UI Test` through the normal source login flow against v2.8.1, selected all three libraries, and confirmed all 19 books appeared with the media filter set to All Media.

The actual player exposed a second defect that the original provider-only tests missed: converting BookOrbit tracks into the playback-session timeline dropped their server file identity. Audio progress writes then returned without sending anything. BookOrbit now preserves file IDs in session track IDs, uses those IDs when mapping positions in both directions, and throws for an unusable identity instead of silently reporting success. A two-track regression test exercises the real timeline conversion and verifies a global position of 75 seconds maps to file 91 at 15 seconds and back.

After rebuilding, used the UI to play the Chaptered M4B fixture, seek backward, resume, and pause at 0:49. An independent server read returned `positionSeconds: 48.725685`, `percentage: 81.20948`, and `currentFileId: 2`. Before the fix, the same UI workflow left the server audio-progress record null.

Opened Pride and Prejudice through the library, rendered the EPUB, navigated using Contents, and closed/reopened the reader. BookOrbit saved 9.328704% for the linked copies. Reopening displayed 9%, but location 30 rather than 31; exact paragraph restoration is not confirmed, and the server CFI was null. This check establishes percentage persistence, not exact locator fidelity. Generic swipe attempts did not establish page-turn behavior.

The UI test connection and disposable fixture progress are retained for inspection, unlike the restored progress in the earlier automated runs. No production account was used. Existing unrelated Plex sign-in and legacy Booklore cover-authentication warnings remain visible in this simulator profile.

The final build completed without errors or warnings. `AllTests` passed 495 tests, with one opt-in live suite skipped, zero failures, and zero runtime warnings. Artifacts: `BookOrbitPlayerFix.xcresult`, `bookorbit-ui-fix-build.log`, and `bookorbit-player-fix-tests.log` in the validation directory. Reader screenshots are retained alongside them. No commit, push, or release was performed.
