#!/usr/bin/env bash
# Składa dist/Delegate.app: aplikacja menu bar + serwer MCP w Contents/Helpers.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SIGN_ID="${SIGN_ID:--}"   # "-" = ad-hoc; ustaw "Developer ID Application: ..." do dystrybucji

swift build -c "$CONFIG" --product Delegate
swift build -c "$CONFIG" --product delegate-mcp
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="dist/Delegate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/Delegate" "$APP/Contents/MacOS/Delegate"
cp "$BIN/delegate-mcp" "$APP/Contents/Helpers/delegate-mcp"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.mar.delegate</string>
  <key>CFBundleName</key><string>Delegate</string>
  <key>CFBundleDisplayName</key><string>Delegate</string>
  <key>CFBundleExecutable</key><string>Delegate</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_ID" --options runtime "$APP/Contents/Helpers/delegate-mcp"
codesign --force --sign "$SIGN_ID" --options runtime "$APP"
echo "Gotowe: $APP"
