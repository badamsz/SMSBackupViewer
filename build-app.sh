#!/bin/bash
# Builds "SMS Backup Viewer.app" (with the bundled smsbackup-mcp server) into ./build.
#   ./build-app.sh             build for this Mac's architecture
#   ./build-app.sh --universal build arm64 + x86_64
#   ./build-app.sh --install   also copy the app to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SMS Backup Viewer"
BUNDLE_ID="local.smsbackupviewer.app"
VERSION="1.0.0"
UNIVERSAL=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg"; exit 2 ;;
  esac
done

if ! command -v swift >/dev/null; then
  echo "Swift not found. Install Xcode from the App Store and try again."; exit 1
fi

# SwiftUI's @State is a compiler macro in current SDKs, and its plugin (SwiftUIMacros) ships only
# with Xcode, not the Command Line Tools. If the active developer dir is the CLT, use Xcode instead.
DEV_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
  XCODE_APP="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -n 1)"
  [[ -z "$XCODE_APP" && -d /Applications/Xcode.app ]] && XCODE_APP=/Applications/Xcode.app
  if [[ -n "$XCODE_APP" ]]; then
    export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
    echo "==> Using Xcode at $XCODE_APP (the Command Line Tools can't build SwiftUI apps)"
  else
    cat <<'MSG'
error: Only the Command Line Tools are active, and they don't include the SwiftUI macro plugin
       this app needs (you'd see "plugin for module 'SwiftUIMacros' not found").
       Install Xcode from the App Store, open it once to finish setup, then re-run this script.
       (The MCP server alone does build with the CLT:  swift build -c release --product smsbackup-mcp)
MSG
    exit 1
  fi
fi

BUILD_ARGS=(-c release)
if [[ $UNIVERSAL == 1 ]]; then BUILD_ARGS+=(--arch arm64 --arch x86_64); fi

echo "==> Building (swift build ${BUILD_ARGS[*]})"
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

APP="build/$APP_NAME.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SMSBackupViewer" "$APP/Contents/MacOS/SMSBackupViewer"
cp "$BIN_DIR/smsbackup-mcp" "$APP/Contents/MacOS/smsbackup-mcp"

# App icon
if [[ -f Resources/AppIcon.png ]] && command -v iconutil >/dev/null; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>SMSBackupViewer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>SMS Backup &amp; Restore XML</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.xml</string><string>public.zip-archive</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
codesign --force --sign - "$APP/Contents/MacOS/smsbackup-mcp"
codesign --force --sign - "$APP"

if [[ $INSTALL == 1 ]]; then
  echo "==> Installing to /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  APP="/Applications/$APP_NAME.app"
fi

echo
echo "Done: $APP"
echo "MCP server: $APP/Contents/MacOS/smsbackup-mcp"
echo "Open the app and go to Settings (⌘,) → MCP Server to connect it to Claude."
