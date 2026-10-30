# Hearth catalog refresh

Hearth refreshes progress separately from recent catalog additions. Hearth starts an additions check only on pull-to-refresh, which bypasses freshness. Opening Hearth or returning to it reads the local cache. The existing startup path retains its 15-minute checkpoint per selected library. Full reconciliation keeps its existing cadence. Grimmory discovery uses 50-book pages, stops at an indexed source page, and never falls back to an unbounded legacy catalog request.

`LibraryCatalogCoordinatorTests` covers multi-page additions, cache preservation, freshness, coalescing, cancellation, incomplete pages, and derived companion boundaries. `BookloreCatalogConsistencyTests` exercises the wire requests, empty responses, unsupported endpoints, and individual-record format resolution.

## Simulator fixture

Start the local server in one terminal:

```sh
python3 scripts/hearth-catalog-fixture.py --port 57733
```

Run the UI check from the app root on iPhone Air:

```sh
TEST_RUNNER_ENVE_HEARTH_FIXTURE_URL=http://127.0.0.1:57733 \
xcodebuild -project enve.xcodeproj -scheme enve \
  -testPlan UISmokeTests \
  -only-testing:enveUITests/HearthCatalogRefreshUITests \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -derivedDataPath .build/DerivedData \
  -collect-test-diagnostics never test
```

The fixture uses invented credentials and books. The test connects it through the existing debug source route, adds 130 books, verifies that returning to Hearth makes no additions request, pulls Hearth, and checks for three 50-book page requests with no full-library scan. It then returns a catalog error and checks that the retry notice appears while the books remain visible. Without the fixture environment variable, the test skips. A screenshot is retained in the UI test result.

Use a fresh fixture source for each run: remove the previous source through Settings → Sources, or start the server on a new port. The debug source remains in the simulator after verification. Stop the local fixture after testing. This is deterministic fixture coverage; it does not replace testing against a deployed Grimmory server.

## Library cache loading

`LibraryScreen` loads the local catalog and subscribes to database changes independently of the server library-name refresh. The shared screen previously awaited names from every active connection before loading cached books.

`LibraryCacheLoadingUITests` uses the same fixture to import a book, terminate the app, and block library-name responses on the next launch. It checks that the cached book appears while the request is blocked, remains usable after switching tabs, and survives another cold launch with HTTP 503 responses. The fixture's `/__fixture/libraries` control accepts `ready`, `blocked`, and `failure`; blocked responses are held for at most 90 seconds.

```sh
TEST_RUNNER_ENVE_HEARTH_FIXTURE_URL=http://127.0.0.1:57863 \
xcodebuild -project enve.xcodeproj -scheme enve \
  -testPlan UISmokeTests \
  -only-testing:enveUITests/LibraryCacheLoadingUITests \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -derivedDataPath .build/DerivedData \
  -parallel-testing-enabled NO -collect-test-diagnostics never test
```

Run the fixture with `--port 57863` for this command. This covers the shared loading order using a Grimmory fixture; it does not measure a live Audiobookshelf server.

### Verification — 2026-10-26

- The regression failed against the original app at the cached-book assertion, with a pending library-name request and the same zero-count/loading screen reported on device. An initial simulator accessibility startup timeout required restarting iPhone Air before the test could execute.
- With the independent refresh task, `LibraryCacheLoadingUITests`, `LibraryLayoutUITests`, and `LibraryFilterControlsUITests` passed all six UI tests on iPhone Air, iOS 27.0. The saved screenshot confirms cached books are visible while library-name responses remain blocked.
- `AllTests` passed: 1,662 passed, 36 skipped, zero failed, and no reported runtime warnings. The same destination and DerivedData path above were used with `-testPlan AllTests`, without `-only-testing`.
- Build succeeded with zero errors and no new warnings. Recompilation surfaced the existing retroactive `Sendable` conformance warning at `CloudKitSink.swift:55`; that file is unchanged.

## Verification — 2026-10-20

- Built `enve` on iPhone Air (iOS 27.0): zero compiler errors and warnings.
- `AllTests`: an earlier run passed (1,562 passed, 33 skipped). The final run, including the additional metadata-preservation regression, had 1,561 passed, 33 skipped, and two intermittent failures in unchanged playback tests: `MediaOverlayPlayerSequenceTests.fileOverflowPastItsTimelineSpanDoesNotPublishLaterChapters` and `EbookTTSServiceRateTests.uncommittedRateIsPersistedAfterTheDebounce`.
- A focused rerun of `LibraryCatalogCoordinatorTests`, `BookloreCatalogConsistencyTests`, and those two playback tests passed all 28 tests.
- `HearthCatalogRefreshUITests` passed on iPhone Air: 130 additions appeared after Hearth pull-to-refresh using pages 0–2 of size 50, with no full catalog request. A subsequent HTTP 503 showed the retry notice and retained the books.
- No deployed Grimmory server was used; provider verification used the local HTTP fixture.

The focused rerun used the same `AllTests` command with `test-without-building` and these selections:

```sh
-only-testing:enveTests/LibraryCatalogCoordinatorTests \
-only-testing:enveTests/BookloreCatalogConsistencyTests \
-only-testing:enveTests/MediaOverlayPlayerSequenceTests/fileOverflowPastItsTimelineSpanDoesNotPublishLaterChapters \
-only-testing:enveTests/EbookTTSServiceRateTests/uncommittedRateIsPersistedAfterTheDebounce
```

## Manual-only Hearth refresh follow-up

Removed the additions check on Hearth activation and foregrounding, along with its scene-phase dependency. The screen now reads cached books and observes local changes; only pull-to-refresh requests additions. The source-engine entry point always performs a manual check, while the existing startup freshness and full-reconciliation paths remain unchanged.

The updated iPhone Air UI test passed: leaving Hearth and returning made no additions request; pulling then fetched 130 books through three 50-book pages, and the failure notice preserved cached books. The build had zero compiler errors and warnings. `AllTests` had 1,562 passed, 33 skipped, and the existing intermittent `MediaOverlayPlayerSequenceTests.fileOverflowPastItsTimelineSpanDoesNotPublishLaterChapters` failure. All refresh tests passed. The single playback test passed when rerun separately.

## Playback timing investigation

The original sequence test polled every 25 ms and required observing a 300 ms fragment. Diagnostic subscriptions reproduced the missing fragment publication under full-suite load as well, with playback startup delayed by several seconds. This establishes delayed or missed highlighting updates under load; it does not establish skipped audio. No playback implementation was changed on that evidence.

The sequence regression now records published fragment changes directly, gives the short chapter opening a one-second window, retains the expected clip sequences and the early-advance check, and verifies that every fixture audio file reaches its natural end. The TTS rate regression waits for the persisted value within a five-second deadline rather than assuming the debounced task has run after a fixed 600 ms sleep.

Reference comparison on 2026-10-20 used Silveran Reader `669a569` and Storyteller `ceaff0e73`, both matching their fetched upstream `main`. Their SMIL players advance entries using the current audio file and its playhead, with a 200 ms update loop and file-completion handling. Enve likewise confines playhead-derived fragments to the file currently playing. This comparison did not justify replacing Enve's playback architecture.

A diagnostic three-iteration run of the original tests also crashed the test host in `XCTWaiter`; the interrupted tests are not individual playback failures. Verification of the changes uses separate full-suite invocations.

Two separate final `AllTests` invocations on iPhone Air passed: 1,563 passed, zero failed, and 33 skipped each. The build had zero compiler errors or warnings, and both results reported no runtime warnings.
