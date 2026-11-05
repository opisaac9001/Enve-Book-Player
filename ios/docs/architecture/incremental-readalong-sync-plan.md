# Incremental read along and linked book sync implementation plan

Status: proposed implementation contract, October 30, 2026. Scope: Enve Book Player iOS. The deployment target remains iOS 17.0.

Incremental alignment will supply one reusable passage mapping for switching between reading and listening, following narration in the reader, and saving corresponding positions. A prepared passage becomes usable before full-book processing or narrated EPUB export finishes. Existing completed read-aloud books, progress records, pairings and calibration remain usable throughout the change.

## Product contract

- Listening then opening the linked ebook resumes at a confidently matched passage when coverage exists.
- Reading then choosing Listen from here seeks to the corresponding sentence when coverage exists. A word boundary is used only when qualified word timings exist.
- A downloaded, unprepared pair can prepare the current passage first, then a bounded distance ahead. Switching and read-along consume the same saved results.
- Cached mappings work offline, including on iOS 17, without a speech permission request or model download.
- An unprepared or ambiguous passage remains distinguishable from a matched passage. Failed analysis does not seek, overwrite a saved position, or interrupt ordinary audiobook playback.
- Existing approximate linked-book sync remains available outside aligned coverage. It is never presented as sentence-accurate.

The first implementation supports local EPUB and downloaded audio through existing download/provider capabilities. Remote excerpt extraction before a download completes, synchronizing alignment caches between devices, Android implementation, new model dependencies and new background entitlements are separate work. Existing provider progress synchronization remains in scope.

## Current integration points

| Owner | Existing behavior | Planned responsibility |
| --- | --- | --- |
| `StoryAlignService` | Selects QuartzNet or Apple Speech, downloads inputs, runs conversion, and registers `accepted.epub` after export | Keep full-book conversion and accepted-output replacement; expose reusable preparation without requiring export |
| Local `StoryAlignCore` CTC implementation | Analyzes 38-second windows with eight-second overlap; accumulates sentence candidates; checks whole-book quality before export | Reuse window analysis, original sentence identities and acoustic checks; expose finalized passage results incrementally |
| `AudiobookTranscriptionService` | iOS 26 window transcription and transcript generation | Supply timestamped Apple Speech results through an availability-isolated boundary; share transcription ownership and avoid duplicate analysis |
| `LinkedBookQuickSyncService` | Samples eleven audio locations to calibrate progress | Preserve existing calibration; use verified local mappings when present and avoid repeating work |
| `LinkedBookPassageService` | Finds a unique passage from a 24-second excerpt on iOS 26 | Route passage lookup through the shared mapping/preparation path, adding QuartzNet support where available |
| `LinkedBookProgressCoordinator` | Maps percentages through anchors; propagates paired positions; clears the ebook locator on estimated audio updates | Prefer precise locators inside mapped coverage and preserve original observation time and existing conflict rules |
| `MediaOverlayTimeline` and reader controller | Resolve embedded SMIL fragments and audio times, apply decorations and follow pages | Reuse resolution semantics while adding coverage-aware mappings for ordinary EPUBs |
| `ProfileSession` | Captures profile stores, services and lifecycle | Own preparation state and passage mappings; retire outgoing work and reject late results |

The full-book CTC API currently starts at audio time zero. Its probe accepts an arbitrary short excerpt and returns sentence ranges. Production incremental processing must retain a prepared index/model rather than repeatedly invoking the diagnostic probe and rebuilding its session.

## Compatibility matrix

| Capability | iOS 17 through 25 | iOS 26 and later |
| --- | --- | --- |
| Pair books, approximate calibration, ordinary reading/listening | Existing behavior | Existing behavior |
| Use valid saved passage mappings in either direction | Available | Available |
| Play existing EPUB media overlays | Existing behavior | Existing behavior |
| Generate English alignment with QuartzNet | Available when the native dependency, model, media and resources are usable | Same capability checks |
| Generate alignment with `SpeechAnalyzer` and `SpeechTranscriber` | Unavailable; never initialize or reference their runtime types through the common path | Requires supported hardware, locale, permission and installed/downloadable language assets |
| Follow prepared sentence timings | Available | Available |
| Follow prepared word timings | Available if that mapping contains qualified word ranges | Same rule; OS version alone does not determine granularity |
| Prepare in foreground while listening | Supported subject to audio, memory and thermal qualification | Same requirement |
| Prepare after backgrounding or locking | Baseline pauses new inference and saves work; no promise of continued generation | User-initiated continued-processing task may run if accepted; queued, rejected, cancelled or expired tasks pause safely |
| Background listening and saving paired positions | Consume cached coverage during legitimate audio playback; save at existing lifecycle/progress events | Same behavior, with optional accepted continued processing |
| Non-English book with no usable generation engine | Use existing mappings/SMIL and approximate sync; explain why new preparation is unavailable | Apple Speech only when the specific device and narration locale support it; otherwise the same fallback |

