# Readium LCP integration

This is the handoff contract for adding production Readium LCP support to Enve Book Player for Android after EDRLab supplies the private client library. Do not add a Gradle dependency on a missing private artifact: the normal source checkout must continue to build before and without LCP credentials.

## EDRLab intake

Request a test-grade Android reading-system package for:

| Field | Enve value |
| --- | --- |
| Application | Enve Book Player |
| Platform | Android 8.0/API 26 and newer |
| Application identifier | `com.enve.app` |
| Readium toolkit | Kotlin Toolkit 3.3.0 from Maven Central |
| Required private component | `liblcp` with `arm64-v8a` support |
| Initial publication scope | LCP-protected EPUB and `.lcpl` acquisition |
| Catalog path | OPDS 1.2 and OPDS 2.0 |
| Distribution role | Reading system only; Enve does not issue LCP licenses |

Ask EDRLab to confirm the supported Android Gradle Plugin, Kotlin, NDK, and compile SDK versions, the exact AAR packaging, production-profile replacement procedure, required R8 rules, robustness rules, and certification test corpus before changing Gradle dependencies.

Private EDRLab artifacts belong under `BuildSupport/Private/ReadiumLCP/`, which is ignored by Git. They must not enter the public source snapshot, archives, logs, diagnostics, or release documentation. Public Readium dependencies, Enve integration source, notices, and reproducible instructions remain publishable unless the EDRLab agreement says otherwise.

## Existing readiness

- The engine already uses aligned Readium 3.3.0 `shared`, `streamer`, and `navigator` artifacts.
- `ReadiumManager` centralizes the reader's `AssetRetriever` and `PublicationOpener`.
- OPDS parsing recognizes LCP license media types and persists the DRM classification instead of treating the LCPL response as an EPUB.
- OPDS parser, acquisition selection, option, and persistence tests cover LCP rejection today, providing the test boundary to change when the private module is installed.
- The app already permits user-configured HTTP endpoints and ships only `arm64-v8a` native code.

## Integration sequence

1. Place the test-grade `liblcp` artifact under the ignored private directory and follow EDRLab's packaging instructions.
2. Add `org.readium.kotlin-toolkit:readium-lcp:3.3.0` and the private library to `:engine`, keeping every Readium module on the same version.
3. Extend `ReadiumManager` with one `LcpService`, authentication implementation, and LCP content protection for its `PublicationOpener`.
4. Use the Activity-hosted LCP authentication dialog in `EbookReaderActivity` and open reader publications with user interaction allowed. Do not store or log passphrases in Enve state.
5. Add a focused `LcpAcquisitionService` under `:engine` that downloads an LCPL with the connection-aware OPDS transport, acquires the encrypted publication, and stores the protected package in app-private persistent storage.
6. Expose acquisition progress, license errors, loan state, return, and renewal through `:engine-api`; `:hearth-ui` must not import Readium or the private client.
7. Change OPDS acquisition selection so Readium LCP is actionable through that service while Adobe DRM remains unsupported.
8. Register `.lcpl` and `application/vnd.readium.lcp.license.v1.0+json` with Android document handling and route them to the same acquisition service. Do not add the license document itself as a library book.
9. Mark the acquired book as LCP-protected, force `ReaderEngineKind.READIUM`, and bypass Foliate and raw ZIP inspection.
10. Check `Publication.isRestricted` and `protectionError` before creating a navigator; do not delete restricted publications as corrupt files.

## Protected-content boundaries

Until a path has been reviewed against the license rights and EDRLab robustness rules, LCP publications must not enter:

- StoryAlign generation or read-aloud EPUB rebuilding
- Enve Librarian full-book extraction
- KOReader hashing, XPointer conversion, or export
- direct `ZipFile` inspection
- MOBI/EPUB conversion or repackaging
- persistent plaintext search or passage caches
- Foliate or any renderer outside the Readium content-protection pipeline

Do not persist decrypted publication resources. Copy and print operations must enforce the license allowance. An expired, revoked, or otherwise restricted publication is a license error and must not be deleted as a corrupt download.

## Storage and backup

The acquired encrypted publication belongs in persistent app-private storage, not the purgeable reader cache. Before shipping, add the exact LCP database, repository, and protected-publication paths to both `res/xml/backup_rules.xml` and `res/xml/backup_rules_v31.xml` so neither cloud backup nor device transfer exports LCP state.

Keep `liblcp`, production certificates, passphrases, license payloads, and protected publications out of logs, diagnostics, test fixtures, screenshots, and public-source exports. A minified release build is required because missing LCP consumer rules or native symbols can appear only under R8.

## Verification gate

Before enabling LCP in a production build:

- Open EDRLab test publications with correct, incorrect, and previously remembered passphrases.
- Verify imported LCPL and authenticated OPDS acquisition paths.
- Verify offline reopening, process death, app restart, expiry, revocation, return, and renewal.
- Verify copy limits and every protected-content boundary above.
- Run unit tests, `:app:assembleDebug`, `:app:assembleRelease`, and connected tests for Android integration changes.
- Install the release-equivalent build on the Pixel 7a and inspect logcat for native loading, license, and secret-leak failures.
- Run `./scripts/verify-provenance` and complete EDRLab certification before replacing the test client with the production client.

## Completion definition

The integration is complete only when the test-grade client passes Enve's automated and Pixel tests, the production client passes the same suite, EDRLab certification succeeds, and the shipped APK or app bundle contains no test root or test-grade LCP component.
