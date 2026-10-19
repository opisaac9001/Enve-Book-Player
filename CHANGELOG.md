# Changelog

## 2026-10-19

Source update for iOS 1.2.6 and Android 1.2 build 55.

- iOS adds comic series, volumes, and specials; streamed Kavita and Komga pages; consistent offline availability; and bounded reading cache.
- iOS includes reader, playback, authentication, profile, and download fixes, plus an Audiobooks only preference.
- Prevent a crash when queued library updates finish after switching profiles.
- Android keeps skip-button numbers proportional to their icons at larger text sizes.
- Series queries and presentation state have separate files. Unused helpers, duplicate logic, and temporary implementation notes were removed.

### Verification

- iOS: 1,518 tests passed, 32 skipped. Comic navigation and accessibility checks passed on iPhone Air and iPad; tvOS and Watch builds passed.
- Android: 1,287 unit tests passed, one skipped; debug and minified release builds passed. Pixel playback and skip controls were exercised at enlarged text size.
- Sensitive-source and provenance checks passed on both platforms.

Existing SMB dependency compiler warnings remain. Live-provider tests requiring local configuration and physical-device comic performance checks remain outside this verification.

## 2026-10-09

Public source update to iOS 1.2.6 and Android 1.2 build 53.

Both platforms include separate user profiles, provider and sync fixes, reader improvements, and code cleanup.

- [iOS changes](ios/CHANGELOG.md)
- [Android changes](android/CHANGELOG.md)
- [Signed Android APK and corresponding source](https://github.com/opisaac9001/Enve-Book-Player/releases/tag/v1.2.53)

### Verification

- iOS: 1,267 tests passed, ten live-service tests skipped; simulator build and launch passed.
- Android: 2,244 tests passed, two skipped; debug build, release lint, and acknowledgement inventory passed.
- Sensitive-source and asset provenance checks passed for both platforms.

Existing bundled iOS library compiler warnings and Android lint warnings remain. Live-provider and hardware checks listed in the platform testing guides remain open.

## 2026-09-28

This brings the public source to iOS 1.2.5 and Android 1.2 build 52.

Most of this update is reader and sync work: keeping the right position between devices, getting listen-along resume right, and fixing highlights and provider quirks. Both apps also get expanded OPDS support and a rest-your-eyes reminder.

- [iOS changes](ios/CHANGELOG.md)
- [Android changes](android/CHANGELOG.md)

The previous public snapshot contained iOS 1.2.3 and Android build 51. These notes cover source changes; they do not announce a new App Store or APK release.

### Verification

- iOS: 1,149 tests passed, eight live-service tests skipped; simulator launch checked.
- Android: debug and release builds passed, with 191 app unit tests passing.
- tvOS and Wear OS builds passed.
- Secret scans and bundled-asset provenance checks passed for both platforms.

iOS testing reported SMB dependency compiler warnings and audio-session runtime warnings.

### Verification limits

The signed Android build 52 APK has not completed its Pixel install-and-launch check because the USB connection dropped during transfer. This source update does not publish that APK. Live-provider and hardware checks still listed in the platform testing guides remain open.
