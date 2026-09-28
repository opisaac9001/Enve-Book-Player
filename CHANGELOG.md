# Changelog

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
