# Third-Party Notices

Enve Book Player for Android includes or depends on software, native code, models, fonts, and brand assets owned by other parties. Those materials are excluded from the Enve license and remain under their own terms.

This inventory describes the repository audited on 2026-08-29. Gradle build files, resolved release dependencies, vendored license files, and upstream notices remain authoritative.

## Bundled source and native components

| Component | Location or version | License | Distribution notes |
|---|---|---|---|
| Foliate JS | `ThirdParty/foliate-js`, commit `6b11e1744346f60504b727984f7d42f0fef3ab54` | MIT | Copyright John Factotum. The app packages an allowlisted runtime subset and retains its license. |
| Liseur reader behavior | Adapted wide-content fitting; revision `1822c64b6a462e6d9285a1b43e2ec7448e4a7719` | MIT | Copyright 2026 chmouel. See `BuildSupport/Liseur/UPSTREAM.md` and `LICENSE.txt`. |
| fflate | `vendor/fflate.js` in the pinned Foliate runtime | MIT | Copyright Arjun Barrett. Retain `BuildSupport/FoliateRuntime/fflate-LICENSE.txt` in binary documentation or acknowledgements. |
| zip.js | 2.7.52 in the Foliate runtime | BSD-3-Clause | Copyright Gildas Lormeau. Retain `BuildSupport/FoliateRuntime/zip.js-LICENSE.txt` in binary documentation or acknowledgements. |
| PDF.js and its CMaps/fonts | PDF.js 4.7.76 in the Foliate vendored tree | Apache-2.0, BSD-style, and SIL OFL-1.1 terms | The app surfaces the PDF.js, CMap, Foxit font, and Liberation font license texts in acknowledgements. |
| libmobi | 0.12 under `engine/src/main/cpp/libmobi/` | LGPL-3.0-or-later | Built as a separate `libmobi.so` loaded by Enve's JNI bridge. The exact source and replacement/install instructions are published with the app and retained in release evidence. |
| whisper.cpp and ggml | 1.8.4 under `engine/src/main/cpp/whisper/` | MIT | Copyright the ggml authors. The app carries a small JNI bridge based on the upstream Android example. Retain the MIT notice. |
| Literata, Atkinson Hyperlegible Next, and Lexend | Google Fonts commit `334b789e33413f3aba4264d9aa6c97f7b94c5a2f`; see `BuildSupport/ReaderFonts/UPSTREAM.md` | SIL Open Font License 1.1 | Bundled as reader typefaces. Retain each font license and the recorded file digests. |

## Direct Gradle dependencies

| Component family | Pinned version | License or terms |
|---|---:|---|
| AndroidX Core, Activity, Lifecycle, Compose, Material, Navigation, Room, WorkManager, Paging, DataStore, Media3, AppCompat, Browser, WebKit, Glance, Fragment, Security Crypto, and test libraries | Versions in Gradle build files; Compose BOM 2025.08.00 | Apache-2.0 |
| Kotlin, kotlinx.coroutines, and kotlinx.serialization | Kotlin 2.3.20; coroutines 1.9.0; serialization 1.7.3 | Apache-2.0 |
| Dagger and Hilt | 2.58; AndroidX Hilt 1.2.0 | Apache-2.0 |
| Retrofit and OkHttp | Retrofit 2.11.0; OkHttp 4.12.0 | Apache-2.0 |
| Coil | 2.7.0 | Apache-2.0 |
| Readium Kotlin Toolkit | 3.3.0 | BSD-3-Clause |
| NanoHTTPD | 2.3.1 | BSD-3-Clause |
| jsoup | 1.17.2 | MIT |
| ONNX Runtime Android | 1.24.2 | MIT; retain the runtime license and third-party notices in binary distributions |
| sherpa-onnx static-link AAR | 2.0.1 from the k2-fsa/sherpa-onnx GitHub release, SHA-256 `07e042d97f3a6bd5b7fe74d4eef0513dc01a714b16c15a903250095aba43a575`; only its classes and arm64-v8a JNI library are packaged | Apache-2.0. The JNI library statically links ONNX Runtime 1.28.2 (MIT) and sherpa-onnx's native dependencies, including OpenFst, kaldi-decoder, kaldi-native-fbank and simple-sentencepiece (Apache-2.0), Eigen (MPL-2.0), and nlohmann/json (MIT). Exact versions, upstream text digests and bundled notices are retained in `BuildSupport/SherpaONNX/`; Release 2.0 no longer links espeak-ng or piper-phonemize |
| jcifs-ng | 2.1.10 | LGPL-2.1-or-later; exact source and replacement instructions are retained with release evidence |
| Android libarchive wrapper and libarchive | 1.1.6 | Apache-2.0 wrapper with libarchive's BSD-style component licenses |
| Google Cast framework and Play services dependencies | Cast framework 21.5.0 | Google APIs and SDK terms; not relicensed under the Enve license |
| Google Play Billing Library | 9.1.0 | Google Play SDK terms; not relicensed under the Enve license |
| ML Kit GenAI Prompt API | 1.0.0-beta2 | Google APIs and ML Kit terms; includes separate service, telemetry, and model terms |
| LiteRT-LM Android | 0.8.0 | Apache-2.0 for the framework; model files have separate licenses |
| JUnit 4 | 4.13.2 | Eclipse Public License 1.0 |

