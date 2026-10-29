# StoryAlign CTC core

The experimental QuartzNet engine adds a sentence-level forced-alignment path to the local StoryAlign package. It accepts the original EPUB text and QuartzNet character probabilities directly. It does not pass a decoded transcript through the legacy aligner.

## References

Reviewed after upstream fetch and clean fast-forward checks on October 20, 2026:

- Storyteller `ceaff0e73cf6d565942306c2d3b7e992c03bba35`: CTC boundary search, forced alignment, model signal preparation, character-space folding and calibrated boundary offsets.
- Silveran Reader `669a56903316fa51bf9c2850bdc89d9bbcac37dc`: narrated EPUB generation, SMIL parsing and sentence-fragment playback expectations.

Reference implementations were consulted for behavior. The mobile implementation uses native Swift, the existing Enve StoryAlign EPUB pipeline and the pinned ONNX Runtime Objective-C bindings.

## App integration

Create `AlignmentSession(request:config:logger:)` without a transcriber factory. Call `StoryAligner.alignStory(session:ctcConfiguration:)` with `CTCAlignmentConfiguration(modelDirectory:)`. Keep sentence granularity and no granularity expansion. The CTC overload does not request Speech authorization or instantiate Apple's speech analyzer.

The model directory must contain the exact `model.onnx`, `config.json` and `vocab.txt` files listed in `QuartzNetModelPackage.files`. Each file is verified against its pinned size and SHA-256. This English model accepts prepared mono 16 kHz signal input. Preparation uses pre-emphasis and reflected padding; the graph handles subsequent acoustic feature processing.

`AlignmentResult.ctcQuality` records eligible and accepted sentence counts, computed text coverage and audio coverage. The same Codable value is embedded as `META-INF/enve-ctc-quality.json` inside the output EPUB so quality and book promotion can be atomic.

## Bounds and recovery

- Audio is decoded one window at a time: 38 seconds by default, with eight seconds of overlap. Adjacent raw emission windows are stitched at the overlap midpoint into a bounded window of at most 68 seconds, so sentences crossing an inference boundary remain alignable.
- Probability tensors are checkpointed by exact audio-source content hashes, pinned model identity, preprocessing/algorithm version and window configuration. Changing ebook text can reuse acoustic work.
- One inference session is used. Apple platforms prefer CoreML, with CPU fallback; Android uses two CPU threads.
- iOS paces inference by provider and thermal state. Temperature auto-pause defaults on and pauses at critical; manual pause preserves checkpoints. Sustained pacing validation is recorded in `storyalign-ctc-mobile.md`.
- Alignment uses independently located sentence windows and an eight-million-cell trellis limit.
- Multiple ordered ten-character anchors are required. Competing repeated passages are withheld.
- Weak acoustic evidence and implausible reading rates are rejected. A longest consistent sentence chain removes timing outliers without dropping a correct suffix; small calibrated overlaps are trimmed while preserving positive duration. Each audio window searches independently, so an earlier false anchor cannot permanently hide correct text.
- Full-book output requires at least three accepted sentences and 70% coverage of eligible sentences. These initial thresholds need real-book calibration before release.
- Cancellation is checked during decoding, hashing, indexing, alignment and between inference windows. The Objective-C runtime wrapper does not expose in-flight inference termination, so a running model call completes before cancellation is observed.

## Verification recorded

The standalone package builds on Apple silicon macOS with ONNX Runtime 1.24.2. Its pinned binary has device, simulator and native macOS slices, but no Mac Catalyst slice; CTC availability explicitly excludes Catalyst. Twenty focused tests cover repeated CTC labels, blanks, surrounding audio, impossible paths, trellis memory, poor acoustic support, whole-book coverage, reflected signal preparation, anchor ordering, unrelated books, repeated passages, original sentence locations, late-anchor recovery, overlapping/equal timestamps, file order, a 20-second sentence across an inference seam, PTS gap placement, and longest-chain equivalence against an exhaustive reference.

A local fixture with four original sentences and synthesized narration exercised the actual pinned model and the full EPUB pipeline. All four sentences were aligned; generated quality recorded 100% sentence coverage and approximately 91% audio coverage. The output contained ordered SMIL clips and the embedded quality metadata. This synthetic check is supporting evidence, not physical-device or Seamage acceptance.

The package includes the `ctc-align` command:

```text
ctc-align EPUB AUDIO MODEL_DIRECTORY SESSION_DIRECTORY
ctc-align EPUB AUDIO MODEL_DIRECTORY SESSION_DIRECTORY PROBE_START PROBE_DURATION
```

The probe analyzes one 1–38 second excerpt and reports model timing, greedy text, chapter anchors and accepted sentence ranges. It uses the same forced window matcher and monotonic timing filter as full-book alignment. Each range includes the original chapter/sentence identifiers, original text, source-audio start/end times and mean character log probability; this score is not a calibrated confidence. A probe does not perform full-book export or represent a full-book coverage result. Books, audio, model weights, probe text and generated outputs must remain outside version control.

## Release gates

The exact model weights' redistribution terms still need verification; Storyteller's source license does not establish the weights' license. Physical iPhone and Android verification, pre-iOS-26 runtime verification, real Seamage alignment, thermal tests, background recovery and existing-output preservation remain app-level acceptance work.

## Main integration — 2026-10-22

The merged app builds and launches on iPhone Air with Xcode 27.1. The complete `AllTests` run with parallel testing disabled passed with no failures (1625 reported passes, 33 skipped live-provider/device prerequisites); the standalone StoryAlign package passed all 32 tests. The earlier broad-suite crash did not recur in this run; its original cause remains unconfirmed. This does not qualify a full-book background run or resolve the model-license release gate.

References were refreshed before integration: Silveran `669a56903316fa51bf9c2850bdc89d9bbcac37dc` and Storyteller `177e6f074482d9496e34a90199cc138a69b7f31e`. The Storyteller update changed covers and progress documentation; its alignment implementation was unchanged from the prior review.
