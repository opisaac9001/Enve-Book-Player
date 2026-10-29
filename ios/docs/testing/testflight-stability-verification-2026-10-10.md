# TestFlight stability verification — 2026-10-10

## Findings and changes

- On the iOS 17.0 compatibility simulator, opening Playback & experience entered a SwiftUI update loop. Isolating the dismiss environment in the shared back button stopped the freeze. Opening, returning, and reopening the category passed UI testing.
- On that runtime, SwiftData rejected the obsolete playback schema with CloudKit validation requirements despite the configuration selecting no CloudKit database. Profile initialization could fail while opening this unused dependency. The obsolete manager, records, and injections were removed. Actual progress, bookmarks, custom metadata, queue, and speed use their existing active stores. Old database files are left untouched; no storage warning or reduced-functionality fallback is needed for this obsolete store.
- Concurrent Audiobookshelf unauthorized responses previously cancelled an in-progress credential refresh. A failing regression reproduced that cancellation. Requests now join the refresh, and a late unauthorized response reuses an already rotated token.
- Cancelled, offline, and server-failed refreshes now propagate without starting password login or presenting them as rejected credentials. Authentication requests use a ten-second timeout.

## Verification

Result bundles are under `~/Library/Developer/XcodeBuildMCP/workspaces/enveworkspace-15340b2fb5b6/result-bundles/`.

| Check | Result | Bundle |
| --- | --- | --- |
| iOS 17.0 startup without obsolete storage warning, Settings navigation, back, reopen | 1 passed | `test_sim_2026-10-11T03-15-11-494Z_pid36703_43c13e79.xcresult` |
| iPhone Air iOS 27 interactive back cancellation and repeated navigation | 1 passed | `test_sim_2026-10-11T02-28-57-793Z_pid36703_77996c70.xcresult` |
| iPhone Air iOS 27 ABS timeout with usable menus and no false reauthentication warning | 1 passed | `test_sim_2026-10-11T02-33-10-565Z_pid36703_0fcc1ec0.xcresult` |
| iOS 17.0 ABS stalled refresh, usable menus, no false reauthentication warning | 1 passed | `test_sim_2026-10-11T03-20-22-886Z_pid36703_91699f9f.xcresult` |
| iOS 17.0 reader highlight, narration controls, and background return | 1 passed | `test_sim_2026-10-11T03-24-28-267Z_pid36703_797c8ef5.xcresult` |
| iPad Pro 10.5-inch iOS 17.5 startup, Settings back/reopen, ABS stalled refresh, source settings and removal | 2 passed | `test_sim_2026-10-11T03-48-53-304Z_pid36703_8fe9302a.xcresult` |
| Enve repository writes with two simultaneous profile containers, iOS 17.5 | 1 passed | `test_sim_2026-10-11T03-48-30-687Z_pid36703_2ca7e354.xcresult` |
| AllTests on iOS 17.5 after fixtures use the complete production schema | 1,278 passed, 0 failed, 22 skipped | `test_sim_2026-10-11T04-07-21-279Z_pid36703_cf62144c.xcresult` |
| iOS 17.5 narration highlight/background recovery, expanded controls and restart | 2 passed | `test_sim_2026-10-11T04-11-32-325Z_pid36703_a868e221.xcresult` |
| iOS 17.5 profile creation, six UI switches, background return, removal and disable | 1 passed | `test_sim_2026-10-11T04-14-36-917Z_pid36703_2d2cfef4.xcresult` |
| iOS 17.5 profile switching, background return and full process restarts restoring both selected profiles | 1 passed | `test_sim_2026-10-11T04-33-16-608Z_pid36703_da73a921.xcresult` |
| iOS 17.5 real coordinator resource check after 40 switches | Failed; 33 to 113 open files | `test_sim_2026-10-11T04-10-30-834Z_pid36703_f0b47f59.xcresult` |
| AllTests after obsolete playback dependency removal, iOS 27 | 1,277 passed, 0 failed, 21 skipped | `test_sim_2026-10-11T02-48-20-774Z_pid36703_9bd034d4.xcresult` |
| AllTests after schema fixture corrections and new compatibility checks, iOS 27 | 1,278 passed, 0 failed, 23 skipped | `test_sim_2026-10-11T04-15-48-324Z_pid36703_034360e2.xcresult` |

The navigation bundle also includes an earlier unsuccessful ABS test. Initial ABS UI attempts failed because the test tapped a category beneath the bottom controls and then looked for a field label that was not exposed to accessibility. The final ABS run corrected those selectors and passed. It used a loopback fixture with synthetic credentials, stalled refresh responses, and removed its temporary source through the UI.

An iPad iOS 17.0 ABS run reached source removal but failed to expose the confirmation actions. The confirmation dialog was moved from the screen root to its triggering button. The iOS 17.5 iPad test passed source removal with that change. The subsequent iOS 17.0 attempt failed earlier at the source address assertion with multiple loopback fixture sources present; clean-fixture verification of the dialog change on 17.0 remains pending.

Final test builds reported zero errors and zero warnings. The skipped tests require live servers or CloudKit configuration. The provenance and sensitive-source checks passed. No release or push was performed.

## Separate iOS 17.0 profile persistence defect

Opening two containers with the same model types causes newly inserted objects in the earlier context to belong to a different underlying managed-object model. Saving fails with `NSCocoaErrorDomain` code `134020`. A standalone app without Enve, migration plans, SQL tuning, or CloudKit entitlements reproduces this on iOS 17.0. The same binary passes on iOS 27. Sharing one schema object and matching configuration names do not fix it.

Reopening the destination container passed 22 alternating visits with isolated titles, progress, and bookmarks, both in the standalone app and through Enve's actual repository. However, a longer standalone test disproved this as a safe workaround: repeated reopening leaked two open-file descriptors per container and eventually failed when the process reached 256 descriptors. Disabling autosave and yielding between visits did not fix the leak. The same 200-visit test on iOS 27 passed with 8–11 descriptors. Mutating `ModelContainer.configurations` also failed to switch the underlying store. These experiments have not been applied to production persistence.

