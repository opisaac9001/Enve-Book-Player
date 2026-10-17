# Reader feedback verification — 2026-10-11

## Changes

Readium scrolling mode disables horizontal chapter swipes. Side taps and the existing next/previous reader commands scroll roughly one screen within the current chapter. Paged navigation continues through Readium's existing navigation methods. A blocked scroll at a chapter boundary clears the pending manual-navigation marker, so a later narration update cannot inherit that input.

When automatic read-along following brings an off-screen passage into view, it places the passage in the middle of the viewport. Following remains controlled by the existing automatic page-follow setting. Already-visible passages are left in place, and scrolling does not animate through intermediate text on an e-ink display.

## Verification

- Reader unit tests: 79 passed, zero failures or skips.
- Read-aloud/media-overlay engine unit tests: 52 passed, zero failures or skips.
- Debug and minified release builds passed, without new compiler warnings.
- Pixel 7a: native reader tests passed for scrolling navigation, horizontal swipe protection, paged navigation, and read-along centering. The real Media3 playback test visited all four chapters across separate audio files while playback reconciliation ran every 20 milliseconds.
- Bigme B7: the same three device tests passed, zero failures or skips.
- Repository provenance and whitespace checks passed.

Device tests create their own EPUBs and audio, use unique book IDs, restore reader preferences, and remove their fixture files. They do not require a backend login.

## Remaining report

The user's reported automatic 10→12 or 22→24 chapter skip was not reproduced. Controlled multi-file playback passed; this does not establish that the affected book is fixed. The affected EPUB or read-along source and a reproducible chapter boundary are still needed. No speculative change was made to the playback transition engine.

No changes were committed or pushed.

## Additional pre-push verification

- Pixel 7a: three actual playback instrumentation tests passed, zero failures or skips.
- Bigme B7: all three playback instrumentation tests passed, zero failures or skips.
- Mixed-layout coverage includes a chapter spanning two files, several chapters sharing a file, nonzero clip offsets, and pause/resume at a shared-file chapter boundary. Assertions check both chapter order and individual audio segments while the reader repeatedly reconciles playback position.
- No production transition changes were needed. The affected book/source and a reproducible chapter boundary are still needed to pinpoint the reported chapter skip.

## Network interruptions and independent reading

A matching paragraph ID in another chapter incorrectly suppressed manual audio seeking. The fixture reuses paragraph IDs across chapters. The visibility check now verifies the chapter too.

Actual reader instrumentation turns “Skip audio on page turn” off, moves forward/backward, jumps with reading progress and contents navigation, and checks that paused audio stays fixed and playing audio remains on its original segment. It then enables the option and confirms a seek to the new chapter. Paged and scrolling modes passed on Pixel 7a and Bigme B7, including with airplane mode enabled. Original airplane/Wi-Fi settings were restored. The synthetic fixture exposes two reading positions; an 80% progress selection resolves to its second chapter.

Four streaming scenarios passed on both physical devices: buffer exhaustion and recovery, an active connection dropping, remaining paused after connectivity returns, and initial connection failure followed by retry. The initial-failure test also passed using the real AudioPlaybackManager toggle action used by the player UI, instead of preparing the player explicitly from the test.

Streaming uses the actual PlaybackService through MediaController. The HTTP fixture is forwarded over USB with ADB; its delivery is stalled or dropped by the test. Airplane-mode reader checks use audio extracted locally from the EPUB. This establishes controlled transport recovery, not every live provider's authentication or expiring-link behavior.

Reader unit tests: 79 passed. Read-aloud/media-overlay engine tests: 52 passed. Debug and minified release builds passed without new compiler warnings. Provenance and whitespace checks passed.

Reproduction: run `python3 scripts/playback-network-fixture.py` on the Mac, then `adb -s <serial> reverse tcp:18763 tcp:18763`. Run `StreamingInterruptionTest` and the two `ReaderScrollingNavigationTest/disabledAudioSkippingPreservesPlaybackDuring...Navigation` methods. Streaming tests skip if the fixture server is unavailable. Remove the port forwarding after testing. No credentials or third-party media are needed.

No code was committed or pushed. The original natural chapter-skip report still needs the affected book/source and a reproducible boundary.

Final cleanup confirmed airplane mode off on both devices. The owned fixture server and the two USB port forwards were removed. The final production patch changes only the narrated-chapter visibility check.
