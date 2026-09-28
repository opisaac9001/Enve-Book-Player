# Grimmory dual-format regression — September 19, 2026

Status: code complete and focused tests passing. iOS runtime acceptance is open.

## Findings and changes

- The mobile catalog summary omits alternative files. An audio-primary record was mapped only as an audiobook, regardless of resync.
- Resolve format inventories through `/api/v1/books/batch` in groups of 100, including streaming import, full catalog, delta, and recent-book paths. Incomplete inventory responses prevent complete reconciliation.
- Map mixed records to the existing ebook plus linked companion-audiobook representation, independent of server primary order. Select ebook and audio files separately for detail enrichment.
- Use ebook-specific progress when constructing the ebook rather than copying the audiobook percentage.
- Persist corrected media types on record updates, without carrying progress from the previous media type into the corrected record.
- Add both-primary-order mapper coverage and a previously-audio-only persisted-record regression. Existing legacy expectations now include the selected ebook path and no audiobook duration on the ebook.
- Format resolution is import-local and transactional. Cancellation propagates, transient failures cannot persist summary-only identities, and a server without the batch endpoint switches to the legacy catalog rather than downgrading records.
- Media-type correction no longer bypasses timestamp ordering for progress, completion, or locators.
- A per-pair startup migration moves audiobook progress, bookmarks, cached chapters, download files, and inactive download state from the former original ID to the `grimmory-ab-` companion. Completion is recorded only after the failable download and SwiftData moves succeed, preventing later ebook state from being reclassified.

## Lab

Only disposable fixture copies were added. Existing source files were preserved.

- Book 30279: audiobook primary, EPUB alternate; files 30279 and 30280.
- Book 30280: EPUB primary, audiobook alternate in the small audio library; files 30283 and 30284.
- Book 30278: EPUB primary, audiobook alternate in the large books library; files 30278 and 30282.
- The main media mount remains read-only. A lab Compose override grants Grimmory write access only to the new `Enve Dual Format Regression` fixture folders. The Grimmory container was recreated with that override; its database was preserved.
- A malformed generated audio attachment was removed and replaced with a valid remux from the preserved synthetic source.

## Verification

- `enve` / `AllTests` build-for-testing on the iPhone Air simulator succeeded, including the new regressions. Final build reported no warnings or errors.
- Forty-six focused mapper, persistence, recovery, progress/bookmark, and filesystem tests passed with zero failures or skips.
- `git diff --check` and `./scripts/verify-provenance` passed.

## Remaining acceptance

- Run the complete `AllTests` plan.
- Verify Read and Listen for both fixture primary orders, resync of a previously audio-only record, separate progress, and existing downloads/bookmarks when a record's format is corrected.
- Measure full-catalog batch overhead against the large lab library before release.
