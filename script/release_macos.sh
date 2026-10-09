#!/bin/bash
# Signed, notarized universal distribution; does not publish to GitHub.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a saved notarytool Keychain profile}"
"$ROOT_DIR/script/build_and_run.sh" --package
APP="$ROOT_DIR/dist/release/OmaGAWD.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
OUT="$ROOT_DIR/dist/OmaGAWD-$VERSION-macOS-universal"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
# Sign the nested Sparkle helpers before the framework and host application.
for CODE in "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
            "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
            "$SPARKLE/Versions/B/Autoupdate" \
            "$SPARKLE/Versions/B/Updater.app" \
            "$SPARKLE"; do
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$CODE"
done
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$OUT-notary.zip"
xcrun notarytool submit "$OUT-notary.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$OUT-app-notary.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted", "App notarization failed"' "$OUT-app-notary.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
STAGE="$(mktemp -d /tmp/omagawd-dmg.XXXXXX)"
cleanup_stage() {
    python3 - "$STAGE" <<'PY'
import pathlib, shutil, sys
stage = pathlib.Path(sys.argv[1])
assert stage.parent == pathlib.Path('/tmp') and stage.name.startswith('omagawd-dmg.')
shutil.rmtree(stage)
PY
}
trap cleanup_stage EXIT
ditto "$APP" "$STAGE/OmaGAWD.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname OmaGAWD -srcfolder "$STAGE" -ov -format UDZO "$OUT.dmg"
codesign --timestamp --sign "$SIGNING_IDENTITY" "$OUT.dmg"
xcrun notarytool submit "$OUT.dmg" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$OUT-dmg-notary.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted", "DMG notarization failed"' "$OUT-dmg-notary.json"
xcrun stapler staple "$OUT.dmg"
xcrun stapler validate "$OUT.dmg"
hdiutil verify "$OUT.dmg"
(cd "$ROOT_DIR/dist" && shasum -a 256 "$(basename "$OUT.dmg")" > "$(basename "$OUT.dmg").sha256")
echo "Ready for publication: $OUT.dmg"