QuartzNet currently has an English model, roughly 77 MB on first download, and excludes Mac Catalyst. This does not make every iOS 17 device equally fast. Verify real session creation, memory and sustained performance on the oldest supported test hardware. A failed accelerated session may fall back to the existing CPU implementation; CPU background execution still requires separate qualification.

## Shared passage data

Add a focused, profile-owned passage store under `Services/StoryAlign`. Use its typed API from sync and reader consumers; do not add mapping state to `AppState`, `SyncCoordinator` or `StorageService`. Introduce only the engine boundary actually shared by QuartzNet and Apple Speech, using plain Swift values that load on iOS 17.

Each mapping set identifies the ebook and audiobook stable IDs, connection/media ownership, exact media revisions, schema version, text segmentation version and timing coordinate system. Cache identity must distinguish different EPUBs, recordings, track order and audio replacements even when titles and durations match. Duration similarity alone cannot establish recording identity.

Distinguish the reading revision actually opened by the reader from the provider's transport revision. New incremental preparation uses the ordinary original EPUB. Existing `accepted.epub` books keep their own revision and saved locators. When reading and transport revisions differ, translate href/text ranges only through a verified relationship using the existing location bridge; otherwise retain a supported percentage fallback. Replacing an accepted EPUB creates a new reading revision. Never attach its generated fragment IDs directly to the provider EPUB.

Each accepted passage contains:

- Original EPUB href and a validated text range/locator, with original text plus enough surrounding context to resolve repeated text. Keep a durable original sentence identity and explicit Unicode offset convention.
- Source audio track identity and start/end times in the player's presentation seconds, plus conversion to the complete audiobook timeline. These times do not change when playback speed changes.
- Granularity, engine/model/algorithm provenance, acoustic/text match evidence and finalized status. Engine scores are not interchangeable calibrated probabilities.
- Explicit coverage and gaps. Attempting a window is different from establishing a usable mapping over every second of that window.

Keep a reversible relationship between normalized matching text and the original XHTML text nodes, including punctuation, entities, inline elements and Unicode offsets. Normalized token offsets alone are not valid EPUB locators. Validate locator round trips after font/layout changes without rewriting the original publication.

Define and verify the transformation from decoded sample timestamps to the player's presentation timeline for each format path, including track origins and encoder priming/delay where applicable. Record that timing convention with the mapping version; a verified zero offset is valid. Check boundaries near the beginning and end of long tracks. Nonuniform seek drift cannot be corrected with a single arbitrary offset; withhold that path until its seeking is accurate.

Persist complete updates atomically with versioned manifests and independently resumable window results. A cancelled write retains the previous readable version. Keep acoustic checkpoints separate from ebook-specific matches so compatible audio analysis can be reused after a text change without reusing stale locators.

Reuse identity already verified by immutable local download/import manifests where available. Compute missing content digests once and persist their association with the media revision. Never trust an old mapping solely because a filename/mtime matches, and never rescan the entire audiobook on each playback tick or window. Ordinary playback can continue while identity is established; cached mappings stay withheld until their identity is verified.

An immutable manifest identity or verified content digest establishes strong identity. Fast file/provider revision checks may revalidate its association, but cannot establish strong identity on their own. Recheck on opening, media replacement, download repair and import; replacement cancels in-flight identity work for the old revision. Hashing runs outside the playback path. First resume after an upgrade with no strong identity is measured separately from a validated cached resume.

## Position resolution and sync

Resolve positions by the evidence covering the requested passage: valid existing SMIL or accepted alignment for that exact media, validated user anchors for their applicable area, existing calibration/chapter landmarks, then proportional estimates. Conflicting high-quality mappings require validation or reacquisition. A single new anchor must not displace all useful calibration across the book.

