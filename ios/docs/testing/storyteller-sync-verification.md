# Storyteller loading and sync verification

Verified 2026-09-16 against a disposable Storyteller test server. Silveran's Storyteller download format selection and complete-locator progress handling were used as behavioral references.

## Fixes

- iOS no longer substitutes the ordinary ebook cache for Storyteller's read-aloud edition.
- iOS checks for SMIL and embedded audio before caching a downloaded read-aloud EPUB, and revalidates an existing read-aloud cache before reuse.
- Android pulls progress while online even when reading a downloaded book, and retains the remote locator when applying remote progress or choosing it in a conflict.
- Android imports an aligned read-aloud EPUB without requiring a separate ebook or audiobook asset.

## Verification

| Check | Result |
| --- | --- |
| iOS `enve` build, iPhone Air simulator | Passed, no warnings reported |
| iOS `AllTests` | 553 passed, 0 failed, 4 opt-in live tests skipped |
| iOS read-aloud runtime harness, valid fixture | 17 passed, 0 failed, 1 skipped (catalog chapters are built on open) |
| iOS malformed read-aloud fixture | Rejected with a specific error; not cached or opened |
| Android Storyteller, core, engine, and app unit tests | Passed |
| Android debug and minified release builds | Passed, no new warnings reported |
| Android read-aloud-only catalog import | Fixture appeared with Read and Listen actions |
| Android downloaded-book remote progress | Updated from location 19 / 18% to location 43 / 42% on reopen |
| iOS provenance and protected-marker checks | Passed |

The existing synthetic lab book is marked aligned by the server but its 1,966-byte read-aloud package contains neither SMIL nor audio. It was preserved as a malformed fixture. Added `Enve Readaloud Sync Regression`, an original 12-second EPUB with three synchronized passages, one SMIL resource, and embedded test audio. The valid fixture passed audio extraction, overlay playback, local/server locator round-trip, and reader presentation on iOS.

## Remaining device verification

Android testing used the authorized HiBreak. Its system refused to launch Enve debug's WebView sandbox services with `process is bad`; Readium's WebView remained invisible. This prevented verification of rendered text and completed read-aloud playback on that device, although catalog loading and reader locator restoration were observable. The connected Pixel 7a remained unauthorized, and no phone emulator was configured. Repeat rendered-text and read-aloud playback checks on an authorized healthy Android device before treating Android end-to-end verification as complete.

The standard EPUB fixture's server locator was restored to its pre-probe 18% position. No production server or media was used.