The final APK also contains transitive dependencies. Before each binary release, generate the resolved release dependency graph and include every required license and NOTICE file. A direct-dependency list is not a substitute for that exact release inventory.

## Runtime models

Enve does not license model weights merely by supporting or downloading them. The offered Qwen3 0.6B LiteRT-LM and Whisper tiny.en downloads are revision-pinned, SHA-256 verified, and identified in `BuildSupport/Models/UPSTREAM.md`; their terms are shown before download and remain available in the in-app acknowledgements. User-selected model files may carry different terms.

ML Kit states that its APIs may send performance and utilization metrics and may contact Google for updates. Binary distributors must provide the privacy disclosures required for their distribution channel.

The optional StoryAlign CTC engine downloads an English QuartzNet ONNX checkpoint from Storyteller's registry, project `67994333`, model version `3023100`. The model SHA-256 is `3a4cf199c53475ae752694bb65989c05755bf6920d8ac8aaf51581a1021bdf2c`. Weights are not included in this repository. The exact exported checkpoint's license and downstream requirements remain unconfirmed. Confirm provenance and applicable terms, retain required notices, and present any required download terms before releasing this engine. Storyteller's source license and ONNX Runtime's MIT license do not establish the weights' license.

### On-device narrator packs

Each optional narrator pack is downloaded only when selected, verified against the SHA-256 digests in `engine/src/main/java/com/enve/app/readium/narrator/NarratorPack.kt`, and stored in app-private no-backup storage. No narrator weights or voices are included in this repository, APK, or app bundle. The archives come from the mutable `tts-models` release of k2-fsa/sherpa-onnx, so a replaced upstream file fails verification instead of being installed. Only the files the runtime needs are extracted; the Kokoro archive's espeak-ng data and Chinese assets are skipped.

