# Profile database reuse — October 11, 2026

## Change

The profile coordinator retains each visited profile's `BookStoreManager`, keyed by profile ID, and injects it when recreating a retired `ProfileSession`. Initial-session storage is registered in the same cache. Successful profile removal evicts its database. Playback, network, credentials, sync and all other session services still receive the existing retirement and recreation behavior. No schema, migration, authentication, signing or release configuration changed.

The coordinator's session factory now accepts an optional existing database. `ProfileSession` accepts that database rather than reopening it. The new ownership test confirms that a retired session releases, revisiting a profile reuses its database, databases differ between profiles, and removing a profile releases the cached manager.

## Verification

- Before: 40 switches grew numeric open descriptors from 33 to 113 on the 17.5 simulator.
- Initial isolated check after the change: **200 switches, 31 → 31**, book/progress isolation assertions passed; zero errors/warnings. Result: `test_sim_2026-10-11T22-27-25-678Z_pid36703_29304c7a.xcresult`.
- Focused ProfileSession suite: **13 passed, zero failures/skips**, including 200 switches and cache eviction. It emitted two weak-variable mutability warnings in the new test; both were corrected to weak constants. This intermediate run is not the final warning-free build. Result: `test_sim_2026-10-11T22-28-51-357Z_pid36703_180a5d7e.xcresult`.

Final full suites and native profile UI checks on 17.5 and 27 completed; results follow. Default AllTests skips the opt-in descriptor soak; the soak is run separately with `ENVE_PROFILE_SOAK=1` so unrelated concurrent tests do not distort the process-wide descriptor measurement.

## Limits

Simulator results do not establish behavior on the reporter's exact physical iPadOS 17.7.11 device or resolve the separate 17.0 persistence issue. Reusing a bounded set of databases fixes the measured reopening-related descriptor accumulation; it is not proof that every app resource leak is absent. Earlier general-app accessibility and OPDS download-label findings are outside this change. No commit or push was performed.

- Final iPadOS 17.5 AllTests: **1,279 passed, zero failed, 23 skipped**, zero reported compiler errors/warnings. Result: `test_sim_2026-10-11T22-29-40-539Z_pid36703_19e1070f.xcresult`. Skips are opt-in lab checks, including the separately executed descriptor soak.

- Final iOS 27 AllTests: **1,279 passed, zero failed, 23 skipped**, zero reported compiler errors/warnings. Result: `test_sim_2026-10-11T22-34-46-305Z_pid36703_215f88c9.xcresult`.
- iOS 27 focused ProfileSession suite including the 200-switch soak: **13 passed, zero failures/skips**, zero compiler errors/warnings. Descriptors were 71 → 31 during the shared suite; other tests released resources in that process. It passed the unchanged bounded-growth assertion and profile-isolation checks. Result: `test_sim_2026-10-11T22-36-02-710Z_pid36703_bc518601.xcresult`.
- Native switch/background/full restart/removal workflow passed on 17.5 and 27: `test_sim_2026-10-11T22-31-44-158Z_pid36703_fd77425b.xcresult` (compatibility case passed; second case failed as below) and `test_sim_2026-10-11T22-36-20-370Z_pid36703_c4551ce4.xcresult`.
- The extra 17.5 server-sync workflow initially failed because its hardcoded 93%-width tap missed the switch. Changing the test to the switch's native tap action preserved all assertions and passed setup, sync opt-in/off, switching, empty-library isolation, restart and removal. Result: `test_sim_2026-10-11T22-45-51-673Z_pid36703_371dad3f.xcresult`, one passed, zero failed/skipped, zero compiler errors/warnings. The interrupted test's exact owned profile was removed through native UI before rerunning; a temporary cleanup-only test was then removed from source.

The measured profile-switch descriptor growth is resolved in these checks. The independent general-app issues remain outside this fix. The only additional retained harness change is the native switch tap in `ProfileDeviceUITests`.