Do not pass sparse incremental mappings directly into the current nearest-clip behavior. `MediaOverlayTimeline.clipIndex(atAudioTime:)` can choose a neighboring clip in a gap, and its duration/progression assumptions suit a completed overlay. Incremental queries must return matched, approximate, unprepared, ambiguous or unavailable explicitly and use the full source-audio duration, not just the prepared clips.

### Listening to reading

Capture the actual playhead and observation time. Within accepted coverage, resolve the corresponding original EPUB locator, save it through the existing progress APIs, and open there when requested. Outside coverage, prepare around the current playhead. After processing, resolve the latest playhead again before applying a result so playback elapsed during preparation does not produce a stale jump.

A pending or failed lookup never changes the existing precise position. If a newer listening observation is actually applied to the linked ebook outside aligned coverage, replace its older locator with an explicitly estimated, percentage-only position. Do not retain a stale precise locator alongside that newer estimate. A failed explicit handoff applies neither update. Test these three branches independently.

### Reading to listening

Resolve the visible or selected original EPUB range. If it is mapped, seek once using the matching track/time through the injected playback controller. A sentence-level handoff starts at the sentence boundary to preserve context. Unsupported selected text such as an unspoken heading or footnote must not silently seek to an unrelated passage.

For uncovered text, use existing calibration/chapter information to estimate an audio region, analyze it, and expand the search only while the request remains current. Begin with a 30-second on-demand search budget; cancellation is always available and longer preparation is explicit. If no confident match is found, keep playback and both saved positions unchanged and offer the existing approximate handoff as a separate choice.

### Event authority and conflicts

Preparation, cache import, index rebuild and mapping-quality improvements are not reading activity. Derived paired updates retain the source observation time and origin so they cannot echo back as new user activity. Preserve current throttling, backward-progress protection, completion/reset semantics, and provider conflict handling. A newer reading position cannot be overwritten by analysis of an older listening event.

Use existing provider/sink contracts and `EpubLocationBridge` for transport conversion. Original EPUB locations are authoritative; generated spans from a rewritten EPUB cannot be sent as if they existed in the original. Providers that only support percentages retain that limitation. Device-to-device progress sync does not imply that the receiving device has the same local alignment cache; it can resolve a supported locator or prepare its own mapping.

## Incremental preparation

Maintain one active analysis owner per captured profile/book pair, coordinated with transcript generation and full-book conversion. Requests for overlapping work coalesce. Preparation runs off the main actor; the focused observable coordinator remains on the main actor. Use existing per-book serialization for related commits and avoid holding a queue across a dependency that needs that same queue.

Serialize mapping commits with one role-ordered pair key containing the captured profile and ebook/audiobook identities. Release that queue before issuing each book's progress write through its existing book queue. Never nest two book queues or await a book queue while holding the pair queue. Progress writes recheck observation time, media revision and pair generation so an unlink or newer event invalidates queued stale work.

Request order is an explicit user handoff, the current playback passage, then look-ahead work. A seek changes the request generation, cancels stale queued work and prioritizes the destination. A completed in-flight native inference may finish, but cannot publish an obsolete navigation event. Pause retains completed results; discard removes only that pair's preparatory data.

Start with the existing 38-second CTC windows and eight-second overlap. Preserve original audio bytes and decode only the required window, with at most one decoded window ahead. Compare 10-, 20- and 38-second startup excerpts on a labeled corpus before choosing a smaller default. Keep a 120-second look-ahead target and 30 seconds behind as initial tuning values, measured in audio time and adjusted for playback speed and measured throughput. Request replenishment before the buffer is nearly exhausted.

Use neighboring context to finalize sentence boundaries at window seams. Repeated passages require a clear distinction from competing locations and consistency with validated local context. Estimated book progress is a search hint, never sufficient proof. Widen ambiguous excerpts, allow later windows to reacquire after skipped/added narration, and withhold unsupported sentences. Whole-book 70% coverage remains an export gate; local acceptance uses passage-specific evidence rather than weakening that gate.

Retain local results between launches. At a covered resume point, load the mapping before warming a model. Reuse a model/text index within an active preparation session and release them on retirement or memory pressure. Use bounded disk caches for large acoustic tensors and an explicit storage-cleanup policy that preserves user positions and accepted EPUBs.