| Diagnostic | iOS 17.0 | iOS 27 |
| --- | --- | --- |
| Enve repository writes with two simultaneous profile containers | Failed | Passed |
| Enve repository reopened for 22 alternating profile visits | Passed | Passed |
| Standalone serialized reopening for 200 competing profile visits | Failed; descriptor exhaustion | Passed |

This defect remains unresolved on iOS 17.0. Successful single-profile startup and reader tests do not establish that switching or importing between profiles works on that runtime.

Additional standalone checks on the official iOS 17.5 runtime (21F79), using an iPad Pro 10.5-inch simulator, passed the overlapping-container save reproduction. However, serialized reopening still exhausted open-file descriptors at approximately 128 visits and failed to load the next container. Raising the minimum to 17.5 would therefore not make that reopening workaround safe. No production persistence workaround has been applied.

## iOS 17.5 follow-up

The first full AllTests run recorded 1,214 passed, 64 failed and 22 skipped (`test_sim_2026-10-11T04-05-04-339Z_pid36703_10621434.xcresult`). Eight test fixtures used six-record schemas that omitted the production sync-cursor record. A standalone two-container reproduction confirmed that mixing model lists on iOS 17.5 could give an earlier context objects from the wrong model, failing with code 134020. Updating those fixtures to `Schema(versionedSchema: BookStoreSchemaV1.self)` made the full suite pass. Assertions and production schemas were unchanged.

The real `ProfileSwitchCoordinator` still reopens a database when recreating a retired session. A focused test kept books and progress isolated but grew the open-file count from 33 to 113 after 40 switches. An earlier attempt used nonexistent local-book fixtures that startup correctly pruned; the final reproduction used retained SMB catalog rows and failed only its resource-growth assertion.

A standalone prototype retaining one container per profile completed 200 competing visits on iOS 17.5, ending with 14 open files. The proposed app change is to retain each profile's `BookStoreManager` in the coordinator, inject it into recreated sessions, and evict it on profile removal. Playback, credentials, network, sync retirement and parent authorization remain session-scoped. This ownership change is awaiting user approval under CLAUDE.md; it has not been applied to production.

The focused resource test is opt-in with `ENVE_PROFILE_SOAK=1`; profile UI checks use `ENVE_PROFILE_UI=1` on a dedicated simulator with profiles disabled. These are additional release checks, not covered by a default AllTests pass.

## Profile restart and resource measurements

The expanded UI check switched between two adults, backgrounded and returned, then terminated and relaunched Enve in each profile. Both selected profiles were restored. The test passed with zero errors and zero warnings. An initial invocation omitted the UI test plan and failed before executing tests; the recorded successful run selected `UISmokeTests`.

Separate measurements used the actual Debug app on the same dedicated iOS 17.5 iPad simulator, with an owner EPUB fixture and an empty second adult profile. Counts came from numeric descriptors reported by `lsof`; memory and CPU deltas came from one-second `ps` samples. They exclude filenames, credentials and account contents.

| State, with the second adult selected | Process | Samples | Open descriptors | Resident memory at end | Average CPU |
| --- | --- | --- | --- | --- | --- |
| Fresh process, settled | 81849 | 25 seconds | 24 | 295.38 MB | 5.29% |
| After four switches, same profile selected again | 81849 | 30 seconds | 28 | 316.59 MB | 6.53% |
| After full termination and relaunch, same profile restored | 82514 | 20 seconds | 24 | 295.41 MB | 5.84% |

The old process was confirmed absent before the final launch. In the final ten seconds, CPU averaged 5.45%, 6.34% and 5.46%, respectively. Descriptor counts were flat throughout each idle window; resident memory was also stable within those windows. These observations show accumulated process resources clearing on termination, while the selected profile survives restart. They do not establish that all switching-related memory growth is leaked memory.

An earlier five-switch observation peaked at 44.75% CPU, including runtime UI automation and snapshot collection. In the final five seconds of a subsequent background observation, CPU averaged 0.40%, with 29 descriptors still open in the same process. Backgrounding therefore did not clear all accumulated resources. A later launch tool call created a new process rather than resuming that background process; it is counted as a restart, not a background-return measurement. The separate XCTest check exercised genuine background return.

No escalating CPU use was observed in these short profile checks. Simulator CPU percentages refer to host process use relative to one core; they are not physical iPad power or thermal measurements. These fixtures do not cover sustained playback, active downloads, or live server sync.

The passing isolation checks kept books, progress, artwork, preferences and connection catalogs separate, and enforced adult PIN authorization. No cross-profile exposure was observed in those checks; they are not a complete security audit. The temporary profile was removed through the UI, profiles were disabled again, and the test app was stopped. No production database ownership change was made.

## Reader UI follow-up — October 11

Normal-library UI testing found a separate SwiftUI/AttributeGraph update loop. Selecting text, saving a new note and opening Contents could freeze the app, consume roughly one host CPU core and grow resident memory by hundreds of megabytes within seconds. Isolating ReaderScreen's dismissal environment in its two Close controls stopped that sequence in repeated checks. The normal Close action still saves visible reading progress before dismissal.

Switching from the bookmark title field to its note field also lost keyboard focus. The reader's keyboard-navigation controller unconditionally reclaimed first responder after a text field ended editing. It now checks for an active `UITextInput` across the scene's windows before reclaiming focus and supplies its key commands only while it is first responder. Bookmark title and attached note text were subsequently saved and restored after a full app restart.

The actual-library regression also verified the selected-text note survived restart, bookmark navigation dismissed Contents, and the reader could close and reopen. However, removing a bookmark after that reopen still froze the UI. Fresh-session bookmark deletion passed both with and without visiting Notes search first. These are partial feature checks; the longer regression failed overall at deletion.

