# Third-Party Notices

Enve Book Player for Android includes or depends on software, native code, models, fonts, and brand assets owned by other parties. Those materials are excluded from the Enve license and remain under their own terms.

This inventory describes the repository audited on 2026-08-29. Gradle build files, resolved release dependencies, vendored license files, and upstream notices remain authoritative.

## Bundled source and native components

| Component | Location or version | License | Distribution notes |
|---|---|---|---|
| Foliate JS | `ThirdParty/foliate-js`, commit `6b11e1744346f60504b727984f7d42f0fef3ab54` | MIT | Copyright John Factotum. The app packages an allowlisted runtime subset and retains its license. |
| zip.js | 2.7.52 in the Foliate runtime | BSD-3-Clause | Copyright Gildas Lormeau. Retain `BuildSupport/FoliateRuntime/zip.js-LICENSE.txt` in binary documentation or acknowledgements. |
| PDF.js and its CMaps/fonts | PDF.js 4.7.76 in the Foliate vendored tree | Apache-2.0, BSD-style, and SIL OFL-1.1 terms | The app surfaces the PDF.js, CMap, Foxit font, and Liberation font license texts in acknowledgements. |
| libmobi | 0.12 under `engine/src/main/cpp/libmobi/` | LGPL-3.0-or-later | Built as a separate `libmobi.so` loaded by Enve's JNI bridge. The exact source and replacement/install instructions are published with the app and retained in release evidence. |
| whisper.cpp and ggml | 1.8.4 under `engine/src/main/cpp/whisper/` | MIT | Copyright the ggml authors. The app carries a small JNI bridge based on the upstream Android example. Retain the MIT notice. |

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

## Provider names and logos

Enve displays names and logos for compatible services so users can identify a connection type. Those marks belong to their respective owners. Their presence does not imply endorsement, sponsorship, partnership, or ownership by Enve.

The bundled Grimmory variants are official, unmodified reference assets covered by `ThirdParty/grimmory-branding/ASSET-LICENSE.md` and `ThirdParty/grimmory-branding/TRADEMARKS.md`. The maintainer has confirmed permission to use provider logos in this compatibility context. Forks and redistributors must make their own trademark assessment and must not imply endorsement.

The Enve name, logo, and app icon are not granted for use as a fork's brand by the source license.

## Distribution reminder

An APK, app bundle, store listing, or source archive must retain this file, all applicable license texts and notices, the Enve license and notice, and every item required by `docs/legal/THIRD_PARTY_AUDIT.md`. The Enve license does not narrow any right granted directly by a third-party license.
