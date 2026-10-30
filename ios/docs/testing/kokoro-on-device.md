# Kokoro on-device trial — 2026-10-22

Kokoro's existing iOS backend is fast enough for local narration on the tested iPhone 16 Pro. The tested Android INT8 export runs locally and plays audio, but cannot maintain continuous real-time generation on the Pixel 7a with this runtime.

## Measured results

| Device / configuration | Generation | Generated audio | Real-time factor |
| --- | ---: | ---: | ---: |
| iPhone 16 Pro, warm short text | 0.756–0.762 s | 5.000 s | 0.151–0.152 |
| iPhone 16 Pro, seven sentences | 4.519 s | 28.875 s | 0.156 |
| iPhone 16 Pro, 70 sentences | 48.526 s | 288.750 s | 0.168 |
| Pixel 7a, CPU / 4 threads, warm short text | 4.882–5.077 s | ~4.166 s | 1.172–1.219 |
| Pixel 7a, CPU / 4 threads, seven sentences | 25.691 s | 22.323 s | 1.151 |
| Pixel 7a, CPU / 2 threads, seven sentences | 27.183 s | 22.327 s | 1.217 |
| Pixel 7a, CPU / 4 threads / two-sentence limit | 27.535 s | 22.324 s | 1.233 |

Real-time factor is generation time divided by output duration. A factor below 1 can keep ahead of playback at the tested speed, 1.0×.

The initial iPhone run took 3.835 seconds for its first five-second utterance. Later process launches took 1.425–1.480 seconds for that utterance, then ~0.76 seconds warm. Loading the cached models took 8.56–8.88 seconds before synthesis. Initial model downloads are excluded from those loading figures.

The 70-sentence iPhone run repeats the seven-sentence passage ten times. Individual passes rose from 4.54 to 5.03 seconds, still generating 28.875 seconds of audio each. Thermal state changed from nominal to fair. Recorded process-footprint snapshots were approximately 545–652 MB during generation; these include Enve and the test host and are not a sampled peak or a standalone model allocation.

The measured iOS model/front-end directories contain 124,890,534 bytes (~125 MB). This excludes frameworks, generated WAVs, and any OS-managed Core ML caches. The existing UI's download-size estimate was not changed.

Android's official APK download is 161,464,856 bytes. Its uncompressed model/front-end assets total 215,321,602 bytes, including a 114,299,010-byte ONNX model and 53,790,720-byte voice bank. The harness also copies 17,991,651 bytes of eSpeak data to app files. Harness PSS snapshots reached ~489 MB; PSS and iOS physical footprint are different measurements.

## Runtime and method

- iOS 27.0, FluidAudio revision `5390df9752c8fc583596018360c5fd70d6fa6c75`, default legacy English `KokoroAneManager`, voice `af_heart`. This is the manager and preparation path used by `KokoroTTSRuntime`; v3 was not enabled.
- Android API 37, sherpa-onnx 1.13.8 / ONNX Runtime CPU, `kokoro-int8-multi-lang-v1_1`, speaker 0 (`af_maple`). This is a different export and voice from iOS.
- Both synthesize inside the phone. Android's standalone harness has no network permission. No TTS server is used.
- Repeated calls invoke the model directly, bypassing Enve's synthesized-audio disk cache. SDK model and front-end caches remain warm.
- Android callbacks record the first returned audio chunk and immediately return. They do not wait for AudioTrack playback. WAV writing and playback occur after the timed generation call.
- Every successful output passed nonempty, finite, and nonsilent checks. Saved samples are mono 24 kHz WAVs. Short-sample playback started successfully on both phones; listening quality was not scored.
- On Pixel, requesting XNNPACK logged `Available providers: NnapiExecutionProvider, CPUExecutionProvider, . Fallback to cpu!`; it did not test an accelerated XNNPACK path. The packaged sherpa library also contains the API-level restriction for its NNAPI path. One CPU thread failed twice; the diagnostic retry returned 141,600 non-finite samples and is excluded from speed results.
- Android alternatives ran sequentially, with no controlled cooldown. The two-sentence run ended at light thermal status. These runs did not establish an improvement over the initial four-thread configuration.

