# Hardcover integration verification

Hardcover is an optional outgoing reading tracker. Connect in Hardcover Hub, then enable reading-progress sync. Tokens remain in CredentialVault. Book links and the sync preference are stored per Enve profile.

Audio checkpoints, ebook progress, and marking a library book finished submit progress. Automatic matching first queries editions using validated ISBN/ASIN metadata. Only a unique, consistent edition is selected. Conflicts require the Hub’s Link action; no identifier hit falls back to a single exact normalized title-and-author result. Android’s existing metadata model exposes one `isbn13` field, so ISBN-10 or ASIN matching is available when the provider stores that identifier there. Unlinking prevents automatic rematching. Sync resolves the current account's user-book row directly, rather than searching the displayed shelf.

Progress uses the selected Hardcover edition's duration or page count. Completed reads are preserved; a finished book starts a new read only when local progress returns near the beginning. Events are written to a focused Room database beside each profile’s reader database before any network request. They retain their original timestamps, book metadata, account fingerprint, and retry state across process death. Replay starts when the profile becomes active and resumes when connectivity returns. Progress coalesces within a reading pass; completion and subsequent reread events retain their order. Only the acknowledged event is removed. Hardcover does not restore Enve’s playback position.

Disabling sync pauses saved work. Disconnect discards the queue. Account replacement cannot replay another token’s events: rows are scoped to a SHA-256 token fingerprint, with no raw credential or playback URL in the queue. Transient network/408/429/5xx failures use bounded backoff. Rejected operations remain visible in the Hub until retried or discarded; linking a book retries its failed matching events. No operating-system background execution is promised.

All Hub and sync requests use the same per-account request budget within a profile runtime. It accounts for GraphQL root fields, legacy and structured remaining/reset headers, and numeric or HTTP-date `Retry-After`. Long waits are returned to the queue for rescheduling. Cancellation and account checks prevent later requests from continuing after disconnect. Cooldowns are in memory; queued retry deadlines survive restart.

## Local verification

The requests were checked against the [official schema](https://github.com/hardcoverapp/hardcover-docs/blob/1533b83896c393de5fda53ee721e9ddf58e1edd2/schema.graphql) on 2026-10-27. Hardcover unit tests cover matching, edition progress, read lifecycle planning, completed-read display, and nested mutation failures.

Run with a supported JDK:

```sh
./gradlew :engine:testDebugUnitTest :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease
```

## Live verification still required

Use a signed-in account and designated test books on the connected Pixel 7a:

1. Confirm an invalid replacement token leaves the existing account token intact.
2. Enable sync; link one ebook and one audiobook, including a book outside the first displayed shelf page.
3. Advance each book, pause or close, and confirm the correct page/seconds progress on Hardcover.
4. Finish, repeat the finish event, then begin a new reading pass. Confirm the prior completed read remains intact and no duplicate reads appear.
5. Disconnect or disable sync during pending work and confirm no subsequent account writes occur.
6. Unlink a book and confirm later progress does not automatically relink it.
7. Change an annual reading goal and confirm its other conditions and privacy remain unchanged.

Automated tests and a healthy emulator cold start do not establish these live-account results.


## Showcase reference review — 2026-10-27

Source snapshots reviewed:

- [Softcover Multiplatform](https://github.com/CinqueIzumi/Softcover/tree/9b7c20c94ce5824e7240bc161a9d12336930d63a): Room-backed pending writes, replay/rejection handling, shared request pacing, and exact ISBN edition queries. MIT.
- [Softcover for iOS](https://github.com/komadorirobin/Softcover/tree/a3c78889e15935ede84eda1ba5d8245e8591ba9a): persisted account-specific operations, pending/failed state, and response-header-driven rate limiting. No license file found in the reviewed tree; behavioral reference only.
- [Audiobookshelf Hardcover Sync](https://github.com/drallgood/audiobookshelf-hardcover-sync/tree/ce2449593c5e48598a55f441aac14d634fbe3f23): ISBN/ASIN and edition matching, existing user-book lookup across editions, current read mutations. Apache-2.0.
- [Hardcover KOReader plugin](https://github.com/Billiam/hardcoverapp.koplugin/tree/fa352e777e96e983dd43b35ed6d83f89531a196c): identifier linking and edition-page mapping. MIT.

The reviewed reliability upgrades are now implemented: durable outgoing work, identifier-first matching, and shared pacing. Regression tests cover a second offline completion after a reread, original start timestamps, failure/backoff preservation, acknowledgement isolation, and completion retry after the read was written but before shelf status succeeded. A separate instrumented test verifies an actual Room file across close/reopen. No source code was imported.

Live validation must still cover offline completion followed by process death, replay after reconnect, account replacement with pending writes, and simultaneous Hub/sync traffic against a signed-in account. Interactive device verification remains outstanding.

## Validation results — 2026-10-27

- Build: `:engine:testDebugUnitTest :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:assembleDebugAndroidTest` succeeded. No new compiler warnings or errors appeared.
- Engine: 838 tests, 0 failures, 1 skipped. App: 237 tests, 0 failures, 0 skipped.
- `HardcoverOutboxDatabaseTest` passed on an Android 36.1 Pixel 7a emulator, using a real Room file across close/reopen.
- The final debug APK installed and cold-launched successfully (`Status: ok`, 3.57 seconds). The process remained running with no AndroidRuntime errors in the checked log window.
- All 15 extracted GraphQL requests validated against the pinned official schema. `git diff --check` passed.

These checks do not replace the signed-in workflow above. Interactive Hub/queue verification and remote progress verification require a signed-in test account and device.