Begin with a 512 MiB per-profile acoustic checkpoint limit, evicting least-recently-used unpinned windows first. Active windows and atomic writes are pinned; if no space can be reclaimed, pause new work and report storage pressure. Mapping data is separate from evictable acoustic work and is retained until explicit cleanup, unlink or invalidation. Include it in the existing storage accounting and cleanup UI.

## Reader and playback behavior

The original audiobook remains the transport owner. The reader observes its source timeline and applies decorations to original EPUB ranges; enabling read-along does not start a second player, replace the book record or restart narration. Keep stable IDs, bookmarks, history and existing locators.

When prepared coverage runs out, clear unsupported highlights and pause following while audio continues. Reacquire automatically only if following is still requested. Opening, closing or scrolling the reader must not itself become an instruction to move audio. Manual browsing pauses following; show a clear Resume following control instead of forcing the reader back after a fixed timer. Listen from here is the explicit reverse-direction action.

Reuse existing Hearth components, accessibility and reader appearance. Distinguish Reading position, Listening position and the mapped counterpart in state; do not collapse independent positions merely because a pair exists. Save paired positions during actual listening even when the reader is closed, subject to the existing user sync settings. Flush locally on pause, interruption and lifecycle transitions without waiting for a server.

Sentence highlighting is the first release boundary. Add word highlighting after preserving Apple's timing attributes and mapping recognized tokens back to original EPUB text, or after exposing/qualifying CTC character-to-word boundaries. Never display recognized transcript text as a replacement for printed text, or infer equal word durations and label them precise. Word mode is gated by each mapping's validated granularity, on every OS.

## Availability and execution gates

Keep the app and test-host minimum at iOS 17.0 and audit transitive native framework slices and embedded minimum OS metadata. Building with a recent SDK and a 17.0 deployment target does not replace running on 17.0.

Availability checks apply at construction and use sites. Mark newer implementation types/functions with `@available(iOS 26.0, *)`; dispatch through `if #available` and preserve existing `#if os(iOS)` and Catalyst exclusions. Shared stored properties, default arguments, globals, static initializers, view bodies and persisted models must not eagerly construct newer Speech/BackgroundTasks types. Persist engine names and plain mapping values, never framework objects.

Expose capability results with actionable reasons: unsupported system/hardware/language, missing media, model download required, permission denied, low storage, temporarily busy, paused for power/temperature, or background execution unavailable. Recheck after permission, model, media or environment changes. A saved Apple Speech preference on iOS 17 is not executable; preserve saved data and choose the available English engine or explain the limitation without starting an impossible job.

Changing engines creates a new preparation run with its own checkpoint identity; it never relabels Apple results as QuartzNet work or vice versa. Already validated plain passage mappings remain readable regardless of which engine generated them.

Use a per-profile feature rollout gate in the focused feature owner, independent of the capability result. Disable generation independently from cached playback/sync so a rollout issue does not strand prepared books. Do not offer unsupported method choices, and do not hide cached functionality because permission was revoked or its generating engine is unavailable.

### Background and resource policy

On iOS 17 through 25, pause new analysis on background/lock and checkpoint completed windows. Existing audio playback continues. Use a bounded UIKit background task only to finish saving state, handle expiration, and end it promptly. Do not request Apple Speech permission, fabricate silent audio, or start a model solely to keep the process alive. Relaunch/foreground resumes from saved work.

On iOS 26 and later, keep long preparation user-initiated. Dispatch through the existing continued-processing integration with the captured profile/job identity. A queued request is not permission to run in the background before the system grants execution. Handle submission failure, task cancellation, expiration and an outgoing profile by checkpointing and pausing. Do not add background GPU entitlements; qualify the existing execution providers under actual background conditions and pause when required resources are unavailable.

Automatic look-ahead runs while foregrounded and read-along or a handoff needs it. Low Power Mode pauses speculative preparation; already cached playback and switching remain available. Start thermal pacing conservatively, pause automatic inference at serious/critical pressure and resume after cooling. Explicit preparation cannot override system resource restrictions. Tune only against sustained device evidence; avoid rebuilding the model between adjacent windows.

An explicit handoff search may run in Low Power Mode only in the foreground within the on-demand budget; it does not restart speculative look-ahead. Serious or critical thermal pressure pauses all new inference, including explicit searches, until cooling. Publish already saved mappings immediately in either state. Measure this policy on physical hardware before relaxing it.

