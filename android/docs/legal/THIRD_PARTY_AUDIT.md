# Android Third-Party Release Audit

Audited 2026-08-29 against the repository and Gradle configuration on `main`.

This is a release checklist, not legal advice. It separates source publication from binary distribution because an APK has obligations that a source repository alone does not satisfy.

## Current conclusion

The source repository can be published under the Enve Noncommercial Public Source License because `LICENSE.md` excludes third-party materials and preserves their separate rights. The repository-level licensing work is complete; a public APK or app bundle remains gated on verification of the exact signed release candidate and its matching public source snapshot.

The remaining binary release gates are:

1. Generate the release evidence bundle from the exact signed candidate and confirm its artifact digests, signature, dependency inventory, native libraries, notices, and source archives.
2. Audit the final APK and app bundle for unexpected assets, debug metadata, credentials, private URLs, and build paths.
3. Verify the current Google SDK and service terms for ML Kit GenAI, LiteRT-LM, Google Cast, Play services, and Play Billing, then make the matching Google Play Data safety and Health apps declarations.
4. Publish and independently build the public source snapshot that corresponds to the production binary, including Android Auto and every other shipped feature.
5. Complete the required physical-device, Android Auto, Wear OS, Cast, and server-integration checks listed in the release checklist.

## Source repository checks

- [x] Root Enve license distinguishes original and third-party material.
- [x] Root notice carries an Android-specific provenance identifier.
- [x] Foliate is pinned as a Git submodule and its runtime is built from an allowlist.
- [x] Foliate and zip.js licenses are copied into generated assets.
- [x] libmobi carries the full LGPL-3.0 text in `engine/src/main/cpp/libmobi/COPYING`.
- [x] whisper.cpp carries its MIT license.
- [x] Grimmory assets include their asset and trademark terms.
- [x] Build outputs, local SDK paths, keystores, IDE state, and `.agent-lock` are ignored.
- [x] Tracked raster assets were checked for embedded creator, location, AI-tool, C2PA-style text, and other identifying metadata. None was found by the local inspection tools.
- [x] Removed the commercial *Isles of the Emberdark* EPUB test fixture. The remaining StoryAlign EPUB fixtures identify themselves as Project Gutenberg public domain and Standard Ebooks public domain/CC0 material.
- [x] Removed the obsolete website/store screenshots containing third-party book covers and visible library data.
- [x] The maintainer confirmed that bundled provider logos are authorized for their current identification and compatibility use in Enve.
- [x] Record an authoritative upstream commit and source archive hash for the vendored libmobi 0.12 tree, including the exact Enve integration changes.
- [x] Record the authoritative whisper.cpp v1.8.4 commit and verify every vendored upstream file by Git blob hash.
- [x] Record every non-Grimmory provider-logo file digest and its unchanged transfer from the owner-authorized Enve iOS asset set.

## Completed binary-preparation work

- [x] In-app acknowledgements are reachable from About and contain the resolved release dependency inventory plus bundled legal and provenance documents.
- [x] `verifyAcknowledgementsInventory` fails the build when a resolved release module is missing from the in-app inventory.
- [x] `generateReleaseDependencyInventory` records each resolved release artifact and SHA-256 digest.
- [x] libmobi is packaged as a separate `libmobi.so`; exact corresponding source, rebuild, replacement, signing, and installation instructions are documented.
- [x] jcifs-ng 2.1.10 has exact source, commit, archive digest, license, replacement, and installation information.
- [x] Offered Qwen3 0.6B and Whisper tiny.en downloads are revision-pinned, size-checked, SHA-256 verified, and documented with their licenses.
- [x] Model download terms are presented before Enve-managed downloads, and all model notices remain available in-app.
- [x] The public privacy policy describes Health Connect sleep access, Google SDK behavior, and model downloads.

## Binary distribution package

A release evidence bundle should contain:

- the source tag matching the binary
- `LICENSE.md`, `NOTICE.md`, and `THIRD_PARTY_NOTICES.md`
- the exact resolved Gradle dependency graph
- the complete generated acknowledgements inventory
- all required Apache NOTICE, BSD, MIT, EPL, LGPL, GPL, font, model, and SDK notices
- the exact libmobi and jcifs-ng corresponding source archives
- libmobi relinking or rebuild materials plus tested instructions
- any installation information required to install a relinked build
- model cards, licenses, and accepted-use restrictions for distributed or offered models
- privacy disclosures covering ML Kit and other SDK data behavior
- a report from inspecting the final APK and app bundle
- the private source revision, matching public source revision, and confirmation that Android Auto is present in the public snapshot

Keep that bundle available for at least the period required by the applicable licenses and by section 6 of the Enve license.

## License compatibility notes

The Enve license's noncommercial and advertising restrictions apply only to Enve-owned material. They do not restrict rights granted in libmobi, jcifs-ng, Foliate, AndroidX, or other third-party components.

LGPL recipients must retain the right to modify the covered library and debug those modifications. The Enve license explicitly grants the minimum reverse-engineering and relinking permission necessary for third-party compliance, but a distributor still has to provide the practical materials required by the LGPL.

Google SDK and model terms may impose service, telemetry, account, privacy, or acceptable-use conditions. Those terms are not converted into the Enve license and must be evaluated for the actual release channel.

## Release gate

Do not publish an APK or app bundle until every binary blocker above is closed against the exact artifact being distributed. Publishing source first does not authorize a later binary release automatically.
