# Production release checklist

Use this checklist for Enve 1.2 build 46. A production release is ready only when every gate is complete against the same source revision and signed app bundle.

## Repository gate

- [x] App and Wear version codes match at 46.
- [x] Target SDK is 36 and native libraries satisfy 16 KB page alignment.
- [x] Privacy and website links use `https://envemedia.com`.
- [x] In-app acknowledgements include the resolved release inventory and bundled legal documents.
- [x] Downloadable Qwen and Whisper models are revision-pinned and SHA-256 verified.
- [x] libmobi, whisper.cpp, jcifs-ng, model, and provider-logo provenance are recorded.
- [x] LGPL replacement and installation instructions are published.
- [x] Release lint passes for the phone and Wear apps.
- [x] Complete the local gate and connected-device suite. The final clean-checkout rerun remains part of signed-candidate production evidence:

  ```sh
  ./scripts/verify-provenance
  ./gradlew --no-daemon test :app:verifyAcknowledgementsInventory :app:generateReleaseDependencyInventory :app:lintRelease :wear:lintRelease :app:assembleDebug :wear:assembleDebug :app:assembleRelease :wear:assembleRelease :app:bundleRelease :wear:bundleRelease
  ./gradlew --no-daemon :app:connectedDebugAndroidTest
  ```

## Signed candidate and evidence

- [ ] Produce Play-signed app and Wear bundles from the reviewed source revision.
- [ ] Run the production evidence builder with the matching public commit and signed bundles:

  ```sh
  ENVE_PUBLIC_SOURCE_REVISION=<public-commit> \
  ENVE_APP_BUNDLE=<signed-app.aab> \
  ENVE_WEAR_BUNDLE=<signed-wear.aab> \
  ENVE_ZIPALIGN=<android-sdk>/build-tools/35.0.0/zipalign \
  ENVE_LLVM_READOBJ=<android-ndk>/toolchains/llvm/prebuilt/<host>/bin/llvm-readobj \
  ./scripts/build-release-evidence production
  ```

- [ ] Confirm both signatures verify, the sensitive/build-path scan is empty, and `SHA256SUMS` matches.
- [ ] Retain the evidence bundle, mapping files, native symbols, and corresponding source archives with the release tag.

## Public source gate

- [ ] Export the complete publishable Android source to `opisaac9001/Enve-Book-Player/android/`.
- [ ] Confirm Android Auto source, manifest entries, resources, and tests are present in that snapshot.
- [ ] Review the full public diff and confirm no credentials, signing material, local configuration, diagnostics, or user data are present.
- [ ] Build, lint, and test the public snapshot independently.
- [ ] Record the private revision, public revision, and signed artifact digest in release evidence.

## Manual and hardware gate

- [ ] Complete `docs/testing/manual-test-plan.md` on the Pixel 7a with clean runtime logs.
- [ ] Test Android Auto on a compatible vehicle or Desktop Head Unit.
- [ ] Test the Wear companion on a physical Wear OS device.
- [ ] Test remote and downloaded playback on physical Cast hardware.
- [ ] Verify Health Connect permission grant, denial, revocation, 30-day sleep access, and data deletion behavior.
- [ ] Verify each promoted server integration with a real account; include Komga reading direction with an affected library.
- [ ] Exercise Qwen, Whisper, and Gemini Nano setup on supported hardware, including cancellation, corrupt-download rejection, and model removal.

## Website and Play Console gate

- [ ] Publish the updated privacy pages and verify `https://envemedia.com/privacy-policy` from a phone and desktop browser.
- [ ] Complete the Google Play Data safety form using the actual SDK and network behavior documented by the privacy policy.
- [ ] Complete the Health apps declaration and justify `READ_SLEEP`; include the required privacy-policy link and screenshots or video.
- [ ] Verify app access instructions, ads declaration, content rating, target audience, store category, contact details, and support URL.
- [ ] Upload current phone, tablet, Android Auto, and Wear screenshots that contain no private library or account data.
- [ ] Configure the tip-jar product described in `play-tip-jar.md` and test it through Play licensing.
- [ ] Upload the signed candidate to internal testing and review automated device, accessibility, stability, and pre-launch reports.

## Rollout gate

- [ ] Resolve every blocker from internal testing and regenerate evidence if the binary changes.
- [ ] Promote the unchanged artifact through closed or open testing as required by the account.
- [ ] Start a staged production rollout and monitor Android vitals, crashes, ANRs, reviews, playback failures, and sign-in failures.
- [ ] Pause the rollout if a release-blocking regression appears; expand only after the observation window is clean.
- [ ] Tag the exact private and public source revisions used by the released artifact.