An LLDB main-thread sample during the remaining freeze showed SwiftUI/AttributeGraph layout, including `AG::Graph::index_of_input_slow` and weak attribute-value lookup. Temporary body tracing recorded more than 26,000 Contents invalidations reporting changed `openURL` and `dismiss` environment actions. That identifies a presentation dependency in the loop, but does not establish a complete fix or the reporter's exact crash cause. Isolating BookDetail dismissal, moving Contents actions into row/button views, changing swipe-button role, assigning a fresh reader presentation identity, and using owner-state dismissal did not safely resolve the workflow. Those experiments and every temporary body-tracing call were removed. BookDetail and application presentation identity are unchanged from their pre-experiment state.

The retained production changes are the verified ReaderScreen Close isolation and keyboard-focus correction. Contents also has an accessibility container identifier so UI checks distinguish its marks from the BookDetail screen underneath. The UI tests exercise actual imported-book persistence and deletion in addition to the existing narration fixtures. No bookmark, annotation, notebook-sync or production persistence implementation was changed in this follow-up.

Diagnostic result bundles include:

| Check | Result | Bundle |
| --- | --- | --- |
| Fresh-session bookmark creation and removal | Passed | `test_sim_2026-10-11T06-25-37-471Z_pid36703_e92d4aa9.xcresult` |
| Fresh-session removal after Notes search | Passed | `test_sim_2026-10-11T06-32-17-658Z_pid36703_f873b84e.xcresult` |
| Restart, bookmark navigation, reader close/reopen, then removal | Runtime timeout at removal | `test_sim_2026-10-11T06-34-29-324Z_pid36703_1daaabc0.xcresult` |
| Original remaining failure with temporary body tracing | Runtime timeout; repeated Contents action dependencies | `test_sim_2026-10-11T07-00-20-078Z_pid36703_cd10d6a2.xcresult` |

These runtime failures compiled with zero errors and zero warnings. The final checks against the restored production changes are recorded separately below. The fixtures are synthetic and do not verify live-server notebook synchronization, every annotation editing action, physical-keyboard navigation, or exact iPadOS 17.7.11 behavior.

### Final checks against retained changes

The four-test UI run against the retained source changes passed saving a note and opening Contents, expanded narration controls and restart, and narration controls after highlighting and background return. The actual-library test also passed bookmark title and attached-note restoration, selected-text note restoration, bookmark navigation, and reader close/reopen. It failed before deletion because XCTest could not swipe the bookmark row: its visible frame was empty. This latest failure does not reproduce the earlier deletion freeze, and it does not establish that deletion is fixed.

| Check | Result | Bundle |
| --- | --- | --- |
| Retained reader changes: four focused UI tests | 3 passed, 1 failed at the bookmark swipe | `test_sim_2026-10-11T07-27-02-023Z_pid36703_b113c0b8.xcresult` |
| AllTests after retained reader changes, iOS 17.5 | 1,276 passed, 2 failed, 23 skipped | `test_sim_2026-10-11T07-32-15-177Z_pid36703_e88f5781.xcresult` |
| Focused Audiobookshelf recovery rerun using the same test products | 4 passed, 0 failed | `test_sim_2026-10-11T07-34-35-175Z_pid36703_6d3f8af7.xcresult` |

The UI build succeeded without compiler errors or warnings. The failed assertion is an execution failure, not a build error.

The final AllTests build also succeeded without compiler errors or warnings. Two Audiobookshelf refresh checks failed: `retirementCancelsRefreshWithoutPublishingCredentials` received and published the fixture token, and `unauthorizedRequestJoinsRefreshAlreadyInProgress` counted two refreshes. Both tests rely on a fake refresh sleeping for 100 milliseconds before completion. They ran for several seconds under the full suite's concurrency, so the intended in-flight ordering may not have held. The focused rerun of all four recovery checks passed using the same compiled test products. This supports investigating test timing, but does not resolve the failed full-suite gate or verify an authentication fix. No authentication source was changed in this reader follow-up.

## iOS 27 follow-up — October 11

The current retained source changes were built and tested on a fresh iPhone Air simulator running iOS 27.0 (24A5390f). AllTests passed with 1,278 successes, no failures and 23 skips. The build recorded zero compiler errors and warnings. This is evidence for the installed iOS 27 runtime, not a verification of every release from iOS 18 onward; only 17.0, 17.5 and 27.0 runtimes are installed.

The opt-in real-coordinator resource check failed on iOS 27 as well: 40 switches grew the open-file count from 33 to 104. Books remained isolated and the other profile's final progress was retained; only the resource-growth assertion failed. The result bundle identifies the device and runtime explicitly. The earlier passing standalone iOS 27 experiment does not cover Enve's complete session and service graph. The app-level resource issue therefore cannot be described as exclusive to iOS 17. No database ownership change has been applied.

| Check | Result | Bundle |
| --- | --- | --- |
| AllTests after retained reader changes, iOS 27 | 1,278 passed, 0 failed, 23 skipped | `test_sim_2026-10-11T07-38-17-154Z_pid36703_f36253eb.xcresult` |
| Real coordinator, 40 switches, iOS 27 | Failed resource assertion; 33 to 104 open files | `test_sim_2026-10-11T07-39-33-654Z_pid36703_65487a7e.xcresult` |
| Initial nine focused UI checks, iOS 27 | 7 passed, 2 failed at test setup/selectors | `test_sim_2026-10-11T07-43-58-517Z_pid36703_b8bb6ac0.xcresult` |
| Note input and library flow after the first selector correction | Note/Contents passed; library opening still failed in setup | `test_sim_2026-10-11T07-53-24-139Z_pid36703_d300b43c.xcresult` |
| Library flow before explicit Library launch routing | Failed at the book lookup; tab tap had an invalid hit point | `test_sim_2026-10-11T07-58-24-905Z_pid36703_704aa4f3.xcresult` |
| Library flow with explicit routing | Saved note and bookmark fields; failed opening Contents after restart | `test_sim_2026-10-11T08-02-47-001Z_pid36703_9709b28c.xcresult` |
| Library flow with a center-page reveal gesture | Failed opening Contents after restart during the startup toolbar transition | `test_sim_2026-10-11T08-11-54-281Z_pid36703_18186231.xcresult` |
| Library flow after waiting for the startup toolbar transition | 1 passed, 0 failed; full restart, restoration, navigation, reopen and deletion | `test_sim_2026-10-11T08-33-05-715Z_pid36703_b5d8ef2c.xcresult` |

