# BookOrbit widget compatibility

Verified on 2026-11-20 with an arm64 iPhone Air simulator running iOS 27.0.

## Change

BookOrbit 3.8.0 and 3.9.0 require official-app attestation on individual dashboard widget routes used by Enve. Enve now requests these widgets through authenticated `POST /api/v1/dashboard/widgets/batch`:

- `currently-reading`
- `reading-streak`
- `reading-goal`
- `year-projection`
- `monthly-challenge`
- `highlight-of-the-day`

The batch request contains one widget type and decodes its typed result using the existing provider decoder. Only HTTP 404 or 405 falls back to the individual route for older servers. Authorization, rate-limit, server, decoding, missing-result, and per-widget failures propagate; they do not become successful empty progress snapshots or cached empty results. A successful null highlight remains a valid empty result.

Insights retains the previous affected card values on refresh failure and displays a retry card. Features absent from older servers remain optional. The primary activity snapshot query, progress writes, authentication, streaming, and downloads are unchanged.

Upstream contracts reviewed: [dashboard routes](https://github.com/bookorbit/bookorbit/blob/v3.9.0/server/src/modules/dashboard/dashboard.controller.ts), [batch loader and per-widget failures](https://github.com/bookorbit/bookorbit/blob/v3.9.0/server/src/modules/dashboard/dashboard-widget.service.ts), and [attestation enforcement](https://github.com/bookorbit/bookorbit/blob/v3.9.0/server/src/modules/app-attest/app-attest.service.ts).

## Server verification

Updated only the dedicated lab BookOrbit service from 3.6.0 to the latest release, 3.9.0. Backed up its PostgreSQL database, app data, Compose/environment files, and prior image identity before recreation. Preserved database and media volumes and updated the BookOrbit image inventory entry. The new image digest is `sha256:79cd9c66c990a82944514e3e82d5be5987f21eda96cb37a378ed1484043716fc`.

The container became healthy. `bin/lab doctor` and `bin/lab verify-ecosystem` both exited successfully. Authenticated live probes confirmed that all six individual GET routes return HTTP 403 with `APP_ATTEST_REQUIRED`, while their batch replacements return HTTP 200 with `failed: false`.

## Native verification

- Baseline build passed without compiler errors or warnings.
- `AllTests`: 2,420 tests passed, 40 opt-in tests skipped, zero failures and zero runtime warnings. Parameterized cases accounted for 2,879 passing executions.
- `BookOrbitWidgetTests` covers all six requests, authentication headers and payloads, 404/405 compatibility, 403/429/500 errors, malformed/missing/failed batch results, retries without empty cache poisoning, nullable highlights, and retained Insights cards with visible error state.
- Updated the EPUB position fixture to the batch response; the exact CFI survives currently-reading mapping and upload. Existing legacy progress compatibility fixtures continue exercising the older individual-route fallback.
- The opt-in `ProviderLiveSyncTests` BookOrbit run passed against 3.9.0: authentication; four libraries and 30,274 books; representative details; six widgets and eight currently-reading entries; collection creation/membership/deletion; ebook download; 42%, finished, and reset ebook progress; HTTP 206 streaming and byte-range seeking; 23-second and reset audiobook progress. The harness restores the original progress and removes its temporary collection.
- Launched the installed app and navigated through Journal → Stats Hub → BookOrbit. Confirmed populated streak, monthly challenge, projection, and highlight cards. Error retention/retry behavior was tested at the model/provider boundary; no live server faults were injected for that UI state.

Older-server compatibility was tested with HTTP fixtures, not by downgrading the upgraded lab server. Existing unrelated sources in the simulator reported connection failures; the BookOrbit screen loaded successfully.

## Commands and evidence

Build and full test commands used scheme `enve`, test plan `AllTests`, `-parallel-testing-enabled NO`, the iPhone Air simulator destination, and the existing `DerivedData-main` cache. The live run used `build-for-testing`, then `test-without-building -only-testing:enveTests/ProviderLiveSyncTests`, with `ENVE_LAB_SERVICE=BookOrbit` and the ignored lab document supplied through the generated test configuration.

Artifacts under the local Enve build directory:

- `BookOrbitWidgets-Final-20261120.xcresult`
- `BookOrbit-3.9-Live-20261120.xcresult`
- `BookOrbitWidgets-20261120/` — screenshots and sanitized verification logs

`git diff --check` and `./scripts/verify-provenance` passed. No commit, push, or release was performed.


## Other restricted routes: alternative API audit

Read-only follow-up on 2026-11-20 against the upgraded 3.9.0 lab. Reviewed upstream `main` at `0d1cb5d81cb528736412297b8d10e4c509f37889` and release `v3.9.0` at `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`. The notebook, journal, statistics, year-review, preferences, smart-scope, and achievement modules were unchanged between these revisions. All routes below are relative to `/api/v1/`. No app changes or server policy changes were made for this audit.

| Restricted route or feature | Available alternative | Limits and verification |
| --- | --- | --- |
| `smart-scopes/:id/books` | `POST smart-scopes/:id/books/query` with `{"sort":[],"pagination":{"page":0,"size":50}}` | Source confirms the GET delegates to the same query service. The lab has no saved scopes, so successful book results were not exercised. A nonexistent ID returns 403 on GET and normal 404 on POST, confirming the query passes attestation enforcement. |
| `user-statistics/activity-overview`, `activity-calendar/:year`, `activity-days/:day`, and four `activity-details/*` routes | `summary`, `daily-reading`, `reading-heatmap`, `session-timeline`, `completion-latency`, `genre-reading-time`, `reading-pace`, `session-archetypes` under `user-statistics/` | All seven restricted routes returned 403 `APP_ATTEST_REQUIRED`; all eight alternatives returned 200. Related data remains available, but response shapes, filters, and aggregation semantics differ. They are ingredients for Enve-owned views, not interchangeable DTOs. |
| `mobile/year-review/:year` | `reading-history/summary?year=…`, paginated `reading-history`, statistics, annotations, and book metadata | Blocked route 403; history list and annual summary 200. Enough for a custom annual summary; not the exact official generated response. Session timeline exposes UTC ISO weeks, capped at 3,000 sessions per week without pagination, whereas official year review uses its own timezone-aware accumulation. Any reconstruction needs timezone boundaries, duplicate handling for sessions crossing weeks, and completeness handling. |
| `notebook/entries`, `overview`, `books`, `review`, `on-this-day` | `annotations`, `annotations/overview`, `annotations/books`; per-book `books/:id/bookmarks`; book detail `personalNote`, `personalNoteUpdatedAt`, and `rating` for reviews | All five notebook routes 403. Annotation routes, representative bookmarks, and book details 200. Source confirms notebook reviews originate in the same personal-note table. Can rebuild the non-journal portions and Enve-owned review/anniversary selections; cannot reproduce the complete mixed notebook without all journal entries. |
| `books/:bookId/journal` | `reading-history/:attemptId/marks` exposes a limited journal preview | Journal 403; marks 200. Source hard-caps the preview at two entries within the finished read's date interval, with total count and no journal pagination. Lab history had 38 reads and none with journals, so populated journal payloads were source-verified only. Not a full journal read/write workaround. |
| `user-preferences/annotation-colors` | Existing annotations still include their color values | Preferences 403. This preference stores custom color names; no alternate route for those names was found. Standard color values and annotation notes remain available. |
| Achievement celebration claim/acknowledgment | `achievements`, `achievements/hints` | Both read routes 200. Enve could display achievements or track its own celebrations; it cannot synchronize the official celebration queue through these reads. |
| Resumable `uploads` session creation | Ordinary multipart `POST libraries/:id/upload` | Source-confirmed alternative requiring normal upload permission and respecting configured upload-size limits. Does not provide resumable-session behavior. No upload was performed in this read-only audit. |
| Watch download-ticket creation | Ordinary book-file downloads and an independently implemented device transfer | File-download availability was verified during the prior native live run. Does not reproduce official Watch tickets or media overlays. |
| Mobile AI, story edits, story-guide content/fixes, captioned speech | No equivalent official payload route found | Non-mobile story-guide GET returns build status, not guide content. Ordinary speech synthesis does not provide the captioned response. These are separate feature implementations, not drop-in API replacements. |

`notebook/trash` returned 200, but its source restricts results to deleted highlights/journal entries; it cannot retrieve active journals. No deleted entries were restored or manipulated. No journal contents, tokens, credentials, or private server addresses are recorded here.

Primary source references: [smart-scope delegation](https://github.com/bookorbit/bookorbit/blob/v3.9.0/server/src/modules/smart-scope/smart-scope.service.ts), [statistics routes](https://github.com/bookorbit/bookorbit/blob/v3.9.0/server/src/modules/user-statistics/user-statistics.controller.ts), [notebook composition](https://github.com/bookorbit/bookorbit/blob/v3.9.0/server/src/modules/notebook/notebook.service.ts), [journal preview limit](https://github.com/bookorbit/bookorbit/blob/v3.9.0/server/src/modules/reading-history/reading-history.service.ts), [journal preview query](https://github.com/bookorbit/bookorbit/blob/v3.9.0/server/src/modules/reading-history/reading-history.repository.ts), [annual review aggregation](https://github.com/bookorbit/bookorbit/blob/v3.9.0/server/src/modules/year-review/year-review.service.ts), [ordinary uploads](https://github.com/bookorbit/bookorbit/blob/v3.9.0/server/src/modules/upload/upload.controller.ts).
