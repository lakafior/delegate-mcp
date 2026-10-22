#!/usr/bin/env bash
# Notaryzacja i zszycie biletu. Wymaga podpisu Developer ID i profilu w Keychain:
#   xcrun notarytool store-credentials delegate-notary --apple-id TWOJ@APPLE.ID --team-id TEAMID
# Użycie: SIGN_ID="Developer ID Application: Imię (TEAMID)" ./scripts/build-app.sh
#         ./scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-delegate-notary}"
APP="dist/Delegate.app"
ZIP="dist/Delegate-notarize.zip"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
echo "Notaryzacja zakończona: $APP"