The initial UI run passed book-detail back gestures, repeated Settings back gestures, profile switching/background return/full restarts, bottom-selection toolbar separation, both-edge EPUB selection and intentional page taps, expanded read-aloud controls and restart, and narration after highlighting/background return. The MCP request timed out after 300 seconds, but Xcode finished the run; its complete result bundle records the seven passes and two failures.

The note check assumed that the multiline SwiftUI input appeared as a text view. Selecting the text field by its prompt, with the existing text-view form supported on older runtimes, made saving a note and opening Contents pass. The library test's unrestricted queries matched hidden Hearth controls, producing invalid hit points. The test now launches the Library route, scopes the book lookup to that screen, selects a visible Read button and waits for book text. Manual simulator interaction also opened the actual imported book through the visible Library and Read controls. These corrections are limited to UI tests; no application source was changed for this iOS 27 verification.

The next library runs reached the actual reader and saved both annotation and bookmark fields, but raced the reader's 3.5-second startup toolbar dismissal after restart. The final run waited for that initial transition before revealing Contents through the page gesture. It passed creating a selected-text note, saving a bookmark title and attached note, full process restart, restoring all three texts, navigating to the bookmark, closing and reopening the reader, keeping the restored note visible for ten seconds, and removing both the bookmark and annotation. The compiled test reported zero errors and warnings. No assertion was removed. Its retained screenshot is named `library-reader-bookmark-and-note-after-restart`.

All nine distinct targeted UI checks have now passed across these runs; this was not a single nine-test clean run. The iOS 17.5 reader deletion failure remains unresolved, and the separate real-coordinator resource check still fails on iOS 27. The successful default AllTests run skips that opt-in resource check. These results therefore do not establish a release with no remaining issues or verify every feature on iOS 18 and later.

## Manual bookmark deletion reproduction — October 11

The user reproduced the remaining freeze in the actual imported-book reader on the iPadOS 17.5 compatibility simulator and confirmed it began after clicking the red trash action. The app was running the retained source described above, without diagnostic source changes. The frozen screenshot showed the swiped bookmark row and trash action still visible.

Process 34688 used 98.9–100% of one host CPU core. Two observations recorded approximately 1.2 GB and 763 MB of resident memory; the system sample reported a 1.6 GB physical footprint and peak. These observations confirm high resource use, but do not show monotonically increasing resident memory. The three-second sample is `/tmp/enve-reader-user-freeze-ios175.sample.txt`.

The main thread was repeatedly updating SwiftUI/AttributeGraph and Core Animation layout. A source breakpoint stopped inside `ReaderContentsTray.body`; a second breakpoint in `ReaderArtifactsAdapter.setBookmarks` received no hits while the existing loop continued. The repeated work therefore does not require repeated bookmark-store mutations. This evidence identifies an ongoing presentation/layout loop, but does not prove whether the original trash action completed its one-time store mutation. The debugger was detached and the frozen app stopped after evidence capture. No user data was reset.

### Deletion diagnostics

The actual-library regression now scrolls its newly created bookmark into view before swiping. This addresses the earlier empty-frame test failure without removing any persistence, navigation, or deletion assertion. Subsequent failures reached the red Remove action.

With keyboard first-responder capture disabled as a diagnostic, saving and restoring the bookmark and note, navigating, and closing/reopening the reader passed, but bookmark deletion still produced the layout loop. A check restricted to synthetic bookmark storage confirmed the deleted fixture `Compatibility bookmark FCBAABE2` was absent from saved bookmarks while its frozen row remained visible. The one-time local storage mutation therefore completed in that reproduction; the screen failed afterward.

| Diagnostic | Observed failure | Bundle |
| --- | --- | --- |
| Separate Contents presenter and content | Freeze returning from Save Bookmark | `test_sim_2026-10-11T08-59-40-353Z_pid36703_9974003a.xcresult` |
| Parent-owned Contents dismissal and native capture links | Freeze returning from Save Bookmark | `test_sim_2026-10-11T09-04-46-517Z_pid36703_c4f29fdf.xcresult` |
| Disable keyboard first-responder capture | Freeze after bookmark Remove | `test_sim_2026-10-11T09-09-07-592Z_pid36703_28b10220.xcresult` |
| Notify before artifact assignment, keyboard enabled | Freeze after bookmark Remove | `test_sim_2026-10-11T09-14-23-885Z_pid36703_4c9ece72.xcresult` |
| Notify before assignment and defer swipe removal to a main-actor task | Freeze after bookmark Remove | `test_sim_2026-10-11T09-20-30-490Z_pid36703_06965460.xcresult` |
| Native color presentation backgrounds in Contents and both editors | Execution allowance exhausted before deletion after long animation waits; inconclusive | `test_sim_2026-10-11T09-28-04-933Z_pid36703_fe9c23d7.xcresult` |
| Native backgrounds, compiled-products rerun | New bookmark outside visible rows; failed its appearance assertion before deletion | `test_sim_2026-10-11T09-32-18-686Z_pid36703_acbce255.xcresult` |
| Native backgrounds after scrolling at save, restore and deletion | Freeze after bookmark Remove; app stopped after sampling, producing a lost-connection failure | `test_sim_2026-10-11T09-36-01-779Z_pid36703_059972f1.xcresult` |

