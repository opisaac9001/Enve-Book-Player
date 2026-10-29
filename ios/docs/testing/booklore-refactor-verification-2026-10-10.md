# Booklore refactor verification — 2026-10-10

## Scope

iOS Book Player on `main`, including the shared tvOS build. Reviewed the split Booklore provider, Grimmory app API and compatibility tiers, authentication, catalog import, format mapping, playback, downloads, reader/progress synchronization, notebook, collections, statistics, administrative reads, and their callers. This is not an Android verification or a production-server migration test.

## Source preservation

Compared the original provider in HEAD against its 29 current files. After normalizing indentation and the access changes required for cross-file extensions, all 6,742 original nonblank lines were accounted for. All 292 function/initializer bodies matched before the intentional authentication fixes described below; no missing or accidentally changed method bodies were found. An independent source-only review reached the same behavioral conclusion. Callers were checked for writes to the state whose access had widened; none were found.

Reviewed callers include connection setup, profile/plugin lifecycle, library import/recovery, detail recommendations, audio playback, download asset caching, EPUB streaming, annotation/notebook sync, ebook/audiobook progress strategies, KOReader progress, history/statistics, storage migration, and tvOS playback. Existing Discovery and Stats extensions were included in the review.

## Initial refactor verification

| Check | Result |
| --- | --- |
| Final `AllTests` after replay fix | 1,269 passed, 0 failed, 17 opt-in cases skipped; no reported warnings/errors |
| Existing Grimmory live integration tests | 3 passed, 0 failed, 2 skipped |
| New local HTTP authentication integration tests | 2 passed; rejected-refresh password fallback, stored-token replacement, concurrent 401 coalescing, rotation, and reopening without a password |
| Final combined Grimmory live checks | 6 passed, 0 failed, 1 skipped in 133.2 seconds; real refresh-only case was initially deferred; follow-up below resolves it |
| Existing navigation and reader UI checks | All nine selected cases passed individually; first combined run timed out after eight passes, ninth rerun separately |
| Downloaded audiobook replay UI regression | Passed; Play at completion resets position, returns to Opening, and playback advances |
| iOS simulator build | Succeeded, no app compiler errors or warnings; existing AppIntents metadata-extraction warning appears in both initial and final build logs |
| Shared tvOS simulator build | Succeeded; first clean build reported 50 existing vendored libsmb2 C warnings, no app/provider warnings; incremental build after replay fix succeeded without output |

Live coverage includes the full large-library import and committed-page resume (30,248 unique identities), malformed-summary rejection, server format reconciliation, offset paging, small-library snapshots, incremental updates, cancellation, both dual-format primary orders, audiobook sessions, authenticated media bytes and actual AVFoundation decode/duration, EPUB download, namespace/Unicode EPUB streaming, cover handling, shelves, magic shelves, favorites, for-later, ratings, bookmarks, annotations, book notes, unified notebook, statistics, recommendations, admin/user reads, legacy REST and Komga fallback.

Existing live tests exercised ebook/audio progress round trips, format-specific locators for EPUB/PDF/CBX/FB2/MOBI/AZW3, ranged audio reads, and a readaloud book with 2,444 alignment clips and two tracks, including reopening mid-chapter.

Manual UI testing used the current Grimmory catalog and a synthetic public-domain test fixture: source/library selection, refresh and remote browse, book detail, streaming Listen, elapsed time, skip forward, chapter selection, EPUB Read with Unicode content, ebook and audiobook downloads, and relaunch/local playback resuming at 0:57. Reader UI tests covered selection boundaries, multiline selection, page taps, narration following, expanded/dismissed controls, pause/play, highlights, background return, and interactive back navigation.

## Issue fixed during verification

`PlaybackManager.play()` previously set the player rate at the end of a book without seeking away from the completed position. The button changed to Pause but the clock stayed at 1:00. Added a seek to zero when Play is requested at completion. The new native UI test verifies that the downloaded fixture restarts and advances. This was a preexisting playback issue discovered while testing a Booklore caller, not a behavioral change in the moved provider methods. The preexisting profile-scoped `shared` accessor change in this dirty worktree was preserved.

## Production fix follow-up — 2026-10-10

### Authentication

The initial server diagnosis was incorrect. Grimmory deliberately issues refresh tokens with a `nbf` timestamp 120 seconds after issuance. An immediate refresh is expected to return HTTP 401. Enve now honors that activation time and retains the token rather than attempting an early refresh and discarding it. Late concurrent 401 responses retry the current access token before requesting another rotation. This applies to API requests and authorized downloads.

The real-server activation/rotation/passwordless-reopening case passed in 255.8 seconds. No server configuration, database, media, or certificate changes were required. Local HTTP tests cover early token retention, rejected-token password fallback, concurrent refresh coalescing, delayed 401 responses, rotation, and reopening without a password.

### Search

The provider already supported remote search. Whole-source and all-library searches previously queried only cached records. They now query connected remote Booklore libraries, preserve selected-library and source filters, merge stored records, suppress hidden/deleted books, and deduplicate results. Device search remains local. A separate focus timing fix keeps the search field open when it first mounts.

Live checks passed for an uncached title across a selected library, its source, and all libraries. The native UI test found that title and opened its grouped edition detail with Resume available. The first UI test incorrectly expected a Read button on grouped detail; its assertion was corrected, then passed.

