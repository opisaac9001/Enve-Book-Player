# StoryAlign CTC mobile verification

Development branch: `storyalign-ctc`. No release or main-branch promotion is approved by this record. Media, model weights, diagnostics and generated books remain outside Git.

## October 20, 2026 results

| Check | Result |
| --- | --- |
| Standalone Swift package | 20 tests passed |
| iOS simulator and physical-device build | Passed; existing `CloudKitProgressSync` retroactive Sendable warning remains |
| Focused app tests | 36 passed: alignment methods, model integrity, SMIL ordering, overlay boundaries/positions, narrated progress, ABS credential recovery and playback startup |
| Broad AllTests run | Failed: tool reported 1,460 passed, 110 failed and 33 skipped after a playback observer crash and timeouts; not a clean acceptance run |
| iPhone 16 Pro, iOS 27.0, Seamage excerpt | 38 seconds analyzed in approximately 0.70 seconds after setup; four accepted prologue sentences, matching Mac timestamps |
| Mac, Seamage excerpts | Prologue and middle-of-book excerpts located correctly; the middle excerpt accepted six sentences |
| Sustained iPhone run | Reached serious thermal state and paused; 319 emission checkpoints retained. Full-book acceptance not established |
| Paced iPhone resume | Reached 26% at fair thermal state; full-book run remains incomplete |
| Exact iOS 17.0 simulator | Native model probe passed: four fixture sentences, 18 anchors |
| Mac Catalyst build | Passed with existing dependency warnings; QuartzNet remains unavailable on Catalyst |
| Full Mac Seamage run | Generated EPUB with 41 SMIL files, 16,826/17,034 eligible sentences accepted (98.8%), 86.9% audio coverage; reader timing review pending |

The broad-suite crash stack enters `PlaybackManager.loadPlaybackPreferences()` through `PlaybackManager.setupObservers()`, then fails retaining an unowned reference. Those files are unchanged by this branch. The failing credential/startup cases passed in the focused rerun; the observer crash has not been resolved or established against a baseline checkout.

The sustained test motivated adaptive pacing: an iOS audio window yields 250 ms while thermal state is nominal and two seconds otherwise. At that stage the app paused at serious/critical thermal state. The resumed run passed the original pause point; the excerpt speed does not establish full-book duration or battery consumption.

## Performance investigation

A 20-second Mac CPU profile attributed approximately 92% of sampled CPU time to model inference, dominated by generic convolution kernels. A Pixel 7a profile attributed approximately 56% to ONNX Runtime, 11% inclusively to audio conversion and 2% to forced matching. These are CPU sample shares, not end-to-end wall-time measurements.

The Pixel compared the same 38-second Seamage Float32 PCM with ONNX Runtime 1.24.2, one warmup and three measured runs per configuration:

| Execution | Median inference | Output agreement with CPU1 |
| --- | --- | --- |
| CPU, one thread | 3.130 s | Baseline |
| CPU, two threads | 1.632 s | Exact |
| XNNPACK, one thread | 3.145 s | Exact |
| Fixed-shape CPU, one thread | 3.136 s | Exact |
| Fixed-shape XNNPACK, one thread | 6.662 s | Exact |

Two threads reduced inference wall time by 48%, while process CPU time stayed near 3.2 seconds per inference. Fixed-shape XNNPACK is rejected based on this measurement. The iPhone Debug configuration uses unoptimized Swift; optimized diagnostic builds are used for device comparisons. ONNX Runtime's native binary was already optimized.

The Pixel subsequently completed 100 uninterrupted two-thread inferences in 184.3 seconds including setup. Median inference was 1.819 s; first/last ten medians were 1.649/1.855 s. Maximum reported thermal status was LIGHT (1). This is a three-minute model stress test, not a full-book battery or thermal acceptance run.

An optimized diagnostic build ran the same PCM on the physical iPhone 16 Pro. Median inference was CPU1 0.470 s, CPU2 0.325 s, XNNPACK1 0.501 s, XNNPACK2 0.339 s, CoreML ALL 0.283 s and CoreML CPUAndNeuralEngine 0.254 s. Every configuration retained the same greedy token sequence. CoreML maximum absolute log-probability difference was 0.000532 (RMS 0.0000123). Thermal state remained fair (1) before/after every variant. CoreML configuration does not establish that each operation ran on the Neural Engine.

CoreML uses the NeuralNetwork model format for these measurements. The MLProgram format failed to compile the frontend convolution with a missing `pad` parameter in ONNX Runtime's export. Model weights remain unchanged. The `storyalignctcbenchmark` debug route reads the fixed PCM from `Library/Application Support/Enve/CTCBenchmark/seamage-38.f32` and writes `benchmark.json` alongside it.

## Pipeline optimization and requalification

The branch now prefers CoreML on Apple platforms, with CPU fallback on session creation or one failed inference. Explicit provider requests remain strict for comparisons. Android uses two CPU threads. Both pipelines decode at most one audio window ahead and cancel/join that producer when conversion stops. Cached work bypasses inference cooling waits. CoreML uses 250 ms nominal / 500 ms fair pacing; CPU keeps the two-second fair delay. The current iPhone experiment continues at serious thermal state with a two-second delay per inferred window and pauses only at critical. Full-book thermal acceptance remains unverified.

