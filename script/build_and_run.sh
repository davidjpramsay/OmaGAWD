#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
CONFIG="debug"
if [[ "$MODE" == "--release" ]]; then CONFIG="release"; MODE="run"; fi
if [[ "$MODE" == "--package" ]]; then CONFIG="release"; fi
case "$MODE" in run|--verify|--build|--package|--debug|--logs|--telemetry) ;; *) echo "Usage: $0 [--release|--build|--verify|--debug|--logs|--telemetry]"; exit 2 ;; esac
if [[ "$MODE" != "--build" && "$MODE" != "--package" ]]; then pkill -x OmaGAWD >/dev/null 2>&1 || true; fi
BUILD_ARGS=(--package-path "$ROOT_DIR/macOS" -c "$CONFIG")
if [[ "$MODE" == "--package" ]]; then BUILD_ARGS+=(--arch arm64 --arch x86_64); fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BUNDLE="$ROOT_DIR/dist/OmaGAWD.app"
if [[ "$MODE" == "--package" ]]; then BUNDLE="$ROOT_DIR/dist/release/OmaGAWD.app"; fi
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$BUNDLE/Contents/Frameworks"
ditto "$ROOT_DIR/macOS/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$BUNDLE/Contents/Frameworks/Sparkle.framework"
cp "$ROOT_DIR/macOS/.build/artifacts/sparkle/Sparkle/LICENSE" "$BUNDLE/Contents/Resources/Sparkle-LICENSE.txt"
cp "$BIN_DIR/OmaGAWD" "$BUNDLE/Contents/MacOS/OmaGAWD"
cp "$ROOT_DIR/macOS/Resources/OmaGAWD.icns" "$ROOT_DIR/macOS/Resources/MenuBarIcon.png" "$ROOT_DIR/macOS/Resources/MenuBarIcon@2x.png" "$BUNDLE/Contents/Resources/"
cp "$ROOT_DIR/assets/llama.svg" "$BUNDLE/Contents/Resources/MenuBarIcon.svg"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OmaGAWD</string>
<key>CFBundleIdentifier</key><string>com.davidjpramsay.OmaGAWD</string>
<key>CFBundleName</key><string>OmaGAWD</string>
<key>CFBundleDisplayName</key><string>OmaGAWD</string>
<key>CFBundleIconFile</key><string>OmaGAWD.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>5</string>
<key>SUFeedURL</key><string>https://raw.githubusercontent.com/davidjpramsay/OmaGAWD/main/macOS/updates/appcast.xml</string>
<key>SUPublicEDKey</key><string>EzFhESUgTxUaAol4RkNAGyt4LoUsgD6sGWGx4wO9s4Q=</string>
<key>SUEnableAutomaticChecks</key><false/>
<key>SUAllowsAutomaticUpdates</key><false/>
<key>SUEnableSystemProfiling</key><false/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$BUNDLE" >/dev/null
case "$MODE" in
 --build|--package) echo "Built $BUNDLE" ;;
 --debug) lldb -- "$BUNDLE/Contents/MacOS/OmaGAWD" ;;
 --logs|--telemetry) open -n "$BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "OmaGAWD"' ;;
 --verify) open -n "$BUNDLE"; sleep 1; pgrep -x OmaGAWD ;;
 *) open -n "$BUNDLE" ;;
esac
