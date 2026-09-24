#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-0.0.0-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
PLIST_VERSION="${VERSION%%-*}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/dist}"
APP_NAME="Docklet"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
ARCHIVE="$OUTPUT_DIR/$APP_NAME-$VERSION-macOS.zip"
CHECKSUM="$ARCHIVE.sha256"

if [[ ! "$VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
    echo "error: version must look like 1.0.0 or 1.0.0-beta.1" >&2
    exit 2
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "error: BUILD_NUMBER must contain only digits" >&2
    exit 2
fi

mkdir -p "$OUTPUT_DIR"

# Only remove the exact bundle and artifacts this script owns.
case "$APP_BUNDLE" in
    "$OUTPUT_DIR/$APP_NAME.app") ;;
    *) echo "error: refusing to clean unexpected bundle path: $APP_BUNDLE" >&2; exit 2 ;;
esac
rm -rf -- "$APP_BUNDLE"
rm -f -- "$ARCHIVE" "$CHECKSUM"

cd "$REPO_ROOT"
ARM_TRIPLE="arm64-apple-macosx13.0"
INTEL_TRIPLE="x86_64-apple-macosx13.0"

swift build -c release --triple "$ARM_TRIPLE" --product "$APP_NAME"
swift build -c release --triple "$INTEL_TRIPLE" --product "$APP_NAME"

ARM_BIN_DIR="$(swift build -c release --triple "$ARM_TRIPLE" --show-bin-path)"
INTEL_BIN_DIR="$(swift build -c release --triple "$INTEL_TRIPLE" --show-bin-path)"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
lipo -create \
    "$ARM_BIN_DIR/$APP_NAME" \
    "$INTEL_BIN_DIR/$APP_NAME" \
    -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod 755 "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
install -m 644 "$REPO_ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

PLIST="$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PLIST_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
plutil -lint "$PLIST"
lipo "$APP_BUNDLE/Contents/MacOS/$APP_NAME" -verify_arch arm64 x86_64

# Ad-hoc signing makes the bundle internally consistent but does not establish
# a verified developer identity or satisfy Gatekeeper on another Mac.
codesign --force --sign - --timestamp=none "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE"
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUM")"
)

echo "Packaged $APP_BUNDLE (arm64 + x86_64)"
echo "Created  $ARCHIVE"
echo "Created  $CHECKSUM"