The native-background deletion run recorded 32 half-second resource samples. CPU averaged 97.08%, peaked at 100%, and the final sample used 847,856 KB resident memory. A later sample reported a 3.0 GB physical footprint and peak. Its main-thread stack still showed SwiftUI/AttributeGraph and `ReaderContentsTray` work. The sample is `/tmp/enve-reader-native-background-freeze.sample.txt`; numeric resource observations are `/tmp/enve-native-background-delete-resource.json`. This rejects the custom background host as a sufficient explanation or fix. The app was explicitly stopped to end the measured loop; the lost connection is not an independently observed app crash.

A storage check found ten synthetic-fixture bookmarks with ten unique IDs, rejecting duplicate identity in that reproduction. The presentation-background experiment was reverted, as were the previous isolated diagnostics. These diagnostic UI runs compiled without compiler errors or warnings.

The combined notification-before-assignment, parent-owned Contents dismissal and isolated Capture button trial froze when returning from Save Bookmark. Its sample reported a 13.0 GB physical footprint while the main thread updated SwiftUI presentation and layout. The app was explicitly stopped and all three changes reverted. The result bundle is `test_sim_2026-10-11T09-41-31-772Z_pid36703_da697360.xcresult`.

### Contents environment-action tracing

A fresh-process manual reproduction omitted search and text editing entirely: open the imported EPUB, navigate to an existing bookmark, close and reopen the reader, then remove that bookmark. Deletion still froze. In a ten-second trace, Contents reported 2,592 changes to its `openURL` and `dismiss` environment actions, versus one Contents model update and one ReaderScreen model update. CPU was 99.7%, and resident memory was 623,232 KB at observation. This excludes search input as necessary to that reproduction. The trace is `/tmp/enve-reader-layout-trace-delete.log`.

Replacing only Contents' dismissal environment with `presentationMode` retained bookmark saving, restoration, navigation and reader reopening, but removal still froze. A five-second trace recorded 1,295 Contents `openURL` changes and no repeated dismissal-binding change. The process used 99.9% CPU and 1,038,944 KB resident memory before it was stopped. Trace: `/tmp/enve-reader-presentation-binding-trace.log`; result bundle: `test_sim_2026-10-11T09-55-00-584Z_pid36703_38c5b476.xcresult`. The reported app-not-running and execution-allowance failures followed that explicit stop; they are not independent crash reports.

Combining the dismissal binding with an isolated Capture button did not provide a fix. The first run exhausted its allowance after two startup animation waits (`test_sim_2026-10-11T10-03-35-911Z_pid36703_14e29cfc.xcresult`). A rerun of the same compiled products froze returning from Save Bookmark, using 100% CPU and 2,104,800 KB resident memory; its sample reported a 5.2 GB physical footprint (`/tmp/enve-reader-binding-capture-freeze.sample.txt`). That rerun was explicitly stopped; bundle: `test_sim_2026-10-11T10-08-04-730Z_pid36703_efce4cfc.xcresult`. The root body trace recorded no changes while that loop continued, so moving action dependencies out of the root is insufficient by itself.

### Child presentation isolation

With original root actions, backgrounds, notification timing and keyboard behavior restored, a diagnostic removed only the two Contents editor sheet registrations. A manual existing-bookmark navigation, reader close/reopen and removal passed: `Compatibility bookmark FD431DFE` disappeared, the tray remained responsive, and CPU returned to 0.0% with 365,760 KB resident memory. This build was `build_run_sim_2026-10-11T10-10-58-768Z_pid36703_d395f637.log`. It temporarily disabled those editor presentations and is not a production fix.

Two narrower behavior-preserving candidates were then rejected:

| Candidate | Observation | Bundle |
| --- | --- | --- |
| One enum-backed editor sheet, retaining payload UUIDs and both editor workflows | Full sequence froze after bookmark Remove; 1,277 Contents action invalidations in five seconds | `test_sim_2026-10-11T10-16-28-265Z_pid36703_2ba47761.xcresult` |
| Original two sheets, with model-only captures in their content callbacks | Full sequence froze after bookmark Remove; 1,241 Contents action invalidations in five seconds | `test_sim_2026-10-11T10-20-36-832Z_pid36703_f188c374.xcresult` |

The second candidate also recorded 79 consecutive resource samples at or above 90% CPU, with resident memory rising from 706,624 to 1,204,816 KB. Resource observations: `/tmp/enve-reader-captured-model-resource-window-2.json`. Both frozen runs were explicitly stopped and both candidates reverted. Removing all child registrations avoids the manual reproduction; retaining one shared registration or capturing only the model does not resolve the full workflow. Further isolated diagnostics retained the full original editor workflows unless noted:

| Candidate | Observation | Bundle |
| --- | --- | --- |
| Omit only the annotation editor registration | Freeze after bookmark Remove; 1,308 Contents action invalidations in five seconds | `test_sim_2026-10-11T10-24-34-502Z_pid36703_59f3f6d4.xcresult` |
| Original editors, dismissal binding and direct system URL opening | Freeze after Save Bookmark; no repeated root body trace entries during the measured loop | `test_sim_2026-10-11T10-28-34-978Z_pid36703_eeb21a48.xcresult` |
| Omit all six ReaderScreen color-scheme preferences | Freeze after bookmark Remove; 1,320 Contents action invalidations in five seconds | `test_sim_2026-10-11T10-31-01-708Z_pid36703_40133a69.xcresult` |
| Omit the entire keyboard navigation controller overlay | Freeze after bookmark Remove; 1,290 Contents action invalidations in five seconds | `test_sim_2026-10-11T10-35-07-969Z_pid36703_067bfb8e.xcresult` |
| Inherit the existing environment in the tray and its two editors instead of reinjecting it | Freeze after bookmark Remove; 784 Contents action invalidations in three seconds | `test_sim_2026-10-11T10-39-36-691Z_pid36703_f88d8d04.xcresult` |