The Android JNI callback needs a concrete callback method or class-based Kotlin lambdas. The retained harness uses `-Xlambdas=class`; the default invokedynamic lambda caused a JNI method-lookup abort during harness setup. eSpeak data must be copied to an actual filesystem directory before constructing the native engine.

## Four-voice follow-up

The iOS picker now includes Heart and Bella (female), plus Michael and Puck (male), all American English. The selection is stored in the current profile and is passed to both playback and paragraph prefetch. Synthesized-audio cache keys include the voice ID.

The same pinned Core ML chain accepts all four style profiles. The added profiles are downloaded from the model repository's `voices/<id>.json` files and converted to 510 × 256 Float32 binary files. Binary row zero is JSON key `"1"`; the separate `embedding` field is not a row. Converting Heart reproduced the shipped `af_heart.bin` byte for byte (SHA-256 `d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b`). No dependency upgrade or changes to the model weights were required.

Each cached profile is 522,240 bytes. The three additional profiles add 1,566,720 bytes (~1.57 MB); the measured model/front-end directories now contain 126,457,254 bytes. These figures exclude generated narration, frameworks, and OS-managed Core ML caches.

`testFourVoiceSynthesisAndCache` passed on the iPhone 16 Pro with `ENVE_KOKORO_VOICES=1`. It generated the same two-sentence text with each voice, checked finite and nonsilent output, verified four different PCM hashes, checked an identical cache hit for each voice, and started playback of each WAV. Audio durations were 7.275 s (Heart), 7.825 s (Bella), 8.150 s (Michael), and 7.450 s (Puck). This check does not measure uncached throughput or score listening quality.

`KokoroVoicesUITests.testMaleAndFemaleVoicesPersistAfterRestart` also passed on the physical iPhone. It selects each of the four rows, checks the selected narrator in the controls, restarts Enve, and verifies that Puck remains selected. Enable `ENVE_KOKORO_VOICES_UI=1` in the UI-test runner to repeat it; the device needs a library ebook. Physical UI automation was used because the iPhone Air Simulator automation session was unavailable during this trial. The device result includes the same internal QoS warning seen in the earlier connection-flow UI checks.

Final verification ran `AllTests` on iPhone Air Simulator: 1,636 passed, 35 skipped, and three failed (two `ABSCredentialsRecoveryTests` wait timeouts and a killed `MediaOverlayPlayerPositionTests` test process). A focused run of `KokoroVoiceTests`, `ABSCredentialsRecoveryTests`, and `MediaOverlayPlayerPositionTests` then passed all 10 tests with zero failures or skips. The full suite did not finish green in that combined run. No new compiler warnings were introduced; the existing CloudKit conformance warning remains.

The full-suite result is `test_sim_2026-10-23T02-13-38-179Z_pid33262_019fff56.xcresult`; the focused retry is `test_sim_2026-10-23T02-17-04-052Z_pid33262_1e8fec5a.xcresult`, both under the local XcodeBuildMCP workspace's `result-bundles/` directory. The physical generation and picker tests each passed one test with zero failures.

Implementation files are `KokoroTTSVoice.swift` (catalog and profile assets), `KokoroTTSEngine.swift` (voice-specific synthesis and cache identity), `EbookTTSService.swift` (profile preference and prefetch), `ReaderTTSSheet.swift` (picker), and the Kokoro download-detail string in `EbookTTSEngineChoice.swift`.

An existing Heart-only installation finishes the Kokoro download once to fetch the additional profiles. The cached model weights are reused. Download readiness now requires all four profiles, so the app does not promise offline availability before they are present.

