# Reader position regressions — 2026-09-23

Scope: the reporting user’s reports of lost read-aloud position, non-navigating notes, seeking, and headset pause/resume. These changes address reproduced code-level failures; they do not establish that every reported symptom has the same cause.

## Changes

- Read-aloud server pushes now use the committed locator, fraction, and observation time instead of the immutable book snapshot from reader opening.
- Pause/close flushes retain a coherent audio-position snapshot rather than combining audio progress with a later visual-page locator. The local progress mirror also keeps the EPUB locator.
- Delayed visual anchor enrichment cannot overwrite audio position while read-aloud is active. Pending page saves/enrichment are canceled when closing the reader.
- Native Readium touch/keyboard activity now reaches the progress activity gate, including native swipes rather than only Enve's navigation buttons.
- Readium restore accepts short text quotes and CSS anchors. Tests for both failed before the change.
- Paused seeks retain their requested position until AVPlayer completes the seek; seeks across audio files select the correct queued file. Superseded completion callbacks cannot replace a newer seek.
- A missing visible overlay fragment no longer masquerades as the first fragment in the chapter.

## Verification

- Baseline and changed app built and launched on GM iPhone Air 27, arm64.
- `AllTests`: 1,020 passed, zero failed, eight opt-in live-service tests skipped. This plan contains unit tests, not UI tests.
- `UISmokeTests`, `enveUISmokeTests/testReaderPresentation`: one passed, zero failed. The run emitted Apple's runtime warning about synchronous `AVAudioSession` activation on the main thread; this is not a full narrated-reader workflow test.
- Audio regression exercises immediate and completed paused seeks, forward/backward cross-file jumps, and repeated remote play/pause/toggle calls using generated local WAV files.
- Simulator opened local narrated EPUBs, including the workspace's Midnight sample; page swipes rendered the next page. This is not a completed note-navigation or pause/reopen acceptance test. The reader's WebView was absent from the accessibility snapshot, and Device Hub's desktop accessibility connection timed out.
- No new compiler warnings reported. Xcode's existing App Intents metadata-extraction warning also appears in the baseline build.

## Remaining acceptance checks

Obtain the reporting user’s current Enve build, affected EPUB, current provider (Grimmory or Storyteller), and a saved note's locator. Fresh Grimmory notes imported with only a CFI have position zero and no native Readium locator; the short-quote fix does not add general CFI support. Do not treat those notes as verified fixed.

On the affected book: create a short note, move away, reopen the note; swipe while reading, close/reopen; start narration mid-chapter, lock, pause/resume, unlock, close/reopen; seek backward and across audio files while paused. Repeat the headset sequence with the reporting user’s Bose hardware. Simulator remote-command calls do not test Bluetooth delivery or MPNowPlayingSession ownership.

No production server, Discord messages, commits, pushes, or releases were changed. Pre-existing podcast edits were preserved.
