# Experimental build 54

## Source and artifact

- Version name: `1.2 build 54`
- Version code: `54`
- Package: `com.enve.app`
- Android source revision: `43acf90357da141ab0b5be94d9010e8988078714`
- Signed APK: `Enve-Book-Player-1.2-build-54.apk`
- SHA-256: `2175f6e78c7f8f003a09971f4778a2871798dd2d90b1d00e01800e1ff1daed86`
- The corresponding source is the `android/` tree in this PR. Signing material, IDE state, build products, private Git history, local configuration, and diagnostic reports are excluded.

## Verification

- Local debug, minified release, and app-bundle builds passed before the final version-only update.
- Release APK was rebuilt with version code 54 and signed through Android Studio.
- APK signature verification passed; its certificate matches the published build 53 APK.
- APK ZIP alignment, including 16 KB page alignment, passed.
- Bounded private-configuration, credential-pattern, and workstation-path scans passed.
- The uploaded APK digest matches the local artifact. The checksum is attached to the GitHub draft release.
- Scoped normal UI checks on a Pixel 7a confirmed the portrait ebook outline, unchanged audiobook circle, and the existing flat reader progress footer.
- Built-in test suites were not run during the latest verification pass at the maintainer's request. No hosted CI was requested.

## Export verification

- The public Android export independently passed `:app:assembleDebug`, `:app:assembleRelease`, `:app:verifyAcknowledgementsInventory`, and `:app:generateReleaseDependencyInventory` in 1m 14s, with no warning/error scan matches.
- Public-source provenance and staged privacy scans passed.
- Compared 1,420 production, build, and test files against the signed candidate's Android source revision; no content differences after line-ending normalization. Public repository guides and changelog history are retained.
- Installed the exported debug APK on Pixel 7a; cold launch, library navigation, opening the original narration EPUB fixture, and closing the reader succeeded. No fatal or Compose crash marker was observed in the bounded process-log check.
- The iOS tree, shared GitHub workflows, submodule configuration, and locked Grimmory readiness work are unchanged.

## Remaining checks

The full device/provider matrix, Android Auto owner test, and signed-candidate integration checks are incomplete. Source publication and a valid signature do not establish production readiness. Keep the candidate experimental pending the remaining release checklist.