Profile switching captures the outgoing stores, stops publication, cancels and joins tasks, then retires resources. Late callbacks may only finish safe writes in their original scope and cannot affect the incoming profile. Existing family/profile permission policy still applies. Mutable mappings and progress remain private to the owning profile even if immutable model assets are shared.

## Migration and preservation

- Read existing pairing, calibration and completed-output formats without destructive migration. Old percentage anchors remain approximate; they do not become timed passages automatically.
- Add the passage store lazily and namespace it by profile and media identity. An interrupted schema upgrade leaves the old readable version and can retry.
- Resolve existing SMIL to original publication locations only where that relationship is verified. Sparse generated sentence IDs and different EPUB versions must never be renumbered or conflated.
- Replacing one audio track or the EPUB invalidates affected mappings. Model/algorithm changes invalidate only incompatible caches. Never delete another profile's data or the accepted narrated EPUB while rebuilding.
- Unlinking a pair cancels its job and removes its mapping association without deleting either book or unrelated annotations/progress. Removing downloads preserves user progress; unavailable media simply prevents new preparation until restored.
- Preserve the full-book atomic replacement and quality checks. Export is optional for fast read-along and remains a separate explicit action.

## Implementation sequence

Each milestone includes source review, focused regression coverage and runtime verification before the next milestone builds on it. Keep work on `main` and do not commit, push or publish as part of planning.

Keep new state in `PassageAlignmentStore` and new preparation orchestration in `PassageAlignmentService` under `Services/StoryAlign`. Both are owned by the captured `ProfileSession`; background work must not resolve mutable stores through owner-only `.shared` access. Existing engine types retain their names. Use a small shared engine contract only for the two implementations that need it.

Expected existing integration files are `StoryAlignService`, `AudiobookTranscriptionService`, the linked-book services listed above, `ReaderInitialLocationResolver`, `ReaderReadAloudController`, `ProfileSession`, and `EnveApp` for lifecycle/task routing. Presentation changes belong in the existing passage sheet, ebook/audiobook matching screen, read-aloud tray and StoryAlign settings as needed. Audit these actual call sites before implementation; avoid unrelated player/provider rewrites. Protected authentication/network files are outside this feature's scope.

| Milestone | Implementation | Exit condition |
| --- | --- | --- |
| 0 Baseline and capability contract | Record build/test baseline, fixed tuning/held-out corpus, device inventory, binary compatibility, existing engine/lifecycle gates and model license status | A reproducible iOS 17 launch/build/test path; freeze accuracy, abstention and startup thresholds before milestone 2 |
| 1 Shared mapping and coverage | Add versioned profile store, identity, atomic persistence, range lookup and migration; adapt valid existing overlays | Bidirectional sentence lookup survives restart, gaps, replacements, cancellation and profile changes |
| 2 Incremental QuartzNet | Reuse CTC internals with persistent session/index, out-of-order window scheduling, local acceptance and seam finalization | A current passage is usable without full-book export on exact iOS 17; repeated/incorrect excerpts do not navigate |
| 3 Precise linked sync | Update Find Passage, Quick Sync reuse, reader initial location and linked progress to use coverage-aware locators and source timestamps | Read-to-audio and audio-to-read round trips pass; newer user progress and existing remote conflict rules are preserved |
| 4 Sentence read along | Attach mappings to existing transport, reader decoration, look-ahead, gap handling and explicit following controls | Continuous reading/listening works across chapters, seeks and buffer exhaustion on iOS 17 and current iOS |
| 5 Apple Speech and execution policy | Add isolated iOS 26 engine adapter, prewarming, permission/assets checks and conditional continued processing | Same data contract from both engines; real unsupported hardware/locale and rejected/expired tasks degrade correctly |
| 6 Word timing qualification | Preserve/derive word timings, resolve original text and validate alignment per engine | Enable word mode only for qualified mappings; sentence mode remains available on every supported OS |
| 7 Release qualification | Complete full test plan, device/provider matrix, performance and interruption runs, migration/rollback and documentation | Every required result is recorded; unresolved generation paths remain gated |

## Verification matrix

### Systems and hardware

