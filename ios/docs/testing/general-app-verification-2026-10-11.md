# General app verification — October 11, 2026

## Scope

Current uncommitted iOS Book Player source on `main`, before a public push. Testing covers the app beyond the reader deletion fix. Existing unrelated work is preserved. This report records failures as well as passes; it is not a release approval.

## Current results

| Check | Result | Evidence |
| --- | --- | --- |
| iPadOS 17.5 build/install/launch | Passed; no reported compiler errors or warnings | `build_run_sim_2026-10-11T20-31-10-950Z_pid36703_2edc2b8c.log` |
| Real profile coordinator, 40 switches | Failed resource-growth assertion: 33 to 113 open descriptors. Book and progress isolation assertions passed | `test_sim_2026-10-11T20-32-08-696Z_pid36703_803cc186.xcresult` |
| Library navigation and Settings accessibility | Both passed | `test_sim_2026-10-11T20-32-47-391Z_pid36703_36dfe8e6.xcresult` |
| Hearth accessibility | Contrast audit flagged author caption on orange current-book card | Same bundle; `/tmp/enve-broad-ui175-failures/` |
| Library accessibility | Failed: mini-player title button has a 42-point height; assertion requires 44 | Same bundle, reproduced with geometry below |
| Initial OPDS navigation check | Failed setup: no OPDS connection existed on this simulator | Same bundle; subsequently configured a dedicated localhost acquisition fixture |
| Detail and Settings interactive back navigation | Both passed | `test_sim_2026-10-11T20-34-23-889Z_pid36703_2e6ebb73.xcresult` |
| Library health, including accessibility text size | Both passed | Same bundle |
| Unsupported-OS passage prompt | Passed | Same bundle |
| Player accessibility | Hit-region audit failed | Same bundle, reproduced with geometry below |
| ABS delayed refresh/menu responsiveness | Passed using a dedicated localhost fixture with a 20-second refresh delay | `test_sim_2026-10-11T20-36-23-868Z_pid36703_c14e4751.xcresult` |
| Narration after highlighting/background return; natural page follow; multiline selection | All three passed | Same bundle |
| Native profile switch/background/full restart workflow | Passed | `test_sim_2026-10-11T20-42-57-332Z_pid36703_1da48894.xcresult` |
| Reader accessibility | Contrast audit flagged the location label. Its captured dark text on near-white background needs investigation before attributing this to app colors | Same bundle; `/tmp/enve-broad-reader175-failures/` |
| Hit-region diagnostic rerun | Both failures reproduced without weakening assertions | `test_sim_2026-10-11T20-49-10-564Z_pid36703_417d04e4.xcresult` |
| Physical iPhone test build | Blocked before test execution: both test targets lack a development team | `/tmp/enve-general-physical-device-20261011.log`; temporary signing override requires approval |

The first profile invocation omitted the Swift Testing method's trailing `()` and executed zero tests. Its tool success is not counted as a pass. The corrected invocation above executed the test and failed its resource assertion. The profile ownership fix remains unapplied.

## Additional checks

| Check | Result | Result bundle |
| --- | --- | --- |
| Profile offline storage/download routing, downloaded EPUB narration repair, audiobook artifact migration | 14 passed | `test_sim_2026-10-11T21-01-36-846Z_pid36703_923a33ea.xcresult` |
| Live Booklore refresh/reopen, audio/ebook downloads/streaming/covers, shelves/ratings, bookmarks/annotations/notes, administration compatibility | 5 passed; owned temporary fixtures cleaned up by test harness | `test_sim_2026-10-11T21-01-57-914Z_pid36703_3b688736.xcresult` |
| Configured OPDS navigation; expand/dismiss/restart narration; page-turn preference persistence; contents after saving a note | 4 passed | `test_sim_2026-10-11T21-02-56-504Z_pid36703_eba3634b.xcresult` |
| Playback resume, sleep windows, sync coordinator/lifecycle | 26 passed | `test_sim_2026-10-11T21-04-58-673Z_pid36703_7251c891.xcresult` |
| Live Booklore uncached search and complete catalogue import/resume/browse/delta/cancellation | 2 passed | `test_sim_2026-10-11T21-06-37-126Z_pid36703_b9acc20c.xcresult` |
| Playback queue policy/routing/persistence and BookOrbit annotation/bookmark merging/retry queue | 43 passed | `test_sim_2026-10-11T21-05-29-732Z_pid36703_5e25a4b3.xcresult` |

All these runs used the iPadOS 17.5 simulator, reported zero compiler errors/warnings, and executed the stated counts. BookOrbit merge/queue checks are automated model tests, not a new live SSO login.

## Accessibility evidence

