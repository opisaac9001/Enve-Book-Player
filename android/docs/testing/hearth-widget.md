# Unified Hearth widget

Verified locally on Pixel 7a (Android 17), 2026-09-14.

## Behavior

- One registered widget: **Your Hearth**. Existing audio-widget placements use the same receiver.
- Shows the first book from `LibraryFacade.continueBooks`, in the same order as the app. Falls back to the first playable Up Next item. No fallback to arbitrary downloads, finished books, or the old snapshot.
- When both sections are empty: **Light a new fire**.
- Ebooks open their reader and show reading progress without audio controls. Linked/bundled ebooks resolve to the appropriate reading edition.
- Audiobooks have play/pause and, where space permits, skip controls. Starting a queued book preserves the rest of the queue.
- Read-along opens the narrated reader. An active narration also exposes play/pause, scoped to its exact book key and session ID; it cannot control another book's audio. After process death, Read along reopens the reader to resume narration there.
- Embedded M4B covers and single-book folder covers are supported. EPUB media-overlay references identify read-along books; merely containing an audio asset does not.
- Covers retain their aspect ratio. Compact, wide, and large layouts adapt controls to available space.

## Verification

```sh
./gradlew :app:assembleDebug :app:assembleRelease :app:testDebugUnitTest :engine:testDebugUnitTest :local:testDebugUnitTest :app:assembleDebugAndroidTest
adb -s DEVICE_SERIAL install -r app/build/outputs/apk/debug/app-debug.apk
adb -s DEVICE_SERIAL install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb -s DEVICE_SERIAL shell am instrument -w -e class com.enve.app.widgets.WidgetRoutingTest com.enve.app.debug.test/androidx.test.runner.AndroidJUnitRunner
```

Debug and minified release builds passed with no errors or new warnings. The existing experimental-API warnings in the untouched `ReaderPreferencesTest` remain. Unit results: app 131, engine 186 (one skipped), local 3; zero failures/errors. These include 11 widget-selection/session-isolation tests. All seven widget instrumented tests passed, covering the single provider registration, reader routing, EPUB media-overlay classification, and live snapshot observation.

Device checks use Webster's dictionary EPUB, the full-cast Chamber of Secrets M4B, and the workspace's narrated Midnight EPUB, all with their own covers. Narration play/pause was verified against the actual media session, not just the icon. Reader routing for PDF/comics is instrumented-test coverage, not a full PDF/comic reading-session claim. Remote authenticated providers were not exercised in this pass.

Midnight has narration for the prologue and first chapter, not the entire novel. Its library percentage switches between narration-relative progress during playback and text-relative progress during reading; this existing reader/progress behavior is not changed here. The widget mirrors the library value and labels read-along progress "complete" rather than implying that the percentage always means text pages read. Audio play/pause, 30-second skips in both directions, resume after an app restart, and 2×2 / 4×2 / 4×4 resizing were exercised on the Pixel. Up Next fallback is covered by unit tests.

## Contributor provenance

This adapts Daryl's PR #21/#22 work to the requested single-widget design. The three original commits are retained in the public repository with Daryl's authorship:

- `338a6b466816ba37a9d14e8ef21e1e67ff7276d1` — ebook widget.
- `ef8d74425439d6ee4b9002569d3ecdcb58eb8809` — audiobook resize/artwork.
- `44b200141ae2856dfdf6593bfc9d66181084f800` — progress/control sizing.

The unified follow-up keeps the original contribution history intact. Its only ReaderViewModel edit supplies the read-along session's book key.