Run new OS-independent tests and user flows on exact iOS 17.0 and 17.5, then iOS 26.x and current iOS. The current workstation has iOS 17.0 and 17.5 simulators plus newer runtimes; provision an iOS 26.x destination if absent. Use iPhone Air on current iOS, iPhone 15 on the installed iOS 17 runtimes, and an iPad on old and current systems. Build affected Watch/tvOS/Catalyst targets separately if touched; their available cached behavior must not acquire an unsupported generation dependency.

Required installed simulator destinations at planning time:

| Runtime | Device | UDID |
| --- | --- | --- |
| iOS 17.0 | iPhone 15 | `C3266B66-8DED-4477-81B7-DC8A62EC23E0` |
| iOS 17.5 | iPhone 15 | `DD940A7E-30B8-4481-BD3C-B29EF0E94456` |
| iOS 17.0 | iPad Pro 10.5 inch | `A13CD9D1-BC96-46E6-BFAA-FEEC6B14EEB5` |
| iOS 27.0 | iPhone Air | `4F199320-8EF3-4109-9CCD-76F940FCC23A` |

Use physical iOS 17 hardware representative of the oldest supported performance tier, a supported iOS 26+ phone, and a newer phone for timing, audio, thermal and battery acceptance. Simulator success does not qualify these properties. Record any unavailable hardware as an unmet release gate rather than substituting an injected OS check.

### Regression coverage

Extend existing linked-passage, calibration-quality, narrated-sentence, timeline-locator, overlay-boundary, model-store and profile-session tests. Add deterministic engine doubles for permission/capability/resource changes, while retaining real-engine fixtures.

Required cases include repeated passages, skipped headings, unspoken front/back matter, abridged/different editions, punctuation, Unicode/inline markup, sentence splits at window seams, chapter transitions, corrupt/missing model assets, denied/revoked permission, unsupported locales, storage exhaustion, paused jobs and stale callbacks. Cover CBR/VBR MP3 with large ID3 artwork, AAC/M4B, multiple tracks, timestamp gaps and a chapter transition inside the initial excerpt.

Verify that mapping improvement emits no listening/reading activity, derived progress does not echo, offline pushes reconcile once, same-item ABS audio/ebook timestamps do not overwrite newer input, and profile/account collisions cannot share private positions. Test intentional rewind, finish/reset, manual correction, pair unlink, download removal/replacement, schema interruption and failure during atomic replacement.

Add a round trip that pairs and syncs an ordinary EPUB, exports a narrated EPUB, reopens that reading revision, and syncs again without locator drift. Stress simultaneous reading saves, listening saves, mapping commits and unlink to verify queue ordering and rejection of obsolete writes.

### Runtime scenarios

Exercise a first model download, cold ebook/index load, warm unprepared passage, cached resume, reading far ahead, cancellation during search, rapid repeated seeks, 0.75x/1x/2x/3x playback, page turns, font/layout changes, reader close/reopen, background/lock, sleep timer, audio interruption and route changes. Kill/relaunch during preparation and verify completed results survive. Force continued-task rejection/expiration on newer iOS; verify 17 never enters that code path.

The exact iOS 17.0 launch test begins with a persisted Apple Speech selection and a plain paused-background-preparation intent written in the newer format. Verify that no iOS 26 Speech/continued-task implementation is constructed or registered, cached mappings resolve in both directions, unavailable selection reports unsupported system, and an English foreground request can select usable QuartzNet without losing the stored job or positions. A missing model or unsupported language reports its separate reason.

Test ordinary local files and Audiobookshelf first, then the existing capability-based downloaded-media paths for at least one separate-book provider pairing. Check precise locator sync where the configured destination supports it, and the existing percentage fallback where it does not. No provider-specific branches or new wire formats are needed in reader UI.

### Performance and quality

Instrument media identity work, EPUB parsing/indexing, model startup, decoding, inference, text matching, persistence and first visible correct highlight separately. Record total time, median, 95th percentile, peak memory, real-time processing throughput, thermal state and acoustic provider. The earlier 0.70-second excerpt measurement excludes setup and is not the startup acceptance result.

Freeze these initial engineering budgets in milestone 0 before tuning begins: 95th-percentile validated cached resume within one second; first matched passage with downloaded media and installed model within five seconds on the newer reference phone and ten seconds on the iOS 17 reference phone; no playback underrun attributable to analysis. Collect at least 20 first-passage samples per reference device, including model startup and uncached EPUB indexing, and measure warm reuse separately. Report first identity establishment, upgrade revalidation and model/media downloads separately. Hold or optimize an engine/device rollout that cannot meet its budget instead of silently weakening match acceptance.

