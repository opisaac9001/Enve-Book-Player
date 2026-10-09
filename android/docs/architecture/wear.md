# Enve on Wear OS

The watch can connect to Audiobookshelf or Grimmory, download books, and play those downloads without the phone. The existing phone remote is a separate choice on Home.

## First milestone

- Phone setup for Audiobookshelf and Grimmory, independent watch sessions, token refresh, multiple accounts, and account switching.
- One-time encrypted connection handoff. The watch creates a hardware-backed key, the phone encrypts the selected session for that request, and the phone waits for the watch to confirm that it saved the connection.
- Book libraries with paginated browsing.
- Wi-Fi downloads with pause/resume and interrupted-transfer recovery when the server supplies an ETag. Otherwise the interrupted track restarts. Completed tracks are retained.
- Local multi-track playback, chapter seeking, speed, sleep timer, bookmarks, and saved position.
- Headphones required unless the user explicitly chooses the watch speaker.
- Progress sync with a durable queue. If the watch and server both move from the last known position, the watch asks which one to keep. It never assumes the furthest position is correct. Bookmarks stay on the watch.

This is a development milestone, not a public watch release. Streaming, local-file transfers, tiles, cover art, search, crown controls, and other providers remain outstanding.

## Boundaries

`wear` depends on `wear-protocol` for phone commands, plus external Android libraries. It does not depend on `core`, `engine`, or the phone providers. Watch implementation lives in `wear/listening`; the existing companion classes still own phone control.

`WatchAudiobookProvider` is the watch-only provider contract. `WatchAbsClient` and `WatchGrimmoryClient` implement it without depending on the phone app's provider graph. `CredentialVault` encrypts sessions with Android Keystore and stores them outside backups. The phone uses the password once to create a separate server session for the watch, then discards it. Passwords are not saved or sent to the watch. HTTP remains available for user-supplied LAN servers. Redirects are not followed, and audio credentials cannot cross origins.

Connections are created and managed in the phone app. Linking currently supports local Audiobookshelf and Grimmory passwords; browser and SSO linking still need provider-specific flows. The watch publishes a five-minute, single-use request containing a hardware-backed public key. The phone creates a dedicated server session, wraps its tokens with that key, sends the encrypted envelope directly to the requesting node, and reports success only after the watch saves the account and returns a matching acknowledgement. Consuming a request invalidates it, including when decryption fails.

`WatchLibraryStore` atomically persists book metadata, progress baselines, pending progress, conflicts, and bookmarks. Book storage keys include provider, server, and account identity. `WatchDownloadWorker` uses WorkManager with unmetered-network and storage constraints. Downloads are serialized; only a completed set of tracks becomes playable. `WatchProgressSyncWorker` runs with a network constraint and retries temporary connection failures. `WatchPlaybackService` owns Media3 playback and the media session, independently of the activity.

## Next milestones

1. Real-server verification for ABS and Grimmory before enabling a public watch release.
2. Phone transfers. Add local books and an explicit file handoff.
3. Add Storyteller, Plex, BookOrbit, Silo, Jellyfin/Emby, and OPDS/local transfer one at a time, with a fixture and real-server check for each.
4. Watch polish. Covers, search, rotary input, a Now Playing tile, watch-face shortcut, storage totals, and accessibility work on different round screens.

## Provisional release version code

The phone and Wear apps share `com.enve.app`, so Wear uses a separate version-code range: `1,000,000 + enve.wearReleaseNumber`. The phone uses `enve.phoneReleaseNumber` directly. Both release numbers are currently 52 in `gradle.properties`, yielding phone code 52 and provisional Wear code 1,000,052. Gradle rejects release numbers outside their separate ranges. Google requires a unique Wear code across form factors: https://developer.android.com/training/wearables/packaging. Play Console history is not available to this local build; confirm the proposed Wear code is unused and above the last Wear release before signing or uploading. This local allocation is not approval to publish.

## Verification

On 2026-09-28, the phone and watch debug and minified release builds passed. Seventeen watch/protocol JVM tests and nine instrumented tests passed on the Wear OS 6.1 ARM emulator. The full phone JVM suite also passed, including separate-session fixtures for Audiobookshelf and Grimmory. No new compiler warnings were reported. Full lint still reports pinned-dependency update advisories and existing companion UI suggestions; these are not a clean-lint release sign-off.

The instrumented tests cover local ABS and Grimmory fixtures, encrypted multi-account session storage, account/origin isolation, token refresh, progress conflicts and deliberate rewinds, interrupted downloads with byte-for-byte validation, and two-track playback after shutting down the fixture server. They also check playback with the activity stopped, seeking, speed, pause, bookmark persistence, timer setup, and position restoration after restarting the playback service. These are not live-server tests or an OS reboot test.

Still required: a paired phone/watch check of connection handoff, hands-on round-screen navigation, timer expiry, process death/reboot, the minimum supported Wear version, minified APK runtime, real ABS and Grimmory authentication, and a physical watch with headphones. Battery drain and Bluetooth reliability cannot be established in the emulator. Do not publish this milestone as release-ready.

The test audio is an original 120-second 440 Hz tone generated with FFmpeg, not a book or recording supplied by a user. It is packaged only in the instrumentation APK.

## References

[NortlinOS](https://github.com/SolfenTheDragon/NortlinOS/tree/13c31fb) informed the feature plan and API review. No upstream source files were vendored. Its GPLv3 license must accompany any later source adaptations. The ABS server source was checked for login/refresh response behavior. Playback uses [Android's Wear media guidance](https://developer.android.com/media/implement/surfaces/wear-os).