The test helper now retains screenshots and visible button geometry; audit and size assertions remain unchanged. Library geometry identifies the title area of the mini player, exposed as “Bookmark,” at 436 × 42 points. Its adjacent transport and tab buttons measure 44 × 44. Player geometry identifies the Book/Chapter segmented picker: accessible child frames measure 76 × 28.5 and 47 × 14.5 respectively. This needs review of the actual native control and touch area; playback itself did not fail in this audit.

The Hearth author caption's element screenshot contains foreground RGB (110, 100, 89) over approximately (245, 185, 109). The reader location screenshot instead contains dark RGB (35, 31, 27) over near-white (253, 253, 252), despite the contrast audit failure. Captured pixels do not replace an accessibility or physical-device check.

## Download and unavailable-source checks

A dedicated localhost OPDS server serves one owned, synthetic EPUB containing a two-minute embedded narration track. The normal source menu opened its catalogue and Download changed the catalogue status to Downloaded. The acquisition server was then shut down; a new socket connection returned connection-refused. The library's Read action opened the actual downloaded text while the acquisition server was unavailable.

The detail page still displayed Download and a message asking the reader to download before listening. In `OPDSCatalogBrowser.download` the catalogue updates its own item status after a direct provider download; this path does not explicitly mark the library book downloaded. That is a candidate cause of the inconsistent labels and merits a focused fix/retest. Embedded narration started normally from the reader menu and its highlight advanced with the backend unavailable. After terminating and relaunching the app, the same library book opened its downloaded text again. The library detail retained 92% read, although this one-page fixture's reader footer initially displayed 0%; this is an observation for follow-up, not proof of lost persisted progress. Proof: `/tmp/enve-offline-cold-restart-17-5.jpg`. This test makes the acquisition backend unavailable; it does not turn off every network interface on the simulator.

Fixture: `Tests/Fixtures/opds-offline-server.py`. The source connection and book belong to this test. Production servers and unrelated user data are outside its scope.

## Extended session

A separate iOS 27 simulator is running a 60-minute local media-overlay EPUB with four chapters and 240 timed clips. It contains silent PCM audio to verify decoding, timing and text following; it cannot establish audible quality or physical audio-route behavior. The app was built and launched successfully with no reported compiler errors or warnings.

The 45-minute observation window completed successfully. The sampler exited normally, and the same app process was independently confirmed alive at an elapsed 45:34. The current process is sampled every ten seconds for numeric descriptors, resident memory and CPU-time deltas, without filenames or server/account information. `/tmp/enve-general-45min-soak-27.ndjson` contains the observations. The file contains 269 samples covering 2693.07 seconds at approximately ten-second intervals; the sampler loop then exited after its 2700-second target. Initial/final resident memory was 471.31/257.73 MB. After the first five minutes, resident memory ranged 212.83–381.38 MB. Numeric file descriptors ranged 32–34 and began/ended at 34. Average app CPU use was 2.97%; the largest ten-second CPU interval after warmup was 6.08%. These observations show no accumulating handles or monotonic resident-memory growth during this particular local playback session. They do not rule out leaks in other flows. Only the app process was sampled, excluding separate WebKit services and physical-device energy/thermal behavior. Backgrounding from the simulator Home control and reopening the app preserved advancing narration. Natural playback crossed into chapters two and three. Landscape layout rendered; cycling back through the supported portrait orientation restored normal upright text. The mirror briefly presented sideways content when cycled through the unsupported upside-down portrait orientation, so this is not a blanket orientation audit. Manual tap-to-reveal controls in the mirror have not been verified in this session; dedicated native UI tests cover those on 17.5. Playback reached chapter four by the final screenshot (`/tmp/enve-45-minute-playback-proof.jpg`). Numeric summary: `/tmp/enve-general-soak-summary.json`. The app was then stopped before the final phone UI checks.

## Remaining gates

Actual Pocket-ID/authentik SSO, physical Bluetooth/AirPlay/interruption behavior, network-interface-disconnected playback, and installing over the reporter's exact build 291 have not been newly verified in this general-app pass. A retained matching build 291 archive is unavailable. The profile resource leak and the audit findings remain open. No production source, saved signing configuration, release configuration, commit or push has changed in this testing pass.

The repository provenance/sensitive-source/agent-lock marker check passed. Whitespace validation passed for this testing pass's helper, fixture and report.

## Additional reader run requiring follow-up

The seven-case reader run `test_sim_2026-10-11T21-09-01-075Z_pid36703_8c3f3380.xcresult` exceeded the MCP tool's 300-second response limit. The owned test process was then cancelled. Its final result records one pass (bottom-selection controls), one page-turn assertion failure, one cancellation, and four skips. These are not seven successful checks.

