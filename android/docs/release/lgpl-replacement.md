# Replacing LGPL components

Build 45 contains two LGPL components. The public source snapshot published with the app contains Enve's corresponding application source, build scripts, JNI bridge, and the exact vendored libmobi source. The release evidence bundle contains the exact source archives and artifact digests.

## Requirements

- JDK 21
- Android SDK with API 36 and build tools 35.0.0
- Android NDK 27.2.12479018
- CMake 3.22.1 or newer
- an Android device with USB debugging enabled

Initialize the source checkout before building:

```sh
git submodule update --init --recursive
```

## libmobi 0.12

Enve builds libmobi as a separate `libmobi.so`. `libenve_mobi.so` declares `libmobi.so` as a required shared library; libmobi is not folded into the JNI bridge. The exact upstream revision and Enve integration changes are recorded in `engine/src/main/cpp/libmobi/PROVENANCE.md`.

To use a modified libmobi:

1. Replace `engine/src/main/cpp/libmobi/` with the modified source while preserving the CMake target name `mobi`, or modify the vendored source in place.
2. Keep `BUILD_SHARED_LIBS` enabled in `engine/src/main/cpp/CMakeLists.txt`.
3. Build an installable APK:

   ```sh
   ./gradlew --no-daemon :app:assembleDebug
   ```

4. A store-signed installation cannot be updated by a differently signed build. Back up any local Enve data you need, uninstall the store build, and install the replacement build:

   ```sh
   adb install app/build/outputs/apk/debug/app-debug.apk
   ```

5. Confirm that the APK contains `libmobi.so` and that the bridge still loads it:

   ```sh
   unzip -l app/build/outputs/apk/debug/app-debug.apk | grep 'libmobi.so'
   llvm-readobj --dynamic-table path/to/libenve_mobi.so | grep NEEDED
   ```

## jcifs-ng 2.1.10

The exact source release, license, commit, and archive digest are recorded under `BuildSupport/Jcifs/`. To build with a modified jcifs-ng:

1. Build the modified jcifs-ng 2.1.10 source with Maven.
2. Copy the resulting JAR into a new local directory in the Enve checkout.
3. Replace `implementation("eu.agno3.jcifs:jcifs-ng:2.1.10")` in `app/build.gradle.kts` with `implementation(files("path/to/modified-jcifs-ng.jar"))`.
4. Build and install the app using the APK steps above.

The Enve license permits the reverse engineering and relinking necessary to exercise rights granted by these third-party LGPL licenses. A replacement build must be signed with the builder's own key because Android will not accept it as an update to the Play-signed app.
