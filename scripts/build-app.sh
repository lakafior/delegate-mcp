#!/usr/bin/env bash
# Składa dist/Delegate.app: aplikacja menu bar + serwer MCP w Contents/Helpers.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
if [[ -z "${SIGN_ID:-}" ]]; then
  # Automatycznie wykryj lokalny certyfikat Apple Development lub Developer ID.
  # Podpisanie prawdziwym certyfikatem (zamiast ad-hoc "-") sprawia, że macOS Keychain
  # nie pyta o hasło do kluczy API po każdej aktualizacji/przebudowie aplikacji.
  DETECTED_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -E 'Apple Development|Developer ID Application' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  SIGN_ID="${DETECTED_ID:--}"
fi

echo "Tożsamość podpisu: $SIGN_ID"

swift build -c "$CONFIG" --product Delegate
swift build -c "$CONFIG" --product delegate-mcp
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="dist/Delegate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/Delegate" "$APP/Contents/MacOS/Delegate"
cp "$BIN/delegate-mcp" "$APP/Contents/Helpers/delegate-mcp"

# Zasoby i lokalizacja: bundle SwiftPM z .lproj i zasobami
shopt -s nullglob
bundles=("$BIN"/*Delegate*.bundle)
if [[ ${#bundles[@]} -gt 0 ]]; then
  for b in "${bundles[@]}"; do
    cp -R "$b" "$APP/Contents/Resources/"
    if [[ -d "$b/Contents/Resources" ]]; then
      cp -R "$b/Contents/Resources/"*.lproj "$APP/Contents/Resources/" 2>/dev/null || true
    fi
  done
fi
shopt -u nullglob

# Ikona: Assets/AppIcon.icon (Icon Composer) -> Assets.car + AppIcon.icns
ICON_TMP="$(mktemp -d)"
xcrun actool Assets/AppIcon.icon --compile "$APP/Contents/Resources" \
  --output-format human-readable-text --notices --warnings --errors \
  --app-icon AppIcon --include-all-app-icons --platform macosx \
  --minimum-deployment-target 26.0 --target-device mac \
  --output-partial-info-plist "$ICON_TMP/partial.plist" >/dev/null
rm -rf "$ICON_TMP"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.mar.delegate</string>
  <key>CFBundleName</key><string>Delegate</string>
  <key>CFBundleDisplayName</key><string>Delegate</string>
  <key>CFBundleExecutable</key><string>Delegate</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Znacznik czasu jest wymagany do notaryzacji (tylko przy prawdziwej tożsamości).
TS=(); [[ "$SIGN_ID" != "-" ]] && TS=(--timestamp)

# Podpisz zagnieżdżone bundle zasobów
shopt -s nullglob
nested_bundles=("$APP/Contents/Resources/"*.bundle)
for nb in "${nested_bundles[@]}"; do
  codesign --force --sign "$SIGN_ID" ${TS[@]+"${TS[@]}"} "$nb"
done
shopt -u nullglob

codesign --force --sign "$SIGN_ID" --identifier com.mar.delegate.mcp --options runtime ${TS[@]+"${TS[@]}"} "$APP/Contents/Helpers/delegate-mcp"
codesign --force --sign "$SIGN_ID" --options runtime ${TS[@]+"${TS[@]}"} "$APP"
codesign --verify --deep --strict "$APP"
echo "Gotowe: $APP"
