# Android StoryAlign chapter investigation — October 12, 2026

Farqiplier reports natural chapter skips on Android build 52, probably using an Audiobookshelf audiobook and ebook aligned locally with StoryAlign. The affected generated EPUB is not available, so the exact 10→12 or 22→24 skip remains unconfirmed.

Previous Android device tests covered chapter transitions, shared audio files, chapters spanning multiple files, and pause/resume. They did not cover StoryAlign export from chapter documents with matching filenames in different folders. The StoryAlign exporter was unchanged between the build-52 source and the build-53 source at `e200e09`.

## Reproduction and fix

`part-one/chapter.xhtml` and `part-two/chapter.xhtml` both generated `storyalign/MediaOverlays/chapter.smil`. The second chapter overwrote the first chapter's SMIL, and manifest deduplication omitted the second overlay entry. The regression test failed with two expected overlay entries and only one present.

The exporter now gives each aligned chapter a distinct overlay filename. Regeneration also updates existing manifest entries to point to the new files. The regression checks separate overlay entries, distinct paths, and each chapter's own text reference, including a pre-existing overlay entry.

## Verification

- App and engine unit suites: 801 passed, zero failures; one existing engine test skipped.
- Debug app, instrumentation APK, and minified release builds passed with zero errors and no new warnings.
- Pixel 7a: four real Media3 playback cases passed, including a book exported by StoryAlign with four identically named chapter documents in separate folders. The other cases cover natural transitions, shared/multiple audio files, and pause/resume.

The fix and tests are uncommitted in a separate `main` worktree. The active Grimmory readiness work was preserved. No repository push or app release was performed.

An already-generated EPUB is not rewritten by the code change. An affected read-along must be regenerated after the corrected app is installed. The reporter's generated EPUB and a repeatable chapter boundary are needed to establish whether this collision caused their specific report. These checks do not prove every alignment-related chapter skip is resolved.