The full voice inventory contains [28 English voices: 15 female and 13 male](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md). This change exposes and tests four. Upstream documents the shared-chain voice-profile support in [FluidAudio's Kokoro guide](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/TTS/KokoroAne.md); the app supplies the JSON-to-binary conversion missing from its older pinned downloader.

The local voice report, WAVs, and test result were retained outside the repository. The opt-in test writes `Library/Caches/KokoroVoiceCheck/` in the app container.

## Repeating the iPhone benchmark

`enveTests/KokoroOnDeviceBenchmarkTests.swift` is opt-in and skips ordinary test runs. It also skips Simulator performance measurements. Set `ENVE_KOKORO_BENCHMARK=1` in the test host's environment. Set `ENVE_KOKORO_PASSAGE_REPEATS=10` for the longer run; the default is one passage.

Build from this app root, supplying the configured development team for the unit-test target:

```sh
xcodebuild -project enve.xcodeproj -scheme enve -testPlan AllTests \
  -destination 'platform=iOS,id=<device-udid>' \
  -derivedDataPath .build/DerivedData \
  -only-testing:enveTests/KokoroOnDeviceBenchmarkTests \
  DEVELOPMENT_TEAM=<configured-team> -quiet build-for-testing
```

For command-line execution, copy the generated `enve_AllTests_iphoneos*.xctestrun` alongside the original in `Build/Products`. Add the environment variables to the `enveTests` target's `EnvironmentVariables` dictionary under `TestConfigurations[].TestTargets[]`. Keeping the copy in that directory preserves `__TESTROOT__` references. Run:

```sh
xcodebuild test-without-building -xctestrun '<copied-xctestrun>' \
  -destination 'platform=iOS,id=<device-udid>,arch=arm64' \
  -only-testing:enveTests/KokoroOnDeviceBenchmarkTests \
  -resultBundlePath '<new-result-directory>.xcresult'
```

The app writes `Library/Caches/KokoroBenchmark/report.json`, four short WAVs, and `long.wav`. Use its private cache: files in Documents can be moved by Enve's automatic file-sharing importer.

## Evidence and scope

Numeric reports are preserved in [kokoro-on-device-results.json](kokoro-on-device-results.json). Full local artifacts, WAVs, physical-device `.xcresult` bundles, and the standalone Android benchmark harness were retained outside the repository. The harness did not modify Enve Android or install a system TTS engine.

The iPhone physical-device benchmark passed, including the 70-sentence run and short WAV playback. The final physical build and tests produced no warnings from the new test. The iPhone Air Simulator build succeeded; the opt-in test was correctly skipped (one skipped, zero failures). That build reported 31 warnings in unchanged UnrarKit, libsmb2, and CloudKit sync code. The initial performance trial changed no production source or package pins. The subsequent four-voice picker changes are described above. Existing unrelated Duo edits were preserved.

This establishes local generation throughput and basic playback. It does not establish battery consumption, hours of continuous narration, locked-screen/background behavior, reader highlighting, subjective voice quality, or performance on other phones and OS versions. Upstream's [Core ML compatibility notes](https://github.com/FluidInference/FluidAudio/blob/5390df9752c8fc583596018360c5fd70d6fa6c75/Documentation/TTS/KokoroAne.md) still require device/OS testing.

Read-aloud references were fetched and reviewed at Silveran Reader `669a56903316fa51bf9c2850bdc89d9bbcac37dc` and Storyteller `b69f9f18109703f3920b504a9de48f48ee73a88f`. Neither reference checkout was changed.

Android package provenance: [official APK index](https://k2-fsa.github.io/sherpa/onnx/tts/apk.html), [tested 1.13.8 APK](https://huggingface.co/csukuangfj2/sherpa-onnx-apk/resolve/main/tts-new/1.13.8/sherpa-onnx-1.13.8-arm64-v8a-eng-tts-kokoro-int8-multi-lang-v1_1.apk), SHA-256 `317913c0c2c593b2fd49c0f0764d048e55eec081c1a75d7aa5da2557469fbd1e`.