The page-turn case reached its final intentional-edge-tap assertion; selection assertions had passed. The iPad renders the short fixture as one page, unlike the phone layout used by this case. A phone rerun is needed before deciding whether this is an app navigation failure. The controls hide/restore case repeatedly waited 60 seconds for XCTest's animation-idle notification; a screenshot still showed rendered text and narration controls. This does not prove the app froze, but the test is incomplete. The four imported-book cases lacked `ENVE_LIBRARY_READER_UI=1`; the corrected invocation is described below.

The corrected imported-book run (`test_sim_2026-10-11T21-15-07-383Z_pid36703_3584e10e.xcresult`) passed editing bookmark/note artifacts and retaining those edits after a restart (135.8 seconds). Bookmark deletion completed its initial action and advanced into the reopen check, but repeated animation-idle waits exceeded the tool timeout. The run was cancelled: the final bundle records one pass and one cancellation; the other two selected cases did not execute. It is not a completed four-case pass.

A two-second sample of the 17.5 app during this wait (`/tmp/enve-general-reader-idle-wait.sample`) recorded every main-thread sample waiting in `mach_msg2_trap` under the normal application run loop. Point-in-time CPU was 0%. This sample does not reproduce the spinning TextKit stack from the reported crash; it also does not substitute for finishing the interrupted UI case.

## Direct general-screen checks on 17.5

Podcasts opened from the compact bottom bar. Browse loaded chart artwork and show listings. Opening a public show loaded its episode list; playing an episode presented the player, and its elapsed time advanced from 0:03 to 0:10. Pause changed the transport button to Play, and dismissing the player returned to the browser. This verifies visible playback/navigation states, not audible quality or every podcast provider.

Journal opened from the compact bottom bar and displayed stored reading summaries/artifacts. Stats Hub opened, and switching Week to Year changed the selected range and daily-average summary. Returning to Journal worked. These checks did not validate the numeric totals against an independently calculated history.

Settings opened from Journal; Playback & experience and Playback opened. Selecting 1.1× changed the selected chip and the displayed speed. The original 1× setting was restored. The temporary localhost fixture processes have been stopped.

## Final iOS 27 phone comparison

`test_sim_2026-10-11T21-27-34-233Z_pid36703_8cdc871d.xcresult`: four passed, zero failed/skipped, no reported compiler errors/warnings. Launch/Library navigation and Settings accessibility passed. The original short-fixture edge-selection/page-turn case passed in the phone layout. Narration controls hid/restored while playing, paused and selecting, without the repeated animation-idle stalls observed on 17.5.

The edge-selection test now uses the existing `reader-selection-follow` EPUB, containing six chapters, instead of the single short chapter. Its assertions are unchanged. The short chapter fits on one iPad page; the multi-chapter fixture ensures navigation has somewhere to go. The corresponding 17.5 rerun passed: `test_sim_2026-10-11T21-30-05-411Z_pid36703_2c0539e4.xcresult`, one executed/pass, zero failures/skips, no reported compiler errors/warnings. This resolves that fixture-dependent navigation assertion without changing production behavior. No application source was changed to accommodate a test.

The isolated narration-controls rerun on 17.5 passed: `test_sim_2026-10-11T21-32-00-876Z_pid36703_9a6d381f.xcresult`, one executed/pass, zero failures/skips, no reported compiler errors/warnings. Playing, paused and selecting controls hid/restored as expected. The earlier combined-run cancellation remains recorded, but this workflow has a completed pass on both tested OS versions. Bookmark deletion was checked separately with its required imported-book flag; see the completed result below.

The isolated bookmark-deletion rerun on 17.5 passed: `test_sim_2026-10-11T21-33-18-529Z_pid36703_ee8b2f0d.xcresult`, one executed/pass, zero failures/skips, no reported compiler errors/warnings, 84.8 seconds of case execution. Deletion and the reopen checks completed. Earlier cancelled attempts remain in the report for reproducibility.

## Outcome

This broad pass executed 90 successful service/provider checks, plus native UI and direct UI checks on 17.5 and 27. The 45-minute playback soak completed. The profile-switch descriptor-growth test still fails. Accessibility audits/hit areas and the inconsistent OPDS download label need focused review/fixes. Physical-device signing approval, real SSO, hardware audio routes, and the exact reporter-device upgrade remain verification gaps. This pass is not permission or evidence to declare the entire app defect-free or ready to publish.

Changes made by this testing pass are limited to retaining accessibility diagnostic attachments, using a multi-chapter fixture for the edge-navigation test, the localhost OPDS acquisition fixture, and this report. All prior application changes were preserved. No production source, saved signing configuration, commit, or push was changed.

## Subsequent profile-resource fix

The database ownership change was authorized and tested after this general pass. The isolated 17.5 check now held open descriptors at 31 → 31 through 200 switches; full suites and native profile workflows passed on 17.5 and 27. See [profile database reuse verification](profile-database-reuse-2026-10-11.md). The earlier failing measurements above describe the pre-fix source and are retained as evidence.
