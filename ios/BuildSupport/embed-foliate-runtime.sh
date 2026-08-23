#!/bin/sh
set -eu

host_source="${SRCROOT}/BuildSupport/FoliateRuntime"
foliate_source="${SRCROOT}/ThirdParty/foliate-js"
bundle_destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/FoliateRuntime.bundle"
foliate_destination="${bundle_destination}/foliate"
license_destination="${bundle_destination}/licenses"

if [ ! -f "${foliate_source}/view.js" ]; then
    echo "error: Foliate submodule is missing. Run git submodule update --init --recursive."
    exit 1
fi

rm -rf "${bundle_destination}"
mkdir -p "${foliate_destination}/vendor" "${license_destination}"

for file in index.html reader.css adapter.js; do
    cp "${host_source}/${file}" "${bundle_destination}/${file}"
done

for file in \
    view.js \
    epub.js \
    fb2.js \
    mobi.js \
    epubcfi.js \
    progress.js \
    overlayer.js \
    text-walker.js \
    search.js \
    tts.js \
    footnotes.js
do
    cp "${foliate_source}/${file}" "${foliate_destination}/${file}"
done

for file in fixed-layout.js paginator.js; do
    sed \
        -e '/`allow-scripts` is needed/d' \
        -e '/bugs.webkit.org\/show_bug.cgi?id=218086/d' \
        -e 's/allow-same-origin allow-scripts/allow-same-origin/g' \
        "${foliate_source}/${file}" > "${foliate_destination}/${file}"
    if grep -q 'allow-scripts' "${foliate_destination}/${file}"; then
        echo "error: Publication scripts must remain disabled in ${file}."
        exit 1
    fi
done

cp "${foliate_source}/vendor/zip.js" "${foliate_destination}/vendor/zip.js"
cp "${foliate_source}/LICENSE" "${license_destination}/foliate-LICENSE.txt"
cp "${host_source}/zip.js-LICENSE.txt" "${license_destination}/zip.js-LICENSE.txt"
cp "${host_source}/UPSTREAM.txt" "${license_destination}/UPSTREAM.txt"

touch "${DERIVED_FILE_DIR}/foliate_runtime_embedded.stamp"
