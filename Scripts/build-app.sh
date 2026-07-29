#!/usr/bin/env bash
#
# Assembles NotchPal.app from the SwiftPM build products.
#
# SwiftPM produces bare executables; a menu bar agent needs a bundle so that
# LSUIElement is honoured and the app has an identity macOS can remember.
#
#   ./Scripts/build-app.sh              debug-quality build into ./build
#   CONFIG=release ./Scripts/build-app.sh
#   UNIVERSAL=1 ./Scripts/build-app.sh  arm64 + x86_64
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="NotchPal"
BUNDLE_ID="app.notchpal.NotchPal"
VERSION="${VERSION:-1.0.0}"
BUILD_DIR="${BUILD_DIR:-build}"
APP="${BUILD_DIR}/${APP_NAME}.app"

BUILD_FLAGS=(-c "${CONFIG}")
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi

echo "▸ Building (${CONFIG}${UNIVERSAL:+, universal})"
swift build "${BUILD_FLAGS[@]}"
BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

echo "▸ Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BIN_PATH}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "${BIN_PATH}/notchpal-report" "${APP}/Contents/MacOS/notchpal-report"

if [[ -f "Resources/AppIcon.icns" ]]; then
  cp "Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
  ICON_ENTRY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  ICON_ENTRY=""
fi

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    ${ICON_ENTRY}
    <!-- A status item, not a Dock app. -->
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Source-available. Sale prohibited by the license. Trademarks belong to their owners.</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough for local use; replace with a Developer ID identity
# (CODESIGN_IDENTITY=...) before distributing a build to anyone else.
IDENTITY="${CODESIGN_IDENTITY:--}"
echo "▸ Signing with identity: ${IDENTITY}"

# Clear extended attributes first. macOS stamps `com.apple.provenance` on
# binaries it has seen, and that attribute makes bundle-level verification fail
# with "Operation not permitted" on the nested executable even though the
# executable verifies fine on its own.
xattr -cr "${APP}"

codesign --force --sign "${IDENTITY}" --timestamp=none "${APP}/Contents/MacOS/notchpal-report"
codesign --force --sign "${IDENTITY}" --timestamp=none "${APP}"

# Fail loudly here rather than shipping something that dies with SIGKILL on
# someone else's Mac.
codesign --verify --verbose=2 "${APP}"

# Package.
#
# `ditto -c -k --keepParent` is the form Apple documents for a signed bundle.
# Do NOT add --sequesterRsrc: it writes the bundle's extended attributes into
# __MACOSX sidecar entries, and Finder does not restore them faithfully on
# extraction. The signature then fails to validate and macOS kills the app at
# launch with "Code Signature Invalid" — which is exactly what shipped in 1.1.0.
ZIP="${BUILD_DIR}/${APP_NAME}-${VERSION}.zip"
echo "▸ Packaging ${ZIP}"
rm -f "${ZIP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"

if unzip -l "${ZIP}" | grep -q "__MACOSX"; then
  echo "✗ Archive contains __MACOSX sidecars — the signature will not survive extraction." >&2
  exit 1
fi

# Round-trip the archive and check the signature actually survived, because a
# valid signature on disk says nothing about what the user unzips.
VERIFY_DIR="${BUILD_DIR}/.verify"
rm -rf "${VERIFY_DIR}"
mkdir -p "${VERIFY_DIR}"
ditto -x -k "${ZIP}" "${VERIFY_DIR}"
codesign --verify --verbose=2 "${VERIFY_DIR}/${APP_NAME}.app"
rm -rf "${VERIFY_DIR}"

echo "▸ Done: ${APP}"
echo "▸ Done: ${ZIP}  ($(shasum -a 256 "${ZIP}" | cut -d' ' -f1))"