- **Kokoro**: `kokoro-int8-multi-lang-v1_0.tar.bz2`, `132353410` bytes, SHA-256 `72c347230107ef8a31098ec4d468a605244beef5f1ed00db97efa13518800653`. Kokoro-82M v1.0 by hexgrad, int8 conversion by k2-fsa. Apache-2.0; the pack's `LICENSE` is retained beside the model. Voices `af_heart`, `af_bella`, `am_michael`, and `am_puck`.
- **Kokoro English pronunciation** uses [Misaki](https://github.com/hexgrad/misaki), the [PeterReid English G2P model](https://huggingface.co/PeterReid/graphemes_to_phonemes_en_us), and the [nekwo ONNX export and lexicon](https://huggingface.co/nekwo/misaki-en-us-g2p-onnx/tree/4b3a605d2f605318ab4f762ab9855c44106528b7), all under Apache-2.0. The English frontend downloads these two files with the Kokoro pack and maps unknown words locally.
- **Supertonic 3**: `sherpa-onnx-supertonic-3-tts-int8-2026-05-11.tar.bz2`, `128774318` bytes, SHA-256 `82fa96f91c4ef8abaae3a14a3f4153facf88bed821d1f7331cec2700f432c427`. Supertonic 3 by Supertone Inc., int8 conversion by k2-fsa. The weights and voice styles are licensed under the [BigScience OpenRAIL-M license](https://huggingface.co/Supertone/supertonic-3/blob/main/LICENSE), including its use restrictions. The archive's bundled `LICENSE` is Supertone's MIT code license and does not replace OpenRAIL-M. Present the OpenRAIL-M terms and use restrictions before download.
- **Pocket TTS**: `sherpa-onnx-pocket-tts-int8-2026-01-26.tar.bz2`, `98336520` bytes, SHA-256 `2f3b88823cbbb9bf0b2477ec8ae7b3fec417b3a87b6bb5f256dba66f2ad967cb`. [Pocket TTS](https://huggingface.co/kyutai/pocket-tts) by Kyutai, ONNX export by KevinAHM, int8 conversion by k2-fsa, all under CC BY 4.0. The archive README's "non-commercial" remark conflicts with its CC BY 4.0 `LICENSE` and with the upstream model cards. Kyutai's model card prohibits voice impersonation or cloning without consent and deceptive or unlawful use; present those terms before download. Attribution is required.
- **Pocket TTS voice**: `alba-mackenna/casual.wav` from [kyutai/tts-voices](https://huggingface.co/kyutai/tts-voices#alba-mackenna) revision `323332d33f997de8394f24a193e1a76df720e01a`, `958542` bytes, SHA-256 `46264e83cb99115c3d210260e029117566d9c64f20266d10daa78107759ede3e`. The voice of Alba MacKenna, licensed under CC BY 4.0. Attribution is required.
- **Phonon**: [xn-ptts v0.7.0](https://github.com/gradium-ai/xn-ptts/tree/32c1554a8ce442d672de90fc82700bbdcf08d918) by Gradium, built from the pinned source using its Apache-2.0 license option. [Phonon 31M English](https://huggingface.co/gradium/phonon-31m-en/tree/92741c5b07d085ff840e26fea8ce43110b87852f) and [Spencer and Hugh voice embeddings](https://huggingface.co/gradium/phonon-voices/tree/da6c9ec0d47be8df5c87c730a3aa97187f3229c3) are Apache-2.0. The Kotlin and JNI adapters are Enve code. Phonon is available when the build supplies the native runtime.
- **Underdog Woof**: [Conway Research, revision `be702960539777fc3f698e54335276a8391b00f9`](https://huggingface.co/ConwayResearch/Underdog-Woof/tree/be702960539777fc3f698e54335276a8391b00f9), including the Juno and Mira voices. The Underdog Non-Commercial License 1.0 applies to the model and its runtime. Enve supplies a separate adapter and includes the original license and notices in opt-in private debug builds.

## Provider names and logos

Enve displays names and logos for compatible services so users can identify a connection type. Those marks belong to their respective owners. Their presence does not imply endorsement, sponsorship, partnership, or ownership by Enve.

The bundled Grimmory variants are official, unmodified reference assets covered by `ThirdParty/grimmory-branding/ASSET-LICENSE.md` and `ThirdParty/grimmory-branding/TRADEMARKS.md`. The maintainer has confirmed permission to use provider logos in this compatibility context. Forks and redistributors must make their own trademark assessment and must not imply endorsement.

The Enve name, logo, and app icon are not granted for use as a fork's brand by the source license.

## Distribution reminder

An APK, app bundle, store listing, or source archive must retain this file, all applicable license texts and notices, the Enve license and notice, and every item required by `docs/legal/THIRD_PARTY_AUDIT.md`. The Enve license does not narrow any right granted directly by a third-party license.

## Listening-position QR codes

ZXing Core 3.5.4 (`com.google.zxing:core`) is used for on-device QR encoding and decoding under Apache-2.0. Copyright ZXing authors. Upstream: https://github.com/zxing/zxing. The app bundles the Apache-2.0 license in its acknowledgements.