On the Pixel, the same 180-second Seamage excerpt took 27.071 s with one CPU thread and 19.139 s with two threads in the new pipeline: 29% less analysis time, with identical 33 accepted sentence ranges. Decode-only processing took 9.010 s. A two-second overlap run took 18.846 s and accepted 33 sentences, but replaced two of the previous matches; it is not a demonstrated quality-equivalent replacement. Production overlaps remain eight seconds on iOS and twelve seconds on Android.

An 85.7-second generated seam fixture accepted 15/15 sentences on the Mac with CPU and CoreML, with identical timings at eight-second overlap. Two-second overlap retained all 15, changing boundaries by at most 20 ms. The Pixel accepted 14/15 at twelve-second overlap and 15/15 at two seconds; this single fixture does not qualify a default change. Android engine verification now has 730 tests, zero failures, one skipped, and debug/release/test APK builds passed.

The iOS CTC path previously reused legacy chapter extraction, which re-encoded an entire M4B with AVAssetExportPresetAppleM4A on the phone. CTC now stages supported original AAC/MP3 audio bytes as one file per input without chapter splitting or re-encoding. Unsupported container/codec combinations retain whole-track conversion. Checkpoint identity is `ctc-original-audio-v3`: earlier chapter-based checkpoints are intentionally not reused against different PCM or a different track layout. Earlier full-book coverage results above describe the old preparation path and must be requalified. Byte-preservation and track metadata tests cover generated AAC input; physical-device full-book validation is pending.

## Remaining acceptance

- Inspect the method selector on iOS 17.
- Finish Seamage with paced processing and inspect coverage, missed passages and ordered SMIL timings.
- Open generated output in the reader and exercise highlighting, sentence seeks and chapter transitions.
- Exercise interruption/resume and cancellation while preserving an accepted book.
- Re-run app verification after final fixes; retain the broad-suite failure as unresolved until explained.
- Confirm the exact exported model's license and download notice requirements before release.

The debug-only `storyalignctcprobe` route obtains the selected book through the existing download services. `storyalignctcfull` exercises the normal app conversion service. `storyalignctcfixture` reads `Library/Application Support/Enve/CTCTestFixture/ctc-fixture.epub` and `ctc-fixture.mp3` for an isolated older-system model check. Reports contain counts, timings and thermal state; do not commit their text/audio-derived contents.

### Pause and export retry behavior

The temperature switch defaults to on and is saved per profile. With it on, iOS pauses only at critical thermal pressure; with it off, Enve does not cancel for temperature. Inference pacing still applies in either mode. Pause beside Cancel preserves the pair and analysis checkpoints for Resume. Discard clears the resumable job.

Export writes a fresh sibling archive and atomically replaces the working output after success. A leftover narrated EPUB no longer blocks a resumed run, and a failed or cancelled export preserves the previous output. Package regressions cover existing output, archive failure, cancellation, and EPUB mimetype ordering.

### Sparse sentence identities

A high acoustic match count does not establish correct highlighting. The first iPhone Seamage export had 139 unresolved SMIL targets and 12,078 resolved targets containing a different original sentence. CTC keeps original sentence IDs across rejected matches; tagging only accepted sentences had renumbered the XHTML densely. The difference accumulated within a chapter and reset at the next chapter. Chapter Five reached six sentences of displacement.

CTC now tags the complete original sentence list while emitting SMIL timings only for accepted sentences. Apple Speech keeps its existing export path. Integration regressions cover accepted IDs 0/2/4 and an unspoken opening heading with multiple gaps. Emission checkpoints stay compatible because this changes export identities, not acoustic analysis. Validate every SMIL target against the original segmented text as well as checking ZIP integrity and timing ranges.

Validation after the identity fix: 32 core regressions and 17 focused iOS overlay/timeline tests pass. The rebuilt desktop Seamage has 16,837 SMIL references: zero missing targets, zero sentence-text mismatches against all original segmented identities, and zero duplicate IDs. All 45 XHTML bodies preserve original text. iPhone Air reader playback loads all 16,837 clips and advances original fragments 1→2→3 across actual audio times 17.4–35.7 seconds with live highlighting. Physical-device regeneration and its exported-link audit are tracked separately.

The physical cached replay reached export, then iOS expired its background task at normal thermal pressure. The validated desktop export is installed into the existing accepted-book path through the debug-only storyalignctcinstall route (incoming Documents/storyalign-corrected.epub), clearing the paused diagnostic job without deleting the paired book or locator. This verifies the corrected artifact on the phone; it is not evidence that the physical background replay completed. The final export still needs checkpointed resume to avoid reconstructing matches after an expired session.

Android separately keeps original IDs but previously skipped inline ranges and could match repeated accepted text to an earlier omitted occurrence. CTC now tags full original text, wraps inline ranges, and validates target uniqueness and text before promotion. 742 engine tests have zero failures/errors (one skipped); debug/release/test APK builds pass. Pixel Seamage excerpt retains identical 33 timing ranges; its full-book coverage gate correctly prevents exporting that partial-book result. The 15-sentence seam fixture exports 14 accepted clips, with zero missing/duplicate/wrong-text targets and valid ZIP CRCs.

Final device artifact verification: the corrected Seamage file pulled back from accepted.epub is byte-identical (SHA-256) to the validated desktop rebuild. All 16,837 device-exported SMIL references resolve to exactly the original sentence text, with zero missing targets and zero duplicate IDs. The paired book was reopened by its existing storyalign stable ID; no book-record or locator replacement was performed. Native background replay did not complete; the verified desktop artifact was installed for user listening checks. Neighbor-bounded acoustic recovery remains a proposed improvement, not implemented by this identity repair.
