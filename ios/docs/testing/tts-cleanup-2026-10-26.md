# iOS TTS cleanup — 2026-10-26

The active iOS narration engines are Apple voices and Kokoro. Ming and Supertonic integration files, download controls, narrator catalogs, debug routes, and engine-specific tests were removed. The local Ming native package and its Xcode dependency were also removed. FluidAudio remains for Kokoro.

`EbookTTSEngineChoice.swift` now owns the two engine choices and download-state type. `EbookTTSService` retains Kokoro voice selection, paragraph prefetch, playback state, progress, and Apple fallback. Persisted selections for retired or unknown engines are normalized to Apple without resetting pace, language, or the Kokoro narrator. Ming-only time-pitch and preparation UI support were removed from the shared helpers and sheet. The reader's existing stack-overflow fix remains in place.

URL story import was preserved. SHA-256 comparisons matched all 11 recorded importer, entry-point, test, and documentation files before and after cleanup. Unit coverage includes Royal Road extraction, chapter ordering, sanitization, EPUB construction, selection, and cancellation. UI coverage imported an original two-chapter story through a local HTTP fixture and opened it in the reader.

## Verification

| Check | Result |
| --- | --- |
| iPhone Air Simulator `AllTests` | 1,662 passed, 36 skipped, zero failures; no runtime warnings |
| Focused `UISmokeTests` | 8 passed, zero failures |
| Voice picker | Exactly Apple and Kokoro engine rows |
| Reader controls | Pause/resume, voice settings, paragraph navigation, normal controls during speech |
| Book opening | Three consecutive fixture opens with reader contents available |
| URL import UI | Whole-story import, browser preview/navigation, invalid URL, missing-chapter rejection |
| Simulator and signed iPhone builds | Passed; no new compiler warnings |
| Final iPhone bundle | No Ming framework, Ming resource bundle, or stale unit-test plugin |
| iPhone installation | Clean build installed and launched on the paired iPhone 16 Pro |

The existing `CloudKitSink.swift:55` Sendable conformance warning remains. The UI run recorded six system audio-session runtime diagnostics. This run did not repeat the opt-in physical Kokoro benchmarks or a live external-site import.

The unit command used `xcodebuild -scheme enve -testPlan AllTests` with parallel testing disabled. The UI command selected `ReaderBookOpeningUITests`, `ReaderTTSControlsUITests`, and `WebStoryImportUITests`, excluding the opt-in live Royal Road test. Both used the project’s iPhone Air simulator and external DerivedData directory. The temporary result bundles and screenshots were retained outside the repository for local review.

## Retained research

The removed Ming work, native framework slices, integration snapshots, test sources, benchmark results, and notices are preserved in an external research archive. Model weights are not included. Its SHA-256 is `4a97c2a0d64726e8e9b6dd6efc5710e266b7447513e05018c153174a8fe1f7e7`. Extract into a separate directory for future research; the snapshots should not replace current reader files wholesale.

Read-aloud references were refreshed and inspected at Silveran Reader `669a56903316fa51bf9c2850bdc89d9bbcac37dc` and Storyteller `0da18fab332df2c21ada9f4d11f9891f439c6c8b`.
