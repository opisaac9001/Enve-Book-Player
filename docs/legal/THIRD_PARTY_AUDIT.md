# Third-Party Release Audit

Audit date: 2026-08-08

This is an engineering compliance inventory, not legal advice. It separates public source publication from distributing a signed application binary because the obligations are not identical.

## Current conclusion

The code, dependency source, and current provider artwork can be published with the existing license files and the root `THIRD_PARTY_NOTICES.md`. The maintainer confirms that the provider logos are authorized for their current identification and compatibility use in Enve. A signed binary is not ready for distribution as-is because most compiled-package notices are not bundled or exposed to users, the LGPL delivery plan is incomplete, and optional model terms are not presented at download time.

Enve's license prohibits commercial use, charging, advertising, and monetization. Those restrictions conflict with the Open Source Definition's free-redistribution and no-discrimination-against-fields-of-endeavor requirements. Public materials should describe Enve as **source-available**, not OSI open source. See the [Open Source Definition](https://opensource.org/osd).

## Dependency findings

### Cleared for source publication with retained notices

- The remote Swift packages have identifiable permissive licenses at their pinned revisions.
- Foliate JS is pinned to commit `6b11e1744346f60504b727984f7d42f0fef3ab54`; its MIT notice and the zip.js BSD notice are embedded into the generated runtime bundle.
- StoryAlign and its vendored ZIPFoundation copy retain MIT license files.
- UnrarKit and the UnRAR source retain both applicable license files.
- The Foliate PDF.js CMaps and standard fonts retain their component licenses.
- BigSoundBank confirms all four bundled ambient recordings are CC0 or public-domain equivalent at the recorded source URLs.

### Recorded local-package provenance

- AMSMB2 is an exact copy of release 4.0.3, commit `1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0`.
- The bundled libsmb2 directory is an exact copy of commit `aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03`, the submodule revision recorded by AMSMB2 4.0.3.
- The local RAR Swift package adapter is a project-local implementation rather than a vendored abbeycode/UnrarKit revision. Its 147 embedded RARLAB files exactly match portable source release 6.1.7, archive SHA-256 `de75b6136958173fdfc530d38a0145b72342cf0d3842bf7bb120d336602d88ed`, which implements binary and API version 6.12. RARLAB does not provide an authoritative Git revision for the release.
- FluidAudio is pinned by revision, but its binary target depends on a separately downloaded archive. Keep the v0.3.0 URL and checksum from FluidAudio's manifest in release records.

Package-level provenance records are stored beside AMSMB2 and the RAR adapter. FluidAudio's remote binary still needs to be captured in the release manifest so the shipped archive can be reproduced exactly.

## LGPL distribution finding

`LocalPackages/AMSMB2` compiles LGPL-2.1-or-later libsmb2 into a dynamically embedded `AMSMB2.framework`. The app then links that framework through `@rpath`.

For a distributed binary, retain the LGPL text, clearly identify libsmb2, provide the exact corresponding libsmb2 and wrapper source, identify modifications, and provide a practical rebuilding or relinking path for a modified compatible library. Publishing the complete Enve buildable source helps, but an App Store or other signed distribution still needs a deliberate compliance plan because recipients cannot replace a framework without rebuilding and re-signing the app.

Status: source publication can proceed; binary distribution requires a documented release procedure and preferably legal review.

## Optional model finding

Enve downloads Kokoro 82M and Supertonic 3 weights only when the user enables those enhanced voices.

- Kokoro is identified as Apache-2.0.
- Supertonic 3 is OpenRAIL-M and carries use restrictions plus redistribution notice requirements.
- FluidInference's Supertonic repository metadata and model card disagree between `openrail++` and OpenRAIL-M. The upstream Supertone repository supplies the OpenRAIL-M license text.

Status: add a model-license disclosure and acceptance surface before download. Record the exact model revision and license alongside every downloaded manifest.

## Provider asset inventory

Hash comparison was performed against the vendored reference repositories under `Other apps/`. A byte-for-byte origin is recorded only where the hashes match.

The maintainer confirmed on 2026-08-08 that every provider logo currently bundled by Enve is authorized for its present referential use. These marks remain the property of their respective owners and may only identify compatible services. This confirmation clears the artwork items below as release blockers; the remaining notes preserve provenance and attribution work.

| Asset | Evidence | Status before public release |
|---|---|---|
| Enve app, Watch, and tvOS icon assets | First-party Enve artwork derived from `BuildSupport/AppIcon/enve-book-player-icon.svg`, supplied by the maintainer on 2026-08-09. iOS and Watch app-icon slots use generated PNGs because Xcode warns on SVG app-icon files; tvOS brand/icon assets use SVG wrappers. | Cleared for source publication as first-party artwork. |
| Audiobookshelf | Exact match to `audiobookshelf/client/static/Logo.png`; upstream repository is GPL-3.0. | Authorized for current referential use; retain upstream identification. |
| BookOrbit | Exact match to `client/public/maskable-icon-512x512.png`; upstream repository is AGPL-3.0. | Authorized for current referential use; retain upstream identification. |
| Silo | Exact match to `web/public/silo-icon-1024.png`; upstream repository is AGPL-3.0. | Authorized for current referential use; retain upstream identification. |
| Komga | Upstream project is MIT, but its README credits the base icon to Freepik from Flaticon. | Authorized for current referential use; keep the Freepik credit and record the original license when found. |
| Plex | Plex publishes a compatibility-use license with presentation and attribution conditions. | Authorized for current referential use; preserve the required Plex attribution and presentation rules. |
| Emby | An Emby staff response says using the logo to identify an Emby Server connection is acceptable if the app does not imply Emby authorship. | Authorized for current referential use; preserve the no-endorsement statement. |
| Jellyfin | Jellyfin publishes separate branding guidance for third-party projects. | Authorized for current referential use by maintainer confirmation; preserve the compatibility-only context. |
| Kavita | Appears to be Kavita project artwork; upstream repository is GPL-3.0. Exact source file has not been recorded. | Authorized for current referential use; record the exact upstream file when identified. |
| Grimmory | Current light and dark images differ from the upstream 512 icon and appear to be Enve-specific variants; upstream repository is AGPL-3.0. | Authorized for current referential use; record how the variants were created. |
| Storyteller | Current 2048 image is not byte-identical to the official Storyteller logo in the vendored MIT repository. | Authorized for current referential use; record the transformation when identified. |
| Premiumize | Exact asset source is not recorded. | Authorized for current referential use; record the source when identified. |
| Real-Debrid | Exact asset source is not recorded. | Authorized for current referential use; record the source when identified. |
| TorBox | Exact asset source is not recorded. | Authorized for current referential use; record the source when identified. |
| OPDS | Generic image origin is not recorded. OPDS is a protocol, not a single provider. | Cleared for its current referential use; record its origin when identified. |
| WebDAV | Generic image origin is not recorded. WebDAV is a protocol, not a single provider. | Cleared for its current referential use; record its origin when identified. |

Relevant published policies:

- [Plex trademarks and guidelines](https://www.plex.tv/about/privacy-legal/plex-trademarks-and-guidelines/)
- [Jellyfin branding policy](https://jellyfin.org/docs/project/branding/)
- [Emby logo usage discussion](https://emby.media/community/topic/50879-logo-usage-guidelines/)
- [Komga repository and icon credit](https://github.com/gotson/komga)

## Binary notice gap

The current application bundle contains Foliate runtime notices and Readium font licenses. It does not contain a consolidated notice for Swift packages, libsmb2, UnRAR, FluidAudio's nested components, provider marks, or model downloads. There is no general acknowledgements screen in Settings.

Required remediation:

1. Generate a bundled license directory from the exact resolved dependency graph.
2. Add an Acknowledgements screen reachable from Settings.
3. Include the LGPL and UnRAR texts even when the related feature is not used by a particular user.
4. Present Kokoro and Supertonic terms before their first download.
5. Make the release process verify that notice files exist in the final archive.

## Recommended order

1. Add bundled acknowledgements and model disclosures.
2. Write and test the LGPL source/rebuild delivery procedure.
3. Record outstanding asset provenance as exact source files are identified.
4. Re-run the audit against a release archive rather than only the working tree.
