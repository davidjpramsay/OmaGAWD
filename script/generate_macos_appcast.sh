#!/bin/bash
# Generate the authenticated macOS feed after notarization, before publication.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:?Usage: generate_macos_appcast.sh macos-vVERSION-beta.N}"
APP="$ROOT_DIR/dist/release/OmaGAWD.app"
PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")
[[ "$TAG" == "macos-v$VERSION-beta."* && "${TAG##*-beta.}" =~ ^[0-9]+$ ]] || { echo "Tag does not match packaged macOS version $VERSION"; exit 2; }
ARCHIVE="$ROOT_DIR/dist/OmaGAWD-$VERSION-macOS-universal.dmg"
NOTES="$ROOT_DIR/macOS/updates/$VERSION.md"
TOOLS="$ROOT_DIR/macOS/.build/artifacts/sparkle/Sparkle/bin"
ACCOUNT="com.davidjpramsay.OmaGAWD.sparkle"
EXPECTED_KEY=$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$PLIST")
ACTUAL_KEY=$("$TOOLS/generate_keys" --account "$ACCOUNT" -p)
[[ "$ACTUAL_KEY" == "$EXPECTED_KEY" ]] || { echo "Update signing key does not match the packaged app"; exit 1; }
[[ -f "$ARCHIVE" && -f "$NOTES" ]] || { echo "Packaged DMG or release notes missing"; exit 1; }
xcrun stapler validate "$ARCHIVE"
STAGE=$(mktemp -d /tmp/omagawd-appcast.XXXXXX)
cleanup_stage() {
    python3 - "$STAGE" <<'PY'
import pathlib, shutil, sys
stage = pathlib.Path(sys.argv[1])
assert stage.parent == pathlib.Path('/tmp') and stage.name.startswith('omagawd-appcast.')
shutil.rmtree(stage)
PY
}
trap cleanup_stage EXIT
cp "$ARCHIVE" "$STAGE/"
cp "$NOTES" "$STAGE/$(basename "$ARCHIVE" .dmg).md"
"$TOOLS/generate_appcast" --account "$ACCOUNT" --maximum-versions 1 --maximum-deltas 0 \
    --download-url-prefix "https://github.com/davidjpramsay/OmaGAWD/releases/download/$TAG/" \
    --link "https://github.com/davidjpramsay/OmaGAWD/releases/tag/$TAG" \
    --embed-release-notes -o "$ROOT_DIR/macOS/updates/appcast.xml" "$STAGE"
"$TOOLS/sign_update" --account "$ACCOUNT" --verify "$ROOT_DIR/macOS/updates/appcast.xml"
echo "Signed feed ready: macOS/updates/appcast.xml"
