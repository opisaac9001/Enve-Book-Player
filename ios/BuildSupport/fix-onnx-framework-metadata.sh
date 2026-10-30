#!/bin/sh
set -eu

case "${PLATFORM_NAME}" in
    iphoneos|iphonesimulator) ;;
    *) exit 0 ;;
esac

framework="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/onnxruntime.framework"
binary="${framework}/onnxruntime"
plist="${framework}/Info.plist"

# Xcode relinks this static package as a dylib but retains the package's older plist minimum.
minimum=$(/usr/bin/xcrun vtool -show-build "$binary" | /usr/bin/awk '$1 == "minos" { print $2; exit }')
test -n "$minimum"
declared=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$plist")
if [ "$declared" != "$minimum" ]; then
    /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $minimum" "$plist"
    test "$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$plist")" = "$minimum"
    if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier,entitlements "$framework"
    fi
fi
