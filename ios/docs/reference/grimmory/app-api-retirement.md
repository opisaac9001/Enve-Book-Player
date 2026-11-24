# Grimmory app API retirement

Audit date: 2026-11-14. Enve Book Player for iOS and Android, including standalone Wear OS playback.

## Verified server

Before the audit, the test instance pulled `ghcr.io/grimmory-tools/grimmory:nightly` and reconciled only the Grimmory service. The running image already matched the registry image: `nightly-20261114-8ddca596b`, digest `sha256:0fc5f5b2e6c6cefe8a6ce06e4a5414deabfd2a264616a21156a18668d0729dbc`. Docker reported healthy and the web endpoint returned HTTP 200. No database, media, or service configuration was reset.

The source reviewed is [Grimmory revision 8ddca596b54754cf18792b2f4b089c661f25da50](https://github.com/grimmory-tools/grimmory/tree/8ddca596b54754cf18792b2f4b089c661f25da50). The deprecated namespace used by these Enve checkouts is `/api/v1/app/`.

## Replacement contracts

| App API operation | Available non-app API | Required adaptation |
| --- | --- | --- |
| List/search books | `GET /api/v1/books/page` | Use `facet=library:<id>`, `facet=shelf:<id>`, `facet=file_type:<type>`, `facet=read_status:<status>` and `query=<text>`. Repeat `facet` for multiple filters. Sort descending with a leading `-`, such as `sort=-addedOn`. |
| Catalog ID inventory | `GET /api/v1/books/ids` | Uses the same facet/query contract. Response is an ID array. |
| Book detail | `GET /api/v1/books/{id}?withDescription=true` | Decode nested `metadata`, `primaryFile`, and `alternativeFormats`. The top-level `title` can be absent. |
| Batch metadata and formats | `GET /api/v1/books/batch?ids=...` | Up to 500 IDs; decode the same non-app Book shape. |
| Shelves | `GET /api/v1/shelves` | Decode the standard shelf shape. Existing create/assign APIs already use non-app endpoints. |
| Magic shelves | `GET /api/magic-shelves` | List user-visible shelves. Browse membership with `facet=shelf:magic:<id>` on the book page/ID endpoints. |
| Series list | `GET /api/v1/books/facets/series` | Name and count come from facet values; book pages can supply membership and cover IDs where needed. |
| Books in a series | `GET /api/v1/books/page?facet=series:<name>` | Preserve library scope and use `sort=seriesNumber`. Combine the result with metadata and progress when a richer summary is needed. |
| Authors | `GET /api/v1/authors/page`, `GET /api/v1/authors/{id}` | Adapt nested pagination and the standard author DTOs; a detail response does not include every app-summary field. |
| Read status | `POST /api/v1/books/status` | Body is `{"bookIds":[123],"status":"READ"}`, rather than a path ID and `PUT`. The standard operation clears `dateFinished` when changing to `READING` or `ABANDONED`. |
| Progress writes | `POST /api/v1/books/progress` | Include `bookId` and `fileProgress`, identifying the actual ebook or audiobook with `bookFileId`. Percentages are 0–100. Preserve each format's locator and audiobook track coordinate convention. |
| Notebook entries | `GET /api/v1/notebook?bookId=<id>&sort=desc` | The live response has `content` and nested `page`, not the app API's `hasNext`. Omitting `bookId` returns entries across books. |
| Books with notebook entries | `GET /api/v1/notebook/books` | Returns an unpaginated list. The all-book notebook endpoint can avoid one request per book. |
| Current user | `GET /api/v1/users/me` | Decode the standard user response. |

Book and author browse responses have this envelope:

```json
{
  "content": [],
  "page": {"number": 0, "size": 100, "totalElements": 0, "totalPages": 0},
  "links": []
}
```

The live notebook response also nests pagination under `page`. Pass explicit `types=NOTE`, `types=HIGHLIGHT`, and `types=BOOKMARK`; omitting types returns no entries on this nightly. Browse page size is at most **100**, even though the former app endpoints accepted larger pages. `sort=id` returns HTTP 400; use a supported sort key. Cursor links preserve the server's random-sort seed and active filters. A lone facet whose value contains a comma is split by Spring and returns HTTP 400; repeating that same facet value avoids the split without changing the filter. This workaround was verified live and is applied to Android series browsing.

## Request for the Grimmory team: independent audiobook progress reads

**Blocking:** we cannot safely retire the app progress read solely by replacing it with `GET /api/v1/books/{id}`.

The standard Book service selects the most recently updated file across all formats, then enriches the Book with that file's progress. The app progress service separately selects the latest audiobook progress. Consequently, a later ebook update can hide a valid audiobook checkpoint from the standard Book response. The standard typed progress objects also omit `updatedAt`.

This was reproduced read-only on the nightly test instance. A book with EPUB and AUDIOBOOK formats returned EPUB progress at 100% from both APIs. The app progress response additionally returned an audiobook position of 7,000 ms at 11.6667%, with its earlier audio update timestamp. The standard Book response omitted `audiobookProgress`. Its aggregate `lastReadTime` belonged to the later ebook update and cannot substitute for the audio timestamp. `/api/v1/audiobooks/{id}/info` contains media metadata, not the saved checkpoint; viewer settings likewise do not supply it.

Sources: [BookService](https://github.com/grimmory-tools/grimmory/blob/8ddca596b54754cf18792b2f4b089c661f25da50/backend/src/main/java/org/booklore/service/book/BookService.java), [ReadingProgressService](https://github.com/grimmory-tools/grimmory/blob/8ddca596b54754cf18792b2f4b089c661f25da50/backend/src/main/java/org/booklore/service/progress/ReadingProgressService.java), [AppBookService](https://github.com/grimmory-tools/grimmory/blob/8ddca596b54754cf18792b2f4b089c661f25da50/backend/src/main/java/org/booklore/app/service/AppBookService.java), [AppBookMapper](https://github.com/grimmory-tools/grimmory/blob/8ddca596b54754cf18792b2f4b089c661f25da50/backend/src/main/java/org/booklore/app/mapper/AppBookMapper.java).

### Alternatives checked

| Candidate replacement | Finding |
| --- | --- |
| Book detail + `primaryFile` / `alternativeFormats` | File inventory identifies the audio file, but contains no saved checkpoint. The Book enrichment chooses the latest file across all formats. |
| Batch books + audiobook metadata | Batch uses the same progress selection as detail; audiobook info supplies duration and tracks but no saved position. Combining them cannot recover the omitted checkpoint. |
| Book browsing filtered by `file_type:AUDIOBOOK` | The facet selects books that contain audio; it does not select the audio file's progress. The same omission was reproduced live. |
| Viewer settings | Reader preferences, not playback position. |
| Reading-session history | Separately recorded telemetry; progress saves need not create sessions. It cannot reliably represent the last checkpoint, rewind, or explicit zero. |
| Listening completion statistics | Aggregates session progress, rounds it, and limits the result to ten in-progress books. It has no exact position, track index, file identity, or checkpoint timestamp, and requires statistics permissions. |
| KOReader / Kobo state | Ebook reading state and synced EPUB file selection, not audiobook checkpoints. These also use separate device-sync authentication/configuration. |
| Notebook / bookmarks | User-created artifacts, not the canonical playback checkpoint. Writing Enve-specific bookmarks would not retrieve progress saved by other clients. |

The code trace covers the progress repository's readers: the standard Book APIs share `fetchUserFileProgress`; only the app service selects the audiobook independently. The file-specific `fetchUserFileProgressForFile` helper has no controller caller. Kobo's file-specific reader explicitly selects a synced EPUB. Supporting sources: [BookPageFetcher](https://github.com/grimmory-tools/grimmory/blob/8ddca596b54754cf18792b2f4b089c661f25da50/backend/src/main/java/org/booklore/service/browse/BookPageFetcher.java), [ReadingSessionService](https://github.com/grimmory-tools/grimmory/blob/8ddca596b54754cf18792b2f4b089c661f25da50/backend/src/main/java/org/booklore/service/ReadingSessionService.java), [KoboEntitlementService](https://github.com/grimmory-tools/grimmory/blob/8ddca596b54754cf18792b2f4b089c661f25da50/backend/src/main/java/org/booklore/service/kobo/KoboEntitlementService.java).

### Second-pass source and live verification

A second audit traced the stored audio coordinates (`UserBookFileProgressEntity.positionData`, `positionHref`, and `lastReadTime`) through repository callers, DTO mapping, controllers, and the web player at the same running revision. The precise finding is **not that other code cannot return audio position**: standard Book APIs can return it when the selected latest file progress is AUDIOBOOK. They cannot reliably retrieve an independent audio checkpoint when another format was updated later.

- The web audiobook player calls `fetchFreshBookDetail` and restores `book.audiobookProgress.positionMs` and `trackIndex`. It has no separate hidden progress-read API. Its save operation also patches the browser query cache, which is not a cross-device/server read replacement.
- The standard book-detail controller accepts only `bookId` and `withDescription`. Adding `bookFileId`, `bookType=AUDIOBOOK`, or both does not select audio progress. Live checks confirmed this for three dual-format books.
- Legacy `/api/v1/libraries/{libraryId}/book/{bookId}` maps book metadata without enriching user progress. It omitted audio progress even for the two books where standard detail returned it.
- `fetchUserFileProgressForFile(userId, bookFileId)` can read the exact saved row internally, but has no caller. The audio-specific repository query is called only by the app service's detail and progress reads. Exposing either existing lookup is a possible small server change; the checkpoint data already exists.
- Reading-session history can contain historical audio locations. The web client writes these as formatted time strings, discards sessions shorter than 30 seconds, and does not include its track index or file ID in that session payload. Those locations cannot reliably replace the saved checkpoint.
- File attachment/detachment responses use the same latest-file selector. Komga compatibility, OPDS, viewer settings, and WebSocket notifications do not expose another independent audiobook checkpoint read.

Read-only live results: 12 selector/legacy checks passed across books 30278, 30279, and 30280, plus a positive standard-browse audio-position control. Standard detail returned audio for 30278 and 30279; 30280 still omitted it while the app progress read retained it. This distinguishes a conditional existing capability from the specific missing guarantee. No progress was written during this recheck.

Source entry points: [standard detail controller](https://github.com/grimmory-tools/grimmory/blob/8ddca596b54754cf18792b2f4b089c661f25da50/backend/src/main/java/org/booklore/controller/BookController.java#L166), [progress selection and unused per-file lookup](https://github.com/grimmory-tools/grimmory/blob/8ddca596b54754cf18792b2f4b089c661f25da50/backend/src/main/java/org/booklore/service/progress/ReadingProgressService.java#L59), [audio-specific repository query](https://github.com/grimmory-tools/grimmory/blob/8ddca596b54754cf18792b2f4b089c661f25da50/backend/src/main/java/org/booklore/repository/UserBookFileProgressRepository.java#L43), [web player initialization](https://github.com/grimmory-tools/grimmory/blob/8ddca596b54754cf18792b2f4b089c661f25da50/frontend/src/app/features/readers/audiobook-player/audiobook-player.component.ts#L182), [session telemetry](https://github.com/grimmory-tools/grimmory/blob/8ddca596b54754cf18792b2f4b089c661f25da50/frontend/src/app/shared/service/audiobook-session.service.ts#L319).

### Minimum replacement and preferred contract

The minimum needed to remove the final app dependency is the existing audiobook checkpoint and its own update timestamp, available independently of which other format was read last. A dedicated read endpoint or an independently populated `audiobookProgress` on standard Book responses would cover this; a new endpoint is not inherently required.

A per-file progress contract would also remove ambiguity for books with multiple formats. If using that design, the following behavior is needed:

- Return independent saved checkpoints for every relevant book file, with `bookId`, `bookFileId`, and format identity matching the downloadable file inventory.
- Include the locator/position, an explicitly documented 0–100 percentage, and the checkpoint's own server update timestamp. Updating another format must not advance that timestamp or hide the record.
- Preserve EPUB CFI and href, converted-ebook/source progress where supported, PDF/comic page position, and audiobook position plus track index. Document whether audio milliseconds are track-relative or global and use the same convention for reads and writes.
- Distinguish an unsaved checkpoint from a valid zero position. Do not turn missing progress into a reset or completed state.
- Apply the authenticated user's library and content restrictions to every returned record.

Acceptance case: save an audiobook checkpoint, save a different EPUB checkpoint on the same book, then fetch progress in both orders. Both checkpoints and their individual timestamps must survive. Repeat with an audiobook-primary book, an EPUB-primary book, multi-track audio, an explicit rewind, and a checkpoint at zero. Phone and watch must resolve the same audio position.

## Live contract evidence

A read-only probe passed 23 checks against the pinned nightly: catalog ID equality between old and new APIs for five libraries, per-library counts and filtering, nested titles, cursor-page continuity where applicable, nested book/author/notebook pagination, and reproduction of the progress gap above. These are server contract checks, not a substitute for building and exercising the migrated applications.

A populated notebook probe created two temporary bookmarks at different CFIs, fetched them through two one-entry pages with a book/type/search filter, verified their IDs and `BOOKMARK` type, and deleted both in cleanup. The mTLS suite passed valid-certificate access and authenticated login, and rejected missing, expired, and untrusted certificates.

Authentication already uses `/api/v1/auth/`, `/api/v1/public-settings`, and `/api/v1/users/me` and requires no route migration. A further nine read-only checks verified the progress omission across detail, batch, and audiobook-filtered browsing, and checked the limits of session history and completion statistics.

## Enve implementation and verification

Both apps now use the replacements above for their active operations. Standalone Wear OS browsing also uses the standard book page API. Obsolete app-only DTOs and unused API wrappers were removed. Catalog pagination, nested metadata, progress percentage units, file selection, and existing cache versions were adapted to the standard contracts.

The only remaining production app-namespace operation is **GET `/api/v1/app/books/{id}/progress`**, called by iOS, Android, and Wear OS for audiobook resume state. Keep that operation available until the independent audio checkpoint and timestamp are exposed through a non-app API. The migration does not claim compatibility with removal of that final read.

Validation against the pinned nightly and the local checkouts:

| Check | Result |
| --- | --- |
| iOS `AllTests`, iPhone Air simulator | Passed: 2,260 tests (2,679 runs including parameterized cases), 40 gated tests skipped, zero failures. |
| iOS nightly provider suite | Passed: seven live tests covering authentication recovery, search, full catalog/resume/delta/cancellation, dual-format downloads and playable streams, collections/ratings, notebook edits, statistics and compatibility tiers. The optional delayed refresh-token gate was skipped. |
| iOS nightly progress round trip | Passed: the Grimmory-only parameterized progress test; zero skips or failures. |
| iOS Hearth refresh UI smoke test | Passed on a clean iPhone Air simulator: discovered additions through standard paginated browsing and retained them after an injected refresh failure. The first attempt on the existing populated simulator encountered stale test state and was cancelled. |
| Shared tvOS target build | Passed. All 78 compiler warnings originate in unchanged `LocalPackages` dependencies; no warnings from changed application sources. |
| Android engine/app/Wear unit suites | Passed: 1,410 tests, one live-gated test skipped, zero failures. |
| Android phone and Wear debug/release builds | Passed, with no compiler warnings in the validation logs. Instrumentation APKs also built. |
| Android live format progress round trips | Passed for EPUB, PDF, comics, FB2, MOBI/AZW3, and audiobook progress; fixture positions restored. |
| Pixel 7a fresh-login UI test | Passed: authenticated, discovered libraries, imported books, and verified the library screen without import issues. Disposable profile and private test configuration removed. |
| Wear OS emulator contract test | Passed: browse, download, and progress flow using the standard browse route and retained audio progress read. |

The old/new home-lane comparison was not an equality pass: the old app API returned empty continue lanes for the lab administrator, while standard filtered browsing returned matching books. The old controller's library-ID handling accounts for that difference. The migrated query uses the intended reading statuses, format facets, descending last-read time, and excludes books without a last-read timestamp.

Build, test, and probe logs are retained in the local verification archive `grimmory-api-2026-11-14`.

## Manual iOS UI audit — 2026-11-14

Reconfirmed the nightly image before creating a fresh iPhone Air simulator and an isolated, non-admin Grimmory account. Signed in through Enve's ordinary onboarding and connection screens. A local recording proxy rejected every retired app route except the documented audiobook progress read. No UI fixture launch arguments were used.

| Workflow exercised in the app | Observed result and server verification |
| --- | --- |
| Library selection, empty library, search, large catalog | Empty state rendered correctly; scoped libraries and search returned the expected books. The 30,265-book library loaded incrementally. Fixed a clipped loaded/total count label. |
| Favorites and Read Later | UI writes reached Grimmory shelves. Fixed views reading the owner store instead of the active profile's saved-books store; both lists then displayed the saved book and survived restart. |
| Magic shelf | Server membership contained two books, but the UI initially showed only the locally cached member. Added standard batch hydration; both members then rendered. |
| Offline shelf and retry | Stopped only the audit proxy. Added a persistent load error and retry control instead of presenting an empty shelf. Restored connectivity and retried successfully. |
| EPUB, AZW3, MOBI, FB2, PDF and CBZ | Opened each format and inspected actual rendered pages. MOBI reopened at its saved paragraph after restart. CBZ reopened on page 2 of 3, matching server page 2 / 50%. Removed unnecessary EPUB metadata probes for non-EPUB files. |
| Chaptered M4B and multi-file MP3 | Playback clocks advanced; pause, skip and chapter selection worked. Verified M4B position 40,000 ms and MP3 track 1 / 15,000 ms, corresponding to 40 seconds globally. |
| Remote rewind | With Enve stopped, moved the test account's server position from 40 seconds to 7 seconds. Enve offered both positions; choosing the server resumed from 7 seconds. The unchanged Hearth value before that choice was not a failed server write. |
| Reader note, rating and completion | Created a note in the reader and saw it in Marginalia and standard notebook results. Four UI stars became server rating 8/10; marking finished produced `READ` and a completion date. |
| Grimmory statistics and appearance | Opened the provider statistics dashboard and inspected light/dark collection, detail and reading screens. Missing fixture covers used placeholders. |

### Server-linked audiobook and ebook

Used the existing server attachment for book **30288**, with primary MP3 file **30292** and alternate EPUB file **30298**. Both Read and Listen appeared in Enve. This was a server association, not a manually invented local link.

The manual sequence saved audio at 22,920 ms, opened the EPUB at Chapter 10 (page 99/235, 41.7%), and verified both writes on Grimmory. Enve's linked-position mapping moved audio to 235,022 ms. After restarting Enve, Listen resumed at 3:55. Subsequent listening advanced the mapped ebook percentage to 44.2%, but reopening the EPUB initially displayed its cover. Enve's linked coordinator had replaced the old precise locator with a percentage-only estimate; the narrated-book restore policy could not use that estimate. The Enve fix preserves an explicit text-progression locator for this fallback. This is distinct from a Grimmory data-loss report.

The EPUB contains SMIL for the prologue and Chapter 1 only, and the MP3 lasts 9:45. Consequently this fixture verifies format discovery, transport and progress handoff, but cannot establish exact sentence alignment throughout the whole book. Estimated progress outside alignment coverage must not be described as an exact passage match.

The fixed local round trip reopened actual text at page 109/235 (46%). Provider writes intentionally remove the local restore marker, so the Grimmory progress decoder also recognizes a stored percentage-only text locator and restores the marker using the server's rounded percentage. With Enve stopped, a separate server-only write set EPUB progress to 65.234%; after relaunch the app fetched 65.2% and opened actual text around page 153/235. This verifies an incoming server checkpoint rather than relying only on the local cached locator.

The same UI sequence independently reproduced the remaining server API gap: standard book detail omitted `audiobookProgress` when the ebook update at `02:29:16Z` was newer, while the retained app progress read returned audio at **22,920 ms**, **3.91802%**, with its own `02:29:15Z` timestamp. The request to Grimmory remains an independent per-file checkpoint read, not automatic audio/text alignment.

Read-aloud reference checkouts were fetched before investigating the restore failure: Silveran Reader `669a56903316fa51bf9c2850bdc89d9bbcac37dc` and Storyteller `2de166daa9eb5b2b120fd639434f856c19cad823`, both already at upstream `main`. Their locator/progression handling informed the distinction between exact anchors and percentage fallback; no source was copied.

### Midnight metadata investigation and rerun

The user identified the incorrect `01 - Midnight` title and missing author during visual review. Both old app detail and standard book detail returned that title with an empty author array for book 30288. The attached EPUB's OPF instead contained `Hunter, Erin - Warriors: The New Prophecy 01 - Midnight` and creator `Hunter, Erin`. The server attachment service reassigns files without merging their source book metadata into the target record; attaching a correctly tagged EPUB therefore does not fix an incomplete audio-primary record.

Corrected only this test book's server title and authors through the existing `PUT /api/v1/books/30288/metadata?replaceMode=REPLACE_WHEN_PROVIDED`: `Midnight`, `Erin Hunter`. No local Enve metadata override was used. A normal library pull-to-refresh then updated both linked entries, Hearth, details and the audiobook player. Screenshots show the corrected title/author and both Read and Listen controls. Hearth's progress refresh alone did not refresh existing catalog metadata; the library refresh did.

Repeated old/new comparisons for books 30288, 30291, 30294 and 25: title, authors, publisher, language, series name/number and narrator matched in all 28 comparisons, including absent fields. This is a bounded parity check, not a claim that missing metadata was populated or every field in every book was compared. An existing metadata API covers this correction; no new Grimmory API is required for the title/author issue.

Final focused validation after the UI fixes: **63 tests passed, zero failures/skips**, covering Grimmory endpoint contracts, catalog consistency, progress transport, linked passage sync and reader restoration under the `AllTests` plan. Build/install/run succeeded with **zero errors and warnings**. Reopened MOBI at page 273/881 after the EPUB-probe guard and visually verified the same saved paragraph. The earlier full-suite results above preceded these additional UI fixes; the 63-test run is the final focused rerun.

Final test result: `test_sim_2026-11-15T02-42-45-039Z_pid45502_775c5062.xcresult`; final build log: `build_run_sim_2026-11-15T02-44-03-391Z_pid45502_e2cda73a.log`, under the local XcodeBuildMCP workspace.

Screenshots, sanitized request paths/statuses and linked-position response evidence are retained in the local verification archive `grimmory-ui-2026-11-14`. This manual audit is iOS-specific. It does not claim Android visual parity, complete author-facet coverage, audiobook bookmark server sync, every notebook edit/delete flow, or whole-book sentence alignment.
