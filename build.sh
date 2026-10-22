#!/bin/bash
# Builds DiskWidget.app as a universal (Apple Silicon + Intel) bundle.
#
#   ./build.sh                       ad-hoc signed, fine for your own Mac
#   VERSION=1.2.0 ./build.sh         stamp a version into the bundle
#   DEVELOPER_ID="Developer ID Application: You (TEAMID)" ./build.sh
#                                    properly signed, ready to notarize
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
APP="$BUILD/DiskWidget.app"

VERSION="${VERSION:-1.0.0}"
# Two OS versions back, so the release covers current and N-1 comfortably.
DEPLOYMENT_TARGET="13.0"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS"

for arch in arm64 x86_64; do
    swiftc -O -framework Cocoa \
        -target "${arch}-apple-macos${DEPLOYMENT_TARGET}" \
        -o "$BUILD/DiskWidget-${arch}" \
        "$DIR/main.swift"
done

lipo -create -output "$APP/Contents/MacOS/DiskWidget" \
    "$BUILD/DiskWidget-arm64" "$BUILD/DiskWidget-x86_64"
rm -f "$BUILD/DiskWidget-arm64" "$BUILD/DiskWidget-x86_64"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DiskWidget</string>
    <key>CFBundleIdentifier</key><string>local.diskwidget</string>
    <key>CFBundleName</key><string>DiskWidget</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>${DEPLOYMENT_TARGET}</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
    echo "Signed with: $DEVELOPER_ID"
else
    codesign --force --sign - "$APP"
    echo "Ad-hoc signed (not distributable without Gatekeeper warnings)."
fi

codesign --verify --strict "$APP"

# ditto, not zip — it preserves the bundle's symlinks and metadata.
ZIP="$BUILD/DiskWidget-${VERSION}-universal.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Built  $APP"
echo "Zipped $ZIP"
lipo -archs "$APP/Contents/MacOS/DiskWidget"
