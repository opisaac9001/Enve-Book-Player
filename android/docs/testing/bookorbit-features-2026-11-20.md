# BookOrbit feature verification — 2026-11-20

The lab server was upgraded before testing to the latest stable BookOrbit release, **3.9.0** (release commit `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`). Tests used a disposable non-administrator account limited to a dedicated library. Server authentication and attestation settings were preserved.

## Coverage

- Durable ratings and explicit reading status: persisted queue, latest edit wins, retry/replay, server readback, account isolation, and protection from stale refreshes.
- Saved smart scopes: server list, search, empty results, separate pages, retry behavior, and opening details.
- Adaptive browsing: compact navigation and wide list/detail panes; scope search remains after closing details.
- Book Drop: real multipart uploads, access permissions, actual library/folder destinations, fetched metadata application, title editing with author preservation, partial approval results, and discard.
- Highlights: server-side notes-only filter and separate pages; filtering preserves the selected book and search.

## Platforms and checks

- iPhone Air simulator, iOS 27.0: native live provider tests and UI checks for scopes, search, rating/status, approval, notes filtering, and confirmed discard. The server returned 404 for the discarded fixture afterward.
- iPad Pro 13-inch (M4) simulator: XCTest verified library and scope detail panes, simultaneous list access, and retained search.
- Pixel 7a, Android 17: native live tests and Compose UI tests in compact and expanded layouts. Expanded layout used a temporary density override, restored afterward. A temporary USB reverse proxy connected the physical phone to the real lab server.
- Final Apple `AllTests`: 2,504 test cases, 2,462 passed, 42 skipped, zero failures and zero runtime warnings. Parameterized tests produced 2,921 successful executions. The opt-in native live tests were also run separately against the server and passed, including metadata preservation.
- Android unit tests: 1,934 tests, zero failures, one existing skip. Debug and release builds passed.
- Android connected regression tests: 75 passed across Room migrations, cached books, credential isolation, personal stores, profile lifetime, and pending sync recovery.
- tvOS shared target build passed. The initial build emitted existing warnings from unchanged vendored libsmb2; the final incremental build emitted no warnings.

Uploads were exercised through the production native upload APIs. The operating-system document picker itself was not automated. The Apple phone checks used a simulator, not a physical iPhone. Android expanded-layout checks used the Pixel, not a physical tablet.

Live tests are opt-in. Credentials and fixture configuration stay outside the repositories. `BookOrbitFeatureLiveTests` uses `ENVE_BOOKORBIT_FEATURE_CONFIG`; its separate `ENVE_BOOKORBIT_UI_ACTION` prepares, verifies, or removes a temporary simulator profile. `BookOrbitFeaturesUITests` uses `ENVE_BOOKORBIT_FEATURE_UI` for wide-layout checks or `ENVE_BOOKORBIT_COMPACT_UI` plus `ENVE_BOOKORBIT_DISCARD_ID` for notes/discard checks. Android live tests read `files/bookorbit-features-live-test.json` from the debug application's private sandbox. Use only disposable fixture accounts and uploads.
