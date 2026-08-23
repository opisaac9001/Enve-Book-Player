# Android Third-Party Release Audit

Audited 2026-08-10 against the repository and Gradle configuration on `main`.

This is a release checklist, not legal advice. It separates source publication from binary distribution because an APK has obligations that a source repository alone does not satisfy.

## Current conclusion

The source repository can be published under the Enve Noncommercial Public Source License because `LICENSE.md` excludes third-party materials and preserves their separate rights. A public APK or app bundle is not ready for distribution yet.

The binary blockers are:

1. Add an in-app acknowledgements screen reachable from Settings and include all license and NOTICE texts present in the resolved release artifact.
2. Choose and document a compliant LGPL-3.0-or-later distribution method for statically linked libmobi. Provide the exact libmobi source, Enve application code or usable object/relinking materials, build instructions, and installation information needed to replace the library.
3. Provide LGPL-2.1 notice and corresponding source for jcifs-ng 2.1.10, and verify whether the packaged form requires additional relinking material.
4. Generate a complete release dependency and license inventory, including transitive AAR/JAR contents and native libraries. The current root notice covers direct dependencies only.
5. Verify the terms and privacy disclosures for ML Kit GenAI, LiteRT-LM, Google Cast, Play services, and Play Billing for the intended distribution channel.
6. Identify and present the license for every model Enve offers, downloads, hosts, or bundles. No model may be redistributed from its framework license alone.
7. Audit the final APK and app bundle for embedded license files, unexpected assets, native objects, debug metadata, credentials, private URLs, and build paths.

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
- [ ] Record an authoritative upstream commit or release archive hash for the vendored libmobi 0.12 tree.
- [ ] Record the authoritative whisper.cpp v1.8.4 commit and verify the vendored file set against it.
- [ ] Record the exact upstream file or documented transformation for every non-Grimmory provider logo.

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

Keep that bundle available for at least the period required by the applicable licenses and by section 6 of the Enve license.

## License compatibility notes

The Enve license's noncommercial and advertising restrictions apply only to Enve-owned material. They do not restrict rights granted in libmobi, jcifs-ng, Foliate, AndroidX, or other third-party components.

LGPL recipients must retain the right to modify the covered library and debug those modifications. The Enve license explicitly grants the minimum reverse-engineering and relinking permission necessary for third-party compliance, but a distributor still has to provide the practical materials required by the LGPL.

Google SDK and model terms may impose service, telemetry, account, privacy, or acceptable-use conditions. Those terms are not converted into the Enve license and must be evaluated for the actual release channel.

## Release gate

Do not publish an APK or app bundle until every binary blocker above is closed against the exact artifact being distributed. Publishing source first does not authorize a later binary release automatically.