These runs compiled without compiler errors or warnings. Each frozen app was explicitly stopped, and each candidate was restored before the next diagnostic. The resulting app-not-running or lost-connection test failures followed those stops and are not new crash reports. Original editor registrations, action environments, keyboard behavior, color preferences and environment injections are now restored. The plain swipe-button trial also froze after bookmark Remove (`test_sim_2026-10-11T10-45-11-000Z_pid36703_bb943aa9.xcresult`), with 1,084 Contents action invalidations in three seconds. It was reverted.

A regular header button then removed the exact synthetic bookmark after restart, bookmark navigation and reader reopening. No swipe gesture was used; removal still froze, with 2,634 Contents action invalidations in three seconds and 99.4% CPU (`test_sim_2026-10-11T10-49-21-892Z_pid36703_9b8388f6.xcresult`). That comparison filtered the list to the exact title first, so it also removed the last visible row while a search field was active. It proves swipe initiation is unnecessary, but does not isolate filtered-list layout or keyboard focus. The temporary header and test branch were removed.

The full actual-library sequence passed with temporary local row filters for bookmark and annotation Remove, leaving the controller and storage untouched (`test_sim_2026-10-11T10-53-45-664Z_pid36703_52bb8b98.xcresult`). Bookmark deletion kept the unfiltered list structure with other rows remaining. This demonstrated that visible row removal alone was insufficient to reproduce the freeze. It did not persist deletion and was restored immediately.

The next diagnostic retained controller removal and its normal shared-model publication, but omitted deletion persistence, repository tasks and export work in the adapter. Creating and saving marks still persisted normally. The full sequence again froze after bookmark Remove, using 99.7% CPU and 975,728 KB resident memory at observation. A three-second trace recorded 692 Contents action invalidations (`test_sim_2026-10-11T10-57-16-423Z_pid36703_549889e6.xcresult`). The frozen app was explicitly stopped and every omitted storage operation restored. The combined comparisons show that shared reader-model publication can start the loop without deletion writes or native swipe initiation. They do not establish which framework presentation edge feeds back.

### Retained tray callback fix

The first behavior-preserving fix passed the previously failing full actual-library sequence on iPadOS 17.5. The only production change for this deletion follow-up is an explicit `[model, ambient, book]` capture list on ReaderScreen's `.sheet(item: $tray)` content callback. All original storage operations, native swipe actions, both child editors, environment actions, environment injections, keyboard behavior and color preferences remain enabled. ReaderTrays, ReaderArtifactsAdapter and ReaderBridges were compared against their pre-diagnostic backups and restored exactly.

This narrows the callback to the three values used to create its content instead of implicitly retaining the full ReaderScreen value. The diagnostic comparisons locate the problem in presentation updates triggered by reader-model publication, and the passing callback change prevents the reproduced loop. They do not establish SwiftUI's internal feedback mechanism. The reporter's 17.7.11 stack was unavailable during these checks; the later supplied report is analyzed below.

| Check, iPadOS 17.5 | Result | Bundle |
| --- | --- | --- |
| Explicit parent callback captures, original full library flow | 1 passed, 0 failed; save, restart, restore, navigate, reopen, remove bookmark and note | `test_sim_2026-10-11T11-01-05-214Z_pid36703_3db1f076.xcresult` |
| Final production source with all temporary body tracing removed | 1 passed, 0 failed; the same flow plus a second full restart confirming both deleted artifacts remain absent | `test_sim_2026-10-11T11-10-57-391Z_pid36703_65ca1841.xcresult` |
| Existing artifact editors after reader reopening | 1 passed, 0 failed; bookmark title/note update, annotation note/underline update, full restart, editor removal and native bookmark removal | `test_sim_2026-10-11T11-14-37-120Z_pid36703_3bcc9857.xcresult` |
| AllTests after the callback fix, iPadOS 17.5 | 1,278 passed, 0 failed, 23 skipped | `test_sim_2026-10-11T11-17-22-579Z_pid36703_4aa53742.xcresult` |
| AllTests after the callback fix, iOS 27.0 | 1,278 passed, 0 failed, 23 skipped | `test_sim_2026-10-11T11-18-38-220Z_pid36703_ca4d685c.xcresult` |
| Final-source save/restart/navigation/deletion flow, iOS 27.0 | 1 passed, 0 failed; both deletions remained absent after another full restart | `test_sim_2026-10-11T11-19-54-134Z_pid36703_b8c03906.xcresult` |
| Initial existing-editor check, iOS 27.0 | Failed to locate the populated multiline note input; bookmark editing passed | `test_sim_2026-10-11T11-22-56-239Z_pid36703_dcb0e8a0.xcresult` |
| Existing-editor check with scoped input, iOS 27.0 | 1 passed, 0 failed; all edit, underline, restart and deletion checks passed | `test_sim_2026-10-11T11-27-03-189Z_pid36703_1e62c771.xcresult` |
| Existing-editor check with scoped input, iPadOS 17.5 | 1 passed, 0 failed; all edit, underline, restart and deletion checks passed | `test_sim_2026-10-11T11-29-51-005Z_pid36703_5d91ab52.xcresult` |
| Native page-turn audio preference taps, iPadOS 17.5 | 1 passed, 0 failed; tap changed the value, closing/reopening retained it, and a second tap restored the original | `test_sim_2026-10-11T11-46-23-484Z_pid36703_81857ebd.xcresult` |
| Native page-turn audio preference taps, iOS 27.0 | 1 passed, 0 failed; the same tap, reopen and restoration sequence | `test_sim_2026-10-11T11-48-16-534Z_pid36703_b18a84bc.xcresult` |

