# Reader feedback verification — 2026-10-11

## Changes

Readium's scrolling configuration disables horizontal chapter swipes. Side navigation moves roughly one screen of text within the current chapter. Paged navigation retains the existing Readium behavior; contents navigation remains available for choosing chapters. Foliate already rejects horizontal page pans in scrolling mode and was not changed.

Automatic read-along following now places an off-screen passage in the middle of the viewport. Already-visible passages are left in place. Following remains controlled by the existing page-follow preference.

## Verification

- iOS 27 AllTests: 1,280 passed, zero failures, 23 skipped.
- iPadOS 17.5: both native reader UI tests passed, zero failures or skips.
- iOS 27: both native reader UI tests passed, zero failures or skips.
- The scrolling UI fixture has two chapters with enough text for a tablet viewport. The test enables edge taps, checks forward and backward movement, verifies horizontal swipes retain the reading position, and restores the gesture preference.
- The narration fixture starts with a passage outside the viewport. The UI test starts Read Aloud through the app's menu, waits for the second passage, checks its position near the screen center, stops narration, and restores paged mode.
- A new playback regression test visited all four chapters across separate audio files on iPadOS 17.5. The existing paused-seek regression also passed.
- Builds had no compiler errors or new compiler warnings. Whitespace and repository provenance checks passed.

The final UI runs used serial execution and disabled automatic diagnostic collection. Earlier attempts exposed insufficient fixture length, control-opening assumptions, and test cleanup problems; those were corrected before the passing runs. An initial newer-simulator installation failed because the Mac's internal disk was full. This session's generated test-product copies were archived on the external build volume, with links preserving their original artifact paths. Application data was not deleted.

## Remaining report

The reported automatic 10→12 or 22→24 chapter skip was not reproduced. Controlled playback passed on both platforms, including Android playback reconciliation during chapter endings. This does not establish that the affected book is fixed. The affected EPUB or read-along source and a reproducible chapter boundary are still needed. No speculative change was made to automatic chapter advancement.

No changes were committed or pushed.

## Additional pre-push verification

- iPadOS 17.5: three playback tests (four cases) passed. Coverage now includes chapters spanning audio files, multiple chapters sharing a file, nonzero clip offsets, pause/resume at a shared-file chapter boundary, and paused seeks across files. Every expected clip was visited in order.
- iPadOS 17.5: native UI checks for narration controls after highlighting/background return and page-turn audio preference persistence both passed. Preference persistence does not prove that every manual reading gesture leaves audio untouched when the preference is off.
- The affected user's book is still needed to reproduce the reported skipped chapter. These fixtures do not establish correctness for malformed overlays or all server-provided books.

The same three playback tests (four cases) also passed on iOS 27, with zero failures or skips. No compiler warnings were emitted. Runtime logs contained an AppShortcuts provider metadata diagnostic; the test-result summaries reported no runtime warnings.

## Network interruptions and independent reading

Two defects were reproduced and fixed:

1. A visible paragraph ID was treated as the current narrated passage even when it belonged to another chapter. Chapters in the fixture deliberately reuse `p1` and `p50`. Visibility now requires the narrated chapter to match the displayed chapter before suppressing an audio seek.
2. After initial stream/session preparation failed, the iOS Play action had no player to resume. It now retries a failed preparation through the retained provider, or reloads the single direct stream. It does not duplicate a preparation already in progress.

The native UI tests turn off “Skip audio on page turn”, move between pages and chapters while paused and playing, and check the audio position. They then enable the option and verify a real seek to the second chapter. Both modes passed on iOS 27. The reading progress slider is replaced by audio controls during Read Aloud; the audio slider intentionally seeks narration.

The controlled HTTP fixture serves synthetic WAV audio with byte ranges and throttled delivery. Tests exhaust the buffer before restoring delivery, close an active connection, pause during an outage, retry initial HTTP failure through Play, and retry provider-session preparation. All five scenarios passed on iOS 27. The final AllTests run passed 1,286 tests, with zero failures and 23 opt-in tests skipped. No compiler errors or warnings were emitted.

Reproduction: run `python3 scripts/playback-network-fixture.py` on the Mac, then select `enveTests/StreamingInterruptionTests` in the AllTests plan. These tests skip when the fixture server is absent. Native UI methods are `ReaderInteractionUITests/testDisabledAudioSkippingDuringPagedNavigation` and `testDisabledAudioSkippingDuringScrolledNavigation`. Their EPUB is synthetic and bundled with the UI target.

The outage tests use the actual playback manager against a controlled transport. They do not exercise every provider's live authentication, expiring links, TLS configuration, or the reporter's book. The original natural chapter-skip report still needs the affected book. No code was committed or pushed.

The final five streaming/retry tests also passed on iPadOS 17.5, with zero failures or skips, using the saved fixture server script. Temporary server and Android USB port forwarding were removed afterward.

Final iPadOS 17.5 native UI verification: both independent-navigation tests passed after the fixes, zero failures or skips. Both paged and scrolling modes preserved narration with audio skipping off and sought to the second chapter with it enabled. The matching iOS 27 UI run also passed both cases.
