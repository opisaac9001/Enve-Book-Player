# Hardcover integration

Hardcover is a reading-tracking destination, independent of the library provider. Enve uses the GraphQL API at `https://api.hardcover.app/v1/graphql`. The API token stays in Keychain and is sent in the Authorization header. Connect through Hardcover → Connect Hardcover; the connection screen also exposes the reading-progress sync switch.

## Ownership

- `HardcoverService`: account queries, discovery, shelves, reviews, goals, editions, and reading mutations.
- `HardcoverSyncService`: per-Hardcover-book serialized synchronization, conservative matching, edition selection, and sync errors.
- `HardcoverPendingStore`: atomic, account-scoped outgoing events in the owner profile’s application-support directory.
- `HardcoverRequestPacer`: the shared account request budget for discovery and sync.
- `SettingsManager`: the existing Keychain boundary, sync preference, and saved matches.
- `HardcoverRequestTests` and `HardcoverResponseDecodingTests`: isolated request/response fixtures; no real account writes.

Saved matches use Enve's source-aware stable book ID. Previously saved raw or unique IDs are migrated when that book is used. Automatic matching first checks valid ISBN/ASIN metadata against editions. A unique, consistent identifier match retains the edition ID. Conflicting or ambiguous editions require manual selection. With no identifier hit, matching requires one exact normalized title-and-author result. User-book rows are looked up by Hardcover book ID, rather than searching only the first 200 shelf entries. User-book IDs are resolved for the current account.

## Progress

Audio and ebook playback report fractions. Sync converts the fraction using the selected Hardcover edition's `audio_seconds` or `pages`. It sends `progress_seconds` for audio editions and `progress_pages` for page-based editions. It never sends Enve playback seconds against an edition with a different duration.

Before inserting a read, query the latest read after any status change; Hardcover can create a read when marking a book Currently Reading. Reuse an unfinished read. A new reading pass uses a new read rather than overwriting a completed one. Repeated completion is idempotent, including retrying a failed status update after the read was finished.

Create reads with `insert_user_book_read(user_book_id: $userBookId, user_book_read: $read)`, where `$read` is `DatesReadInput`. Update reads with `update_user_book_read(id: $id, object: $read)`. Validate both GraphQL errors and the nested mutation error/result. Unsupported requests must fail visibly instead of reporting success with a zero read ID.

The audiobook timer runs every 60 seconds and flushes on pause. Successfully persisted events advance progress suppression. Reader close pushes its current fraction or completion. A sync operation retains its original account token and stops if the token changes or sync is disabled. Events are atomically saved before network work, and replay after relaunch, foregrounding, or connectivity restoration. Consecutive progress events coalesce while preserving completion-before-reread ordering and original dates. Only the acknowledged event is removed. Transient failures use bounded backoff; permanent errors stay saved until explicitly retried. Pending/failed counts and retry are visible on the connection screen.

Replay is owner-profile-only and stops when the profile locks, the account changes, or sync is disabled. Queue ownership uses a SHA-256 token fingerprint; no credential or media URL is stored in the queue. Disconnect discards that account’s pending work. Token replacement does not transfer old events to the new token. Corrupt queue files are preserved, and storage failures remain visible. Replay runs while the app is active; no operating-system background execution is promised.

All requests share per-account pacing, including GraphQL root-field cost and server cooldown headers. Numeric and HTTP-date `Retry-After` values are honored; long cooldowns are returned to the persisted worker. Account and cancellation checks run again after waiting. Permanent GraphQL rejection is not automatically retried.

## Goals and reviews

The goal UI edits an active annual `book` goal. Use `insert_goal(object:)` or `update_goal(id:, object:)` with the complete `GoalInput`; preserve conditions, dates, description, and privacy on update. Display the server's goal progress rather than counting every finished book regardless of conditions. Goal mutation errors remain visible in the editor.

Reviews use `UserBookUpdateInput.review_markdown`, passed as GraphQL variables. Profile counts use `followed_users_count` and `followers_count`.

## API reference and verification