These runs built with zero compiler errors and warnings. The final-source deletion check took 150.4 seconds of test execution and retained `library-reader-bookmark-and-note-after-restart` and `reader-deletions-persist-after-restart` screenshots. Its positive save/restore checks and deleted-item queries use unique synthetic texts. No existing assertion was removed.

The editor check took 135.4 seconds. It navigated to a saved bookmark and closed/reopened the reader before editing. The updated bookmark title and attached note, and the annotation's updated text and Underline style, survived a full process restart. Removing the annotation from the nested editor closed only that editor, left Contents open, and retained the edited bookmark. Native bookmark removal then passed and Contents remained visible and hittable for five seconds. Its screenshot is `reader-editors-updated-and-removed`.

The new full iPadOS 17.5 and iOS 27.0 AllTests runs passed without compiler errors or warnings. Both Audiobookshelf checks that failed in the earlier 17.5 full run passed in the new run. This records clean final-source suite runs; it does not establish an authentication implementation fix, since those files were unchanged in this follow-up. The iOS 27.0 final-source library deletion flow also passed with zero compiler errors and warnings in 132.1 seconds of test execution. The opt-in profile resource soak remains skipped by default. The other five tray cases received the focused checks recorded below.

The first iOS 27.0 editor run saved the revised bookmark title and attached note, then failed in the test's populated note-input lookup. Its captured accessibility hierarchy shows the active annotation editor's multiline input as a TextField with the expected note value and keyboard focus, but no placeholder label. The iPadOS 17.5 representation was a TextView. The test now scopes this input to the ScrollView containing Update Note and supports those two observed representations. This changes only the UI test; the application source and all edit, persistence, underline and removal assertions remain unchanged. The iOS 27.0 rerun passed the complete workflow in 118.9 seconds; the iPadOS 17.5 rerun passed in 135.5 seconds. Both built with zero compiler errors and warnings.

### Manual tray checks

The final app was built, installed and launched on iPadOS 17.5 for manual browser-mirror checks (`build_run_sim_2026-10-11T11-33-02-099Z_pid36703_c1558898.log`, zero compiler errors and warnings). The actual imported book opened through Library and Read. Text size changed from 100% to 110% immediately and back to 100%; Paper and Ink theme changes updated the reader and kept Appearance responsive. The original 100% / Ink settings were restored.

In-book search returned multiple matching passages for Edge. Tapping a result dismissed the sheet and marked the matching reader text. Read to me started the current passage with the built-in Samantha voice, displayed the utterance and Pause control, paused, advanced to the next paragraph and stopped; stopping cleared the utterance and disabled paragraph navigation. No enhanced voice download was started.

Browser-mirror switch clicks did not toggle Skip audio on page turn, while dragging its thumb did. The changed value survived reopening the sheet and was restored. Native XCUITests then verified ordinary taps, sheet dismissal/reopening, value retention and restoration on iPadOS 17.5 and iOS 27.0. They passed in 25.7 and 35.3 seconds respectively, with zero compiler errors and warnings. This distinguishes mirror input behavior from an application switch failure; no application change was made for the switch.

A fresh synthetic book with six chapters opened as Enve Footnote Fixture. Its Bookmarks and Notes tabs were empty, and Export showed zero highlights and zero bookmarks. Its Contents list correctly showed all six chapters. Selecting Chapter 4 dismissed Contents and moved the reader to location 4 of 6, 50%. No marks from Reader Interaction Regression appeared in the second book.

Without restarting the process, the second reader was closed and Reader Interaction Regression opened through Library and Read. Contents changed back to its single chapter and saved bookmark rows. A new synthetic Morning bookmark was saved through the normal editor. Export showed the correct first-book title, 46 highlights and 16 bookmarks. Markdown, Plain Text, JSON and CSV each changed the preview. Share opened the native activity sheet with the CSV text; cancelling returned to Export. No share destination was selected. This verifies the changed callback uses the current book and model when a different reader is opened in the same process.

The Morning bookmark was then selected, Contents dismissed, and the reader closed and reopened before preparing the morning deletion check. Temporary tracing and diagnostic behavior changes remain absent. The provenance and sensitive-source checks passed again; the restored tray, artifact adapter and bridge files still match their pre-diagnostic backups. No authentication, architecture, signing or release changes were made in this deletion follow-up.

The iPadOS 17.5 mirror at `http://localhost:3200/` was left in Contents > Bookmarks with Morning filtered and its saved row visible. The user can swipe that row left and press the red trash action in the morning. Screenshot: `/tmp/enve-reader-morning-ready-ios175.jpg`. The app remained process 9933 throughout the two-book manual checks; the final observation reported 0.0% CPU and 428,560 KB resident memory. This single observation confirms no active one-core loop at that moment, not a resource-soak result. No test runner or debugger remains attached.

## Supplied build 291 watchdog report — October 11

The user supplied a full crash report captured October 9 at 22:05:08 -0400, from Enve 1.2.6 build 291 on iPadOS 17.7.11 (21H461), hardware identifier iPad7,4. That build predates the reader fixes recorded above. Its process had run for approximately 19 minutes and 12 seconds before termination.

