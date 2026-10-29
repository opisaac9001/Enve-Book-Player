# AZW3 verification

AZW3 files open directly in Foliate, including Grimmory downloads and local books. They bypass EPUB normalization and do not fall back to Readium. Other ebook formats retain their existing routing.

The Foliate runtime includes its pinned MOBI/KF8 parser and fflate for compressed Kindle fonts. Grimmory resources retain the original format and provider file ID for download and reading checkpoints.

Run the device regression suite on the Pixel 7a from the Android repository root:

```sh
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest :core:testDebugUnitTest
adb -s 34181JEHN24801 install -r app/build/outputs/apk/debug/app-debug.apk
adb -s 34181JEHN24801 install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb -s 34181JEHN24801 push engine/src/main/cpp/libmobi/tests/samples/sample-obfuscated-fonts.mobi /data/local/tmp/enve-kf8.azw3
adb -s 34181JEHN24801 shell am instrument -w -r -e class com.enve.app.document.Azw3SupportTest -e kindleFixturePath /data/local/tmp/enve-kf8.azw3 com.enve.app.debug.test/androidx.test.runner.AndroidJUnitRunner
adb -s 34181JEHN24801 shell rm /data/local/tmp/enve-kf8.azw3
```

The vendored fixture has a genuine KF8/version-8 header. The suite checks nested local-folder discovery, direct Foliate opening, page turning, saved-position restoration (including progress from the previous converted-EPUB reader), and the absence of a generated EPUB or Readium navigator. Its Grimmory fixture serves the original AZW3 over HTTP and verifies the AZW3 content request and provider file ID. The temporary fixture connection is removed afterward.

The two reader tests require `kindleFixturePath`; without it, they are skipped. A reader screenshot is saved in the debug app's cache as `azw3-reader-verification.png`.
