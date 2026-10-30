# Book collection UI verification

Verified 2026-10-25 on Pixel 7a (34181JEHN24801).

The Android Hearth palette now matches the iOS book collection: warm brown/cream, layered bindings, outlined controls and wood shelf ledges. The original launcher icon is unchanged. The empty-screen mark is a transparent rendering of the existing SVG, with its background path omitted in `BuildSupport/AppIcon/enve-book-player-mark.svg`.

- `./gradlew :app:assembleDebug :app:assembleDebugAndroidTest :hearth-ui:testDebugUnitTest :app:testDebugUnitTest :app:assembleRelease`: passed. The release build exercises R8 and resource shrinking.
- App unit tests: 230 passed. Hearth UI unit tests: 69 passed.
- Existing `MantelBarGestureTest` on the Pixel: 5 passed. Tab taps select once; horizontal drags do not select; upward swipes open the item only when one exists.
- Installed and checked Hearth, Library, Settings, Light, Ink, OLED and 1.5x system font scale. The enlarged dock reserves its actual measured height and retains all four labels at the checked scale.
- `./scripts/verify-provenance` and `git diff --check`: passed. No new Kotlin compiler warnings; the existing SDK XML tooling warning remains.
- E-ink keeps the monochrome palette, plain cover border and flat shelf rule. Physical e-ink hardware and populated book-cover shelves were not exercised in this pass.

Existing reader/TTS and library-control WIP was preserved. The app and unit verification used that full local checkout; this design change does not publish that WIP.

No authentication, provider, persistence, download, playback-engine or emulator-core behavior was changed by this UI pass. Screenshots from personal libraries and settings remain outside the repository. Physical-device navigation and theme checks used the existing Pixel 7a; no user connections or media were removed.
