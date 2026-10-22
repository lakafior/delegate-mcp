#!/usr/bin/env bash
# Tworzy dist/Delegate.dmg z aplikacją i skrótem do /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Delegate.app"
DMG="dist/Delegate.dmg"
SIGN_ID="${SIGN_ID:--}"
[[ -d "$APP" ]] || { echo "Brak $APP, uruchom najpierw scripts/build-app.sh" >&2; exit 1; }

STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Delegate.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Delegate" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
[[ "$SIGN_ID" != "-" ]] && codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
echo "Gotowe: $DMG"