### Audio activation

Audio-session changes run on one serial background queue. Playback and narration start after activation completes; generation checks cancel delayed starts after pause, stop, replacement, or teardown. Speed changes and track changes respect pending activation. TTS preserves the initial locator when paused before synthesis starts. Volume-button observation is registered after activation and removed only if it was registered.

The rapid-toggle test verifies playback stays paused after a delayed activation could have completed. Native UI checks cover audiobook replay, narration control expansion/dismissal/restart, highlighting, and background return. No audio-session main-thread responsiveness warning appeared in the follow-up UI logs. Physical Bluetooth, AirPlay, and volume-button hardware combinations still require device testing.

### Native UI follow-up results

Search, downloaded audiobook replay, and narration expansion/dismissal/restart passed together in `test_sim_2026-10-11T00-25-18-416Z_pid36703_654d701b.xcresult`. The fourth case failed while long-pressing beyond the last word of a short line after background return; the retained recording confirms the empty-space target. The test now anchors the press inside the actual passage bounds. That case passed separately in `test_sim_2026-10-11T00-28-32-039Z_pid36703_fc0bd55c.xcresult` (42.1 seconds). The rerun also rebuilt the final speed/track activation guards. No production reader change was made for that test-coordinate failure.

### Final automated gate

The final `AllTests` run with the local authentication fixture and authorized live Booklore lab completed in 152.6 seconds: **1,278 passed, 0 failed, 11 skipped**, with no reported compiler warnings or errors. This includes seven live Booklore cases plus the normal 1,271 automated cases. The real refresh activation case was intentionally skipped in this combined run because it had already passed separately with its explicit gate; other skipped cases require separate services or device/account setups.

Final result bundle: `test_sim_2026-10-11T00-30-30-615Z_pid36703_3faf19a2.xcresult`. Real refresh rotation/reopening proof: `test_sim_2026-10-11T00-02-07-424Z_pid36703_4b4b0be7.xcresult`.

The final shared tvOS incremental build succeeded with no output. Provenance, sensitive-source scanning, and diff whitespace checks passed.

## Remaining findings and limits

- Temporary isolated-profile tests emit SQLite unlink diagnostics during test-container cleanup; the tests passed, but the absence of compiler warnings does not mean every runtime log line is silent.
- The large lab catalog returned 30,262 rows containing 30,248 unique IDs and one malformed title. Import deduplicated identities and rejected the malformed summary; that rejection correctly prevented a complete reconciliation snapshot. Duplicate-only unstable paging and persistence of incomplete status across arbitrary restart locations are review risks, not fully proven by this fixture.
- An old cached lab book referenced an ID reused by a previous server reset and returned audio HTTP 404. Fetching the current catalog entry played correctly. Existing cached data was not deleted.
- Administrative mutations, password changes, destructive library operations, production data, actual Pocket-ID/authentik SSO, physical-device behavior, and a network-disconnected offline session were not exercised. Downloaded local playback after relaunch was exercised. Pure source preservation and passing tests cannot guarantee every server/version combination.

## Reproduction

Use the required iPhone Air simulator and configured DerivedData location from `CLAUDE.md`.

1. Start `python3 Tests/Fixtures/booklore-auth-server.py`; it prints a temporary localhost URL. Run the `AllTests` plan with test-runner environment `ENVE_BOOKLORE_AUTH_FIXTURE_URL` set to that URL. Stop the fixture afterward.
2. Select `enveTests/BookloreRefactorLiveTests` in `AllTests`, set `ENVE_LAB_SERVICE=BookloreRefactor` and `ENVE_LAB_DOCUMENT` to the authorized ignored lab document. The suite reads credentials privately and restores its own shelf/notebook/rating fixtures. Set `ENVE_LAB_REFRESH_GATE=1` to verify real refresh-token activation, rotation, and passwordless reopening; this case waits for two server token activation windows.
3. Select `enveTests/ProviderLiveSyncTests` with the authorized lab document and `ENVE_LAB_SERVICE=Grimmory`.
4. Use the `UISmokeTests` plan for `HearthNavigationUITests` and `ReaderInteractionUITests`; split runs to stay within the tool timeout.
5. The replay test requires the 60-second synthetic Grimmory audiobook already downloaded and selected on Hearth. Select `BooklorePlaybackUITests/testDownloadedAudiobookReplaysAfterEnd` with `ENVE_LAB_PLAYBACK_UI=1`.
6. Build `enve-tvOS` for `generic/platform=tvOS Simulator` using a separate DerivedData directory.

Initial refactor unit result bundle: `test_sim_2026-10-10T23-28-07-973Z_pid36703_cb18a805.xcresult` in the local XcodeBuildMCP workspace. Initial live result bundle: `test_sim_2026-10-10T23-30-08-499Z_pid36703_4d934977.xcresult`. Replay UI proof is retained in `test_sim_2026-10-10T23-27-22-618Z_pid36703_93e55e20.xcresult` as `grimmory-downloaded-replay`. The affected reader/background test passed again after the replay fix in `test_sim_2026-10-10T23-28-34-371Z_pid36703_e62fa25a.xcresult`.

No changes were committed or pushed by this verification.
