# Readium LCP integration

This is the handoff contract for adding production Readium LCP support to Enve Book Player for iOS after EDRLab supplies the private client framework. Do not add a project reference to a missing private artifact: the normal source checkout must continue to build before and without LCP credentials.

## EDRLab intake

Request a test-grade iOS reading-system package for:

| Field | Enve value |
| --- | --- |
| Application | Enve Book Player |
| Platform | iOS 17 and newer |
| Bundle identifier | `com.enve.enve` |
| Readium toolkit | Swift Toolkit 3.11.0 through Swift Package Manager |
| Required private component | `R2LCPClient` for device and Apple-silicon Simulator testing |
| Initial publication scope | LCP-protected EPUB and `.lcpl` acquisition |
| Catalog path | OPDS 1.2 and OPDS 2.0 |
| Distribution role | Reading system only; Enve does not issue LCP licenses |

Ask EDRLab to confirm the supported Xcode and Swift versions, the exact framework packaging, production-profile replacement procedure, required robustness rules, and certification test corpus before changing the Xcode project.

Private EDRLab artifacts belong under `BuildSupport/Private/ReadiumLCP/`, which is ignored by Git. They must not enter the public source snapshot, archives, logs, diagnostics, or release documentation. Public Readium dependencies, Enve integration source, notices, and reproducible instructions remain publishable unless the EDRLab agreement says otherwise.

## Existing readiness

- The app resolves Readium Swift Toolkit 3.11.0 and already links `ReadiumShared`, `ReadiumStreamer`, and `ReadiumNavigator`.
- `ReaderPublicationSession` owns the interactive EPUB `AssetRetriever` and `PublicationOpener` used by the reader.
- OPDS parsing recognizes the LCP license media types and preserves the acquisition instead of treating the LCPL response as an EPUB.
- OPDS selection tests cover LCP rejection today, providing the test boundary to change when the private module is installed.
- The app already permits the HTTP transport needed by the Readium certificate-revocation endpoint through its intentional `NSAllowsArbitraryLoads` policy.

## Integration sequence

1. Place the test-grade `R2LCPClient` artifact under the ignored private directory and follow EDRLab's signing and embedding instructions.
2. Add the `ReadiumLCP` product from the existing Readium Swift package and link the private client only to the iOS app target.
3. Add one app-owned `LCPService` using `LCPClientAdapter`, `LCPKeychainLicenseRepository`, `LCPKeychainPassphraseRepository`, and the same `AssetRetriever` used for acquisition.
4. Inject `lcpService.contentProtection(with:)` into the `PublicationOpener` owned by `ReaderPublicationSession` and open reader publications with user interaction allowed.
5. Use `LCPObservableAuthentication` with the SwiftUI `LCPDialog` at the reader presentation boundary. Do not store or log passphrases in Enve state.
6. Add a focused acquisition service under `enve/Services/Reader/` that downloads an LCPL with the connection-aware OPDS transport, acquires the encrypted publication, and stores the protected package in app-private persistent storage.
7. Change the OPDS acquisition selector so Readium LCP is actionable through that service while Adobe and Audible DRM remain unsupported.
8. Register `.lcpl` as an imported document type and route it to the same acquisition service. Do not add the license document itself as a library book.
9. Force LCP publications through Readium and block paths that parse, convert, extract, repackage, or export the raw EPUB archive.
10. Surface `Publication.isRestricted`, `protectionError`, loan expiry, remaining copy allowance, return, and renewal through the reader and book-detail UI.

## Protected-content boundaries

Until a path has been reviewed against the license rights and EDRLab robustness rules, LCP publications must not enter:

- StoryAlign generation or read-aloud EPUB rebuilding
- Enve Librarian full-book extraction
- KOReader hashing, XPointer conversion, or export
- direct ZIP parsing through `EPUB3SMILParser`
- MOBI/EPUB conversion or repackaging
- persistent plaintext search or passage caches
- Foliate or any renderer outside the Readium content-protection pipeline

Do not persist decrypted publication resources. Copy and print operations must enforce the license allowance. An expired, revoked, or otherwise restricted publication is a license error and must not be deleted as a corrupt download.

## Device identity and storage

Initialize `LCPService` with an Enve-owned, non-personal device name unless Apple approves the user-assigned-device-name entitlement. Keep license and passphrase repositories in Keychain with synchronization disabled unless cross-device synchronization is explicitly reviewed and approved.

The acquired encrypted publication belongs in persistent application storage, not a purgeable reader cache. The private client framework and production root certificate are release-sensitive inputs; protected publications and LCP state must be excluded from diagnostics and public-source exports.

## Verification gate

Before enabling LCP in a production build:

- Open EDRLab test publications with correct, incorrect, and previously remembered passphrases.
- Verify imported LCPL and authenticated OPDS acquisition paths.
- Verify offline reopening, app restart, reinstall behavior, expiry, revocation, return, and renewal.
- Verify copy limits and every protected-content boundary above.
- Build and test the `enve` scheme on an Apple-silicon Simulator and a physical iPhone.
- Confirm release signing, archive validation, symbol handling, and zero private artifacts in the public source snapshot.
- Run `./scripts/verify-provenance` and complete EDRLab certification before replacing the test client with the production client.

## Completion definition

The integration is complete only when the test-grade client passes Enve's automated and device tests, the production client passes the same suite, EDRLab certification succeeds, and the shipped binary contains no test root or test-grade LCP component.