Use a manually labeled real-narration corpus alongside redistributable generated fixtures. Before milestone 2, freeze at least 12 titles: eight clean unabridged pairs, two abridged/different-edition pairs and two titles with targeted repeated passages. Split by title into tuning and held-out sets; the held-out set includes at least four clean pairs and at least 200 labeled spoken positions plus 100 adversarial/unrelated queries. Qualify on held-out data without tuning thresholds against its results.

Every accepted held-out handoff must land in the correct sentence, with zero incorrect accepted jumps on adversarial/unrelated queries, at most 10% abstention on clean spoken positions, and 95th-percentile sentence-start error no greater than 750 ms against the actual player timeline. Report all errors, coverage and abstentions. Word mode additionally requires correct original-word targets and 95th-percentile boundary error no greater than 500 ms; otherwise keep sentence mode. These are release criteria, not claims that the existing engines already meet them. Changes to a frozen threshold require an explicit revised decision and a new held-out evaluation.

Measure at least one hour of foreground read-along and locked/background listening, with a playback-only control on each physical reference device. Compare cached and actively preparing cases, including older-device CPU fallback. Record battery drain, memory, thermal transitions and prepared buffer depth. No fixed battery-efficiency claim is established by a short inference benchmark.

### Commands and evidence

Use the app's documented `xcodebuild` commands with `-scheme enve`, explicit simulator UDID and the `AllTests` plan with `-parallel-testing-enabled NO`. Run a real 17.0 install/launch in addition to compilation. Run `swift test --package-path LocalPackages/StoryAlign` when changing the package. Use the app guide's documented DerivedData location or a task-specific build directory; do not erase a shared cache.

Record exact commands, source revision, device/OS, passed/failed/skipped counts, build errors/new warnings and remaining device gates in a focused verification record. Existing skipped provider/device tests require explicit classification. Do not call the milestone complete based solely on generated code or a recent-OS build. Preserve private books, transcripts, server details, model weights and diagnostic content outside Git.

## Release and rollback

Enable the shared cached-mapping path only after migration/round-trip tests pass. Enable incremental generation for qualified OS/device/engine combinations after sentence mode passes. Enable optional background generation and word mode independently after their separate acceptance runs. Keep full-book export, old calibration and existing narrated-book playback available during rollout.

The existing documentation records an unresolved license/notice check for the exact QuartzNet weights. Resolve that release prerequisite before distributing a new model-backed feature; source-code licensing does not establish model redistribution terms. Do not change signing, entitlements, deployment targets or model dependencies as incidental work.

Rollback disables new generation and following without deleting mappings, original progress, pairings or accepted EPUBs. Readers of an unknown future cache schema ignore that cache and retain existing playback/approximate sync. Reopening on an older OS must never instantiate a stored newer engine selection or crash while loading preferences.

## References

- [StoryAlign CTC core](../testing/storyalign-ctc-core.md) and [mobile verification](../testing/storyalign-ctc-mobile.md).
- Silveran Reader `669a56903316fa51bf9c2850bdc89d9bbcac37dc`: `SMILPlayerActor`, `EphemeralProgressManager` and `MediaOverlayManager`; fragment-first seeking and saved text/audio locator behavior. Fetched and confirmed current on October 30, 2026.
- Storyteller `6d0de764815347983bbab287efb0325a57d1599d`: guided navigation audio/text references and CTC/book export behavior. Fetched and confirmed current on October 30, 2026.
- [SoundLeaf 2.1](https://soundleafapp.com/blog/soundleaf-v21-audiobookshelf-apple-watch-ebook-reader/) documents its short excerpt finder and repeated-text/audio-offset failure cases. [SoundLeaf 2.2](https://soundleafapp.com/blog/soundleaf-v22-read-along-podcast-transcripts/) documents preparation ahead of playback. These establish behavior, not a public implementation or transferable performance guarantee.
- [Apple SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber) describes hardware and locale availability. [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer) describes preparation, timed results and model retention.
- [Apple background execution](https://developer.apple.com/documentation/uikit/preparing-your-ui-to-run-in-the-background) and [continued processing](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados) define execution constraints and system task handling.
