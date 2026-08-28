# Streamed EPUB Reproduction Notes

Date: 2026-08-26

## Scope

Simulator verification of remote, non-downloaded EPUBs from the test providers documented in `CLAUDE.local.md`. Credentials, tokens, and private endpoints are intentionally omitted.

## Environment

- `main` at `ad4b811` before the implementation
- Debug build on the iPhone Air simulator running iOS 26.4
- Default engine selection plus a forced Readium launch using `--reader-engine=readium`

## Results

### STREAM-001: Both reader paths report a spine-item count for streamed Grimmory EPUBs

- Status: Fixed and verified
- Provider: Grimmory
- Engines: Normal Foliate selection and forced Readium
- Reproduction:
  1. Connect the Grimmory test server.
  2. Open an uncached remote reflowable EPUB without downloading it.
  3. Record the total after launching with `--reader-engine=readium`.
  4. Move the exact disposable streamed-book cache aside, relaunch with normal engine selection, and open the same book again.
- Observed: The current test account's modern EPUB opened at `Location 1 of 14` under both paths. The total remained 14 after all 25 streamed resources were cached and background position generation had settled. An earlier public-domain encyclopedia fixture reproduced the same defect at `Location 1 of 26`.
- Expected: The location total should use the same granular position calculation as a downloaded copy instead of approximating the book with one location per reading-order resource.
- Technical observation: `StreamedGrimmoryEpubContainer` creates each `DataResource` without exposing the corresponding `GrimmoryEpubStreamingSession.Entry.size`. The session already knows every entry size, but `Publication.positionsByReadingOrder()` receives resources without an estimated length and produces only one position for each spine resource.
- Resolution: `StreamedGrimmoryEpubContainer` now exposes each known manifest entry size through the Readium `Resource` contract while retaining lazy resource fetching. Unknown or zero sizes remain unavailable rather than being fabricated.
- Verification: Separate cold-cache launches through normal Foliate selection and forced Readium both changed the same publication from `Location 1 of 14` to `Location 1 of 1796`. The focused streamed-resource regression test and the complete simulator test plan passed.

### STREAM-002: Foliate cannot open two older streamed Grimmory fixtures

- Status: Reproduced with two remote EPUBs from the earlier test connection; not universal
- Provider: Grimmory
- Engine: Foliate
- Observed: The earlier fixtures log `Foliate unavailable ... falling back to Readium: Load failed` after streamed loading begins. The current account's modern streamed EPUB opens through normal Foliate selection, so this failure depends on the publication or server response.
- Expected: Foliate should open the streamed EPUB, or the automatic fallback should open it in Readium.
- Fix direction: Add non-sensitive diagnostics around Foliate's streamed resource request failures and validate path decoding, content types, and requested-resource lookup against the Grimmory entry manifest.

### STREAM-003: Foliate fallback does not visibly complete for the failing fixtures

- Status: Reproduced during the STREAM-002 runs
- Observed: After Foliate reports its fallback, the detail screen remains visible and no reader or user-facing error appears during the observed test window.
- Expected: Readium should be presented after a successful fallback. If fallback also fails, the detail screen should show an actionable error.
- Fix direction: Add a regression test for the `.foliate` to `.readium` state transition and ensure reader presentation observes the fallback-ready state.

### STREAM-004: The first Read tap can fail to present a remote EPUB

- Status: Reproduced repeatedly with the current test account
- Observed: The first Read tap starts publication work but leaves the detail screen visible. A second Read tap presents the reader. This occurred under both normal engine selection and forced Readium.
- Expected: One Read tap should present the reader once the publication is ready, and repeated taps should not be required.
- Fix direction: Trace the detail-to-reader presentation state around the asynchronous open task. Add a UI regression test that starts an uncached remote EPUB and asserts that the first tap presents reader chrome.

### AUTH-001: Earlier Grimmory test login rejection is not reproducible

- Status: Superseded by a successful normal login with the current test account
- Observed: An earlier credential set was accepted by a direct endpoint probe but rejected by Enve. The replacement test account authenticated through Enve's standard username/password flow, persisted across relaunch, and imported 77 books.
- Conclusion: The earlier result is not sufficient evidence of an Enve authentication defect. Treat it as a test-account or environment mismatch unless the same current account succeeds directly and fails in Enve.

### ABS-STREAM-001: Remote ABS EPUB fixtures fail before reader presentation

- Status: Reproduced with two non-downloaded test EPUBs
- Observed: Enve displays `Received an invalid response from the server` before either reader engine opens.
- Expected: A supported remote EPUB should stream or download and then open; unsupported server responses should identify the failing operation without exposing its URL or authorization data.
- Fix direction: Capture the sanitized response status and content type at the provider boundary, then verify the asset download endpoint and redirect handling against the current Audiobookshelf test server.

## Controls

- Downloaded EPUBs opened correctly in both engines.
- A downloaded Readium control displayed `496 of 634`.
- Foliate controls displayed `496 of 634` and `12 of 543` for two downloaded books.
- A fixed-layout streamed control displayed `Page 80 of 166` under normal and forced-Readium launches, confirming that its explicit page model is unaffected.
- The current Grimmory connection persisted across a clean relaunch and imported 77 items through the normal login flow.

## Test-environment note

The simulator install initially failed because the host volume was full. Clearing only the disposable SwiftPM cache restored enough space to install the clean build. This was an environment issue, not an Enve product defect.
