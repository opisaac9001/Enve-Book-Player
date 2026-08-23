# Third-Party Notices

Enve Book Player includes or depends on software, models, fonts, recordings, and brand assets owned by other parties. Those materials are excluded from the Enve license and remain under the terms listed below.

This inventory describes the repository state audited on 2026-08-08. Versions are taken from `Package.resolved`, package manifests, and vendored provenance files. Full license texts distributed inside vendored source directories remain authoritative.

## Swift package dependencies

| Component | Pinned version | License | Source and required notice |
|---|---:|---|---|
| CryptoSwift | 1.10.0 | zlib-style license | [krzyzanowskim/CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift). Redistributed products must acknowledge Marcin Krzyzanowski as required by the package license. |
| DifferenceKit | 1.3.0 | Apache-2.0 | [ra1028/DifferenceKit](https://github.com/ra1028/DifferenceKit) |
| FluidAudio | revision `5390df9752c8fc583596018360c5fd70d6fa6c75` | Apache-2.0 | [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio). Also contains the separately listed FastCluster, VBx, and NeMo text-processing components. |
| Fuzi, Readium fork | 4.0.0 | MIT | [readium/Fuzi](https://github.com/readium/Fuzi) |
| GCDWebServer, Readium fork | 4.0.1 | BSD-3-Clause | [readium/GCDWebServer](https://github.com/readium/GCDWebServer) |
| Pulse | 5.2.3 | MIT | [kean/Pulse](https://github.com/kean/Pulse) |
| PulseLogHandler | 5.1.0 | MIT | [kean/PulseLogHandler](https://github.com/kean/PulseLogHandler) |
| Readium Swift Toolkit | 3.11.0 | BSD-3-Clause | [readium/swift-toolkit](https://github.com/readium/swift-toolkit) |
| SQLite.swift | 0.16.0 | MIT | [stephencelis/SQLite.swift](https://github.com/stephencelis/SQLite.swift). Resolved by Readium; it is not linked into the currently selected Enve products. |
| SwiftLog | 1.13.2 | Apache-2.0 | [apple/swift-log](https://github.com/apple/swift-log). Its `NOTICE.txt`, including the SwiftNIO-derived lock acknowledgement, must be retained. |
| SwiftSoup | revision `83336847e47b2f499330c15426ad2fb180e72d9b` | MIT | [scinfu/SwiftSoup](https://github.com/scinfu/SwiftSoup) |
| Zip | 2.1.2 | MIT, with zlib-licensed minizip files | [marmelroy/Zip](https://github.com/marmelroy/Zip). Minizip carries copyrights for Gilles Vollant, Even Rouault, Mathias Svensson, Nathan Moinvaziri, Terry Thorsen, and Info-ZIP in its source headers. |
| ZIPFoundation, Readium fork | 3.0.1 | MIT | [readium/ZIPFoundation](https://github.com/readium/ZIPFoundation) |

AMSMB2 declares Swift Atomics 1.2 or newer for its test target, and Readium declares the Swift-DocC plugin for package documentation. Neither is linked into the shipping Enve products or pinned in the application `Package.resolved` file.

## Local and vendored source

| Component | Location | License | Notes |
|---|---|---|---|
| AMSMB2 4.0.3 | `LocalPackages/AMSMB2/` | MIT wrapper combined with LGPL-2.1-or-later libsmb2 | Exact copy of [amosavian/AMSMB2](https://github.com/amosavian/AMSMB2) commit `1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0`. See its `PROVENANCE.md`. |
| libsmb2 | `LocalPackages/AMSMB2/Dependencies/libsmb2/` | LGPL-2.1-or-later for `lib/` and `include/`; BSD-2-Clause for examples | Exact copy of [sahlberg/libsmb2](https://github.com/sahlberg/libsmb2) commit `aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03`. The iOS app embeds it inside `AMSMB2.framework`. Binary distributors must preserve LGPL notices and provide the corresponding source and the practical ability to rebuild or relink with a modified compatible library. |
| StoryAlign | `LocalPackages/StoryAlign/` | MIT | Copyright 2025-2026 Rich Waters; portions copyright 2023 Shane Friedman. |
| Vendored ZIPFoundation | `LocalPackages/StoryAlign/VendoredZIPFoundation/` | MIT | Copyright 2017-2024 Thomas Zoechling. |
| RAR Swift adapter | `LocalPackages/UnrarKit/` | Project-local adapter with retained BSD-style UnrarKit notice | `Package.swift` and `RARArchive.swift` are Enve-local code rather than a vendored abbeycode/UnrarKit revision. See its `PROVENANCE.md`. |
| UnRAR source 6.1.7, API 6.12 | `LocalPackages/UnrarKit/Sources/unrar-lib/` | UnRAR freeware license | Exact copy of the 147 portable source files in RARLAB archive `unrarsrc-6.1.7.tar.gz`, SHA-256 `de75b6136958173fdfc530d38a0145b72342cf0d3842bf7bb120d336602d88ed`, dated 2022-05-04. RARLAB distributes source archives rather than an authoritative Git history, so no commit applies. Copyright Alexander Roshal. It may be used for archive extraction but not to recreate the proprietary RAR compression algorithm. Modified redistribution must retain the paragraph required by `LocalPackages/UnrarKit/license.txt`. |
| Foliate JS | `ThirdParty/foliate-js/` | MIT | [johnfactotum/foliate-js](https://github.com/johnfactotum/foliate-js), commit `6b11e1744346f60504b727984f7d42f0fef3ab54`. The runtime build disables publication scripts in two generated files. |
| zip.js | Foliate runtime | BSD-3-Clause | [gildas-lormeau/zip.js](https://github.com/gildas-lormeau/zip.js), version 2.7.52. The license is embedded in `FoliateRuntime.bundle`. |
| PDF.js | Foliate vendored source | Apache-2.0 | Copyright 2024 Mozilla Foundation. The PDF.js runtime files retain their license headers. |
| Adobe CMaps | Foliate vendored source | BSD-3-Clause-style terms | Copyright 1990-2009 Adobe Systems Incorporated. See `ThirdParty/foliate-js/vendor/pdfjs/cmaps/LICENSE`. |
| Foxit PDF standard fonts | Foliate vendored source | BSD-3-Clause | Copyright 2014 PDFium Authors. See `LICENSE_FOXIT`. |
| Liberation Sans fonts | Foliate vendored source | SIL Open Font License 1.1 | Copyright 2010 Google Corporation and 2012 Red Hat, Inc. Reserved font names apply. See `LICENSE_LIBERATION`. |
| Accessible DfA font | Readium resource bundle | SIL Open Font License 1.1 | Copyright Orange 2015, reserved font name Accessible-Dfa. The license is present in the Readium resource bundle. |
| IA Writer Duospace / IBM Plex-derived font | Readium resource bundle | SIL Open Font License 1.1 and Apache-2.0 portions | Copyright 2017 IBM. The license is present in the Readium resource bundle. |

## FluidAudio binary and model components

FluidAudio contains a prebuilt `NemoTextProcessing.xcframework` from [FluidInference/text-processing-rs](https://github.com/FluidInference/text-processing-rs) v0.3.0. The binary and its bundled grammars include Apache-2.0, MIT, or dual MIT/Apache-2.0 components, including NVIDIA NeMo Text Processing, rustfst, flate2, and their Rust dependency graph. FluidAudio also includes FastCluster under BSD-2-Clause-style terms and VBx under Apache-2.0. The source package's `ThirdPartyLicenses/` directory is the authoritative inventory.

Enve does not bundle the large TTS model weights in its source repository or application binary. Users may download these through FluidAudio at runtime:

- [Kokoro 82M Core ML](https://huggingface.co/FluidInference/kokoro-82m-coreml), Apache-2.0.
- [Supertonic 3 Core ML](https://huggingface.co/FluidInference/supertonic-3-coreml), derived from Supertone Supertonic 3. The upstream weights are under the BigScience OpenRAIL-M license, which contains use restrictions and downstream notice requirements. The Hugging Face metadata currently says `openrail++` while the model card and upstream license say OpenRAIL-M; treat the upstream OpenRAIL-M text as controlling unless the publisher clarifies otherwise.

Downloading or redistributing a model creates obligations separate from distributing the Enve source. A binary release must show the applicable model license and use restrictions before or with the model download.

## Bundled ambient recordings

The four ambient recordings under `enve/Resources/AmbientAudio/` are published under CC0 or an equivalent public-domain dedication by BigSoundBank / La Sonotheque. Attribution is not required, but is retained here for provenance.

| Bundled file | Recording | Author | Source |
|---|---|---|---|
| `ambient-rainfall.mp3` | Rain Under an Umbrella, sound 2679 | Pierre SIBANARCO | [BigSoundBank](https://bigsoundbank.com/rain-under-an-umbrella-s2679.html) |
| `ambient-fireplace.mp3` | Fireplace #5, sound 2857 | Joseph SARDIN | [BigSoundBank](https://bigsoundbank.com/fireplace-5-s2857.html) |
| `ambient-rainforest.mp3` | Forest, sound 0100 | Joseph SARDIN | [BigSoundBank](https://bigsoundbank.com/forest-s0100.html) |
| `ambient-ocean-waves.mp3` | Sea: Waves, sound 0266 | DenisChardonnet | [BigSoundBank](https://bigsoundbank.com/sea-waves-s0266.html) |

## Provider names and logos

Provider names and logos identify compatibility only. They do not imply sponsorship, partnership, or endorsement. All provider names and marks belong to their respective owners.

- Plex, the Plex Play logo, and Plex Media Server are trademarks of Plex and are used subject to the [Plex trademark guidelines](https://www.plex.tv/about/privacy-legal/plex-trademarks-and-guidelines/).
- The Komga icon is based on an icon by Freepik from Flaticon, as credited by the [Komga project](https://github.com/gotson/komga).
- Audiobookshelf, BookOrbit, Silo, Storyteller, Grimmory, Jellyfin, Kavita, Komga, Emby, Premiumize, Real-Debrid, TorBox, OPDS, and WebDAV names and logos are property of their respective owners.

The maintainer has confirmed that the bundled provider images are authorized for their current referential use in Enve. The detailed provenance and usage notes for each image are maintained in `docs/legal/THIRD_PARTY_AUDIT.md`. Redistribution must preserve the compatibility-only context, attribution, and no-endorsement statement.

## Distribution reminder

The public source repository is not itself a complete binary-distribution compliance package. Before distributing an app binary, the distributor must:

1. Bundle the complete required license and notice texts for every compiled dependency.
2. Make those notices reasonably accessible to users.
3. Fulfil LGPL source, modification, rebuilding, and relinking requirements for the exact distributed AMSMB2/libsmb2 build.
4. Present model license terms when optional model weights are downloaded.
5. Keep provider logos limited to their authorized identification and compatibility context, with applicable attribution and no suggestion of endorsement.
6. Preserve third-party license files in source archives and identify modifications where a license requires it.