Checked against the [official Hardcover schema](https://github.com/hardcoverapp/hardcover-docs/blob/1533b83896c393de5fda53ee721e9ddf58e1edd2/schema.graphql) on 2026-10-27, and the vendored Softcover reference at `Other apps/Book Readers & Players/Softcover-main/ReadingProgressWidget/HardcoverService.swift`.

Request fixtures cover read insertion/update, audio progress, exact shelf lookup, nested failures, goal preservation, review escaping, account changes, and conservative matching. Live verification still requires a signed-in account: match an ebook and audiobook, advance each, pause/close, confirm the remote progress, finish, reopen for a re-read, and confirm the previous finished read remains unchanged. Use a designated test book before making these account writes.


## Showcase source review — 2026-10-27

Reviewed the showcase entries from the official docs repository at `1533b83896c393de5fda53ee721e9ddf58e1edd2`, then fetched these upstream source snapshots. This is a source review, not evidence of successful live-account behavior.

| Reference | Reviewed revision | Relevant implementation |
| --- | --- | --- |
| [Softcover for iOS](https://github.com/komadorirobin/Softcover) | `a3c78889e15935ede84eda1ba5d8245e8591ba9a` | `Hardcover Reading Widget/OfflineWriteQueue.swift`: persisted account-specific operations, retry scheduling, pending/failed counts. `ReadingProgressWidget/HardcoverNetwork.swift`: shared request budget, server headers, account isolation. |
| [Softcover Multiplatform](https://github.com/CinqueIzumi/Softcover) | `9b7c20c94ce5824e7240bc161a9d12336930d63a` | `core/connectivity/.../UserBookWriteReplay.kt`: replay outcomes distinguish transient failures from rejected payloads. `core/database/.../PendingUserBookWriteEntity.kt`: durable pending operations. `core/network/.../RateLimitInterceptor.kt`: shared pacing; `GetEditionsByIsbns.graphql`: exact identifier lookup. |
| [Audiobookshelf Hardcover Sync](https://github.com/drallgood/audiobookshelf-hardcover-sync) | `ce2449593c5e48598a55f441aac14d634fbe3f23` | `internal/sync/service.go`: ISBN/ASIN metadata, edition matching, and checking an existing user-book across editions. `internal/api/hardcover/client.go`: current read mutations and response-header-driven request pacing. |
| [Hardcover KOReader plugin](https://github.com/Billiam/hardcoverapp.koplugin) | `fa352e777e96e983dd43b35ed6d83f89531a196c` | `hardcover/lib/hardcover_api.lua`: identifier and edition lookup. `hardcover/lib/page_mapper.lua`: real page labels where available, proportional edition-page mapping otherwise. |

### Implemented reliability upgrades

The three reviewed gaps are now implemented: durable outgoing progress, identifier-first edition matching, and shared request pacing. `HardcoverReliabilityTests` covers disk reopen, completion/reread ordering, acknowledgement isolation, account separation, storage failure, permanent failure, identifier conflicts, and rate-limit delays. Request fixtures verify original event dates and timestamps. Live signed-in replay remains a verification gate; mocked requests and local persistence tests do not establish remote-account behavior.

Use these as behavioral references and verify against the official schema and local tests. Reference code also has defects: the reviewed KOReader `createRead` checks the update-response key before reading its insert result. No source was copied. Kotlin Softcover and the KOReader plugin include MIT licenses; the ABS sync project includes Apache-2.0. No license file was found in the reviewed Swift Softcover tree.

JustRead and Octavo are useful showcase UX references, but their entries do not link source repositories; the showcase is not exclusively open source.

## Local validation — 2026-10-27

- Signed iPhone Air build succeeded. Final `AllTests` run on iPhone Air: 1,692 passed, 0 failed, 36 skipped (`/tmp/enve-hardcover-upgrades-final.xcresult`).
- GraphQL requests validated against the pinned official schema; `git diff --check` passed.
- Installed and launched the final app, and captured Settings. Interactive dogfooding is blocked by the locked host Mac; no signed-in Hardcover account was available for live writes.
- The existing `CloudKitSink.swift:55` Sendable warning also appears in the baseline build. No new Hardcover warning was introduced.