| Evidence | Interpretation |
| --- | --- |
| EXC_CRASH / SIGKILL, FRONTBOARD code 2343432205 (`0x8BADF00D`) | The operating system terminated Enve through its responsiveness watchdog. |
| `WatchdogEvent: process-exit`, Background, failed to terminate gracefully after 5.0 seconds | Enve did not complete an OS-requested process exit within its time allowance; this is a shutdown timeout, not a reported launch timeout. The preceding user action is not supplied. |
| Main-thread `NSTextContentStorage`, `NSTextLayoutManager ensureLayoutForRange:`, `_UITextLayoutCanvasView _viewportDidLayout`, Core Animation layout/commit | The main thread was processing native text layout when it was killed. The stack contains no app-specific reader, persistence or provider callback identifying the original trigger. |
| Application CPU 4.916 seconds / 31%; all-process CPU 8.350 seconds / 53% | The app had significant CPU activity during the accounting window. These totals do not prove continuous 100% main-thread use or quantify a particular layout loop. |
| Kernel VM allocation failures; approximately 1.0 GB MALLOC and 2.8 GB total virtual regions | Allocation pressure is relevant, but these are virtual-region totals. Resident counters are zero in this report, so they do not establish the app's physical footprint. The recorded termination reason is watchdog, not a documented jetsam memory-limit event. |

Apple notes that a watchdog stack records the work at termination and may omit the task that consumed most of the time allowance: [Addressing watchdog terminations](https://developer.apple.com/documentation/xcode/addressing-watchdog-terminations).

The earlier actual bookmark-delete freeze sample contains the same `_UITextLayoutCanvasView` viewport/content-size chain and `NSTextLayoutManager`, within its broader SwiftUI/layout loop (`/tmp/enve-reader-user-freeze-ios175.sample.txt`, lines 1934–1940). This makes the already fixed reader presentation loop a plausible explanation for a frozen UI failing to exit. It is supporting similarity, not proof that this user was deleting a bookmark or that this is the same defect. A single `objc_sync_enter` frame also does not establish a deadlock.

The reader's new-note, bookmark-note and existing-annotation editors use vertically expanding SwiftUI text fields. Focused UI verification now exercises those editors with four-paragraph synthetic notes, backgrounds the app for six seconds while editing, returns and verifies the complete draft, then resumes typing, saves and removes the test artifacts. This targets the text-layout/lifecycle interaction seen in the report without replacing TextKit or changing production behavior. Simulator background/return checks do not reproduce FrontBoard's physical-device graceful-exit watchdog or prove the exact 17.7.11 incident is resolved.

The exact build 291 symbol UUID is `633E3EDA-4898-3A22-A33E-7951985C9FF5`. The standard Xcode archive directory, EnveBuildTmp archives, workspace archive paths and indexed dSYM search did not locate a matching archive or symbol file. No addresses were symbolicated against a different build. An exact app source line therefore remains unavailable; the only Enve frame in the supplied main-thread stack is below UIApplicationMain.

| Focused editor/lifecycle check | Result | Bundle |
| --- | --- | --- |
| Initial iPadOS 17.5 check | Failed because the test read the foreground state immediately after pressing Home, before the asynchronous background transition completed | `test_sim_2026-10-11T17-16-31-728Z_pid36703_0e299fbf.xcresult` |
| iPadOS 17.5 after waiting for the background state | 1 passed, 0 failed; all three editors retained multiline text and keyboard input, and both synthetic artifacts were removed | `test_sim_2026-10-11T17-18-59-883Z_pid36703_aa342420.xcresult` |
| Initial iOS 27.0 check | Failed in the test's populated-input lookup: the empty prompt no longer identified the field after typing | `test_sim_2026-10-11T17-21-18-008Z_pid36703_83906516.xcresult` |
| iOS 27.0 after selecting the populated input by its complete value | 1 passed, 0 failed; all three editor background/return, continued-input, save and removal checks passed | `test_sim_2026-10-11T17-23-56-726Z_pid36703_5fde7d24.xcresult` |
| iPadOS 17.5 with the final populated-input selector | 1 passed, 0 failed; the same complete three-editor workflow | `test_sim_2026-10-11T17-26-08-434Z_pid36703_ef90e5ef.xcresult` |

The passing iPadOS 17.5 check ran for 109.5 seconds, with zero compiler errors and warnings. Each background window lasted six seconds; returning preserved the full text, showed the keyboard and accepted an appended suffix. No production source changed while investigating this supplied report.

The first iOS 27.0 attempt stopped before its background action. Its captured hierarchy shows the complete multiline field populated and keyboard-focused, with no empty prompt identifier. Xcode also reported the legacy TextField / modern TextView representation mismatch. The test now identifies the populated input by its unique complete synthetic value across element types and verifies the updated value after typing. It waits for Keep it to disappear after Save instead of interpreting the vanished empty prompt as a dismissed editor. The draft, lifecycle, keyboard, save and removal assertions remain enabled.

The iOS 27.0 rerun passed in 104.9 seconds, with zero compiler errors and warnings. The final-selector iPadOS 17.5 rerun passed in 116.0 seconds, also with zero compiler errors and warnings. These checks exercise likely text-layout surfaces; the crash stack itself does not establish that an editable note field was active. Other native text views can use the same framework layout chain, including the reader's read-only UIKit footnote view.

After these checks, the iPadOS 17.5 app was launched again and opened through Library > Reader Interaction Regression > Read > Contents > Bookmarks. The existing Morning bookmark remains saved. The mirror is left with Morning filtered and the keyboard hidden, ready for the user's deletion check. `/tmp/enve-reader-morning-ready-ios175.jpg` was refreshed to show this state. The earlier process 9933 observation above belongs to the preceding manual session.

## Remaining limits

The reporter used iPadOS 17.7.11. App Store Connect originally returned 404 for the reported crash logs; the user has now supplied the build 291 watchdog report analyzed above. It establishes a background shutdown timeout during native text layout, but not which app interaction caused it. Apple's current downloader does not provide 17.7.11. The archived iOS 17.5 runtime was downloaded from Apple's authenticated download catalog and installed; full AllTests and focused Enve checks are recorded above. The long-session profile resource leak still needs the proposed fix and verification. Enve's existing MetricKit collector retains incident counts and dates, but not diagnostic call stacks; retaining shareable diagnostic details is a proposed follow-up, not an implemented change. No user data was reset or deleted, and no release or push was performed.
