#!/usr/bin/env bash
# Notaryzacja i zszycie biletu dla dist/Delegate.app albo podanego pliku (np. dist/Delegate.dmg).
# Wymaga podpisu Developer ID. Uwierzytelnienie, do wyboru:
#   - profil w Keychain (na własnym Macu):
#       xcrun notarytool store-credentials delegate-notary --apple-id TWOJ@APPLE.ID --team-id TEAMID
#   - klucz API App Store Connect (CI): NOTARY_KEY_PATH (plik .p8), NOTARY_KEY_ID, NOTARY_ISSUER_ID
# Użycie: SIGN_ID="Developer ID Application: Imię (TEAMID)" ./scripts/build-app.sh
#         ./scripts/notarize.sh [ścieżka]
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-dist/Delegate.app}"
[[ -e "$TARGET" ]] || { echo "Brak $TARGET" >&2; exit 1; }

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  AUTH=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
else
  AUTH=(--keychain-profile "${NOTARY_PROFILE:-delegate-notary}")
fi

# notarytool przyjmuje .zip, .dmg i .pkg; aplikację trzeba spakować.
if [[ "$TARGET" == *.app ]]; then
  SUBMIT="$(mktemp -d)/$(basename "$TARGET" .app).zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
else
  SUBMIT="$TARGET"
fi

RESULT="$(mktemp)"
xcrun notarytool submit "$SUBMIT" "${AUTH[@]}" --wait --output-format json > "$RESULT" || true
cat "$RESULT"
STATUS="$(/usr/bin/plutil -extract status raw -o - "$RESULT" 2>/dev/null || echo unknown)"
if [[ "$STATUS" != "Accepted" ]]; then
  ID="$(/usr/bin/plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" "${AUTH[@]}" || true
  rm -f "$RESULT"
  echo "Notaryzacja nieudana: $STATUS" >&2
  exit 1
fi
rm -f "$RESULT"
[[ "$SUBMIT" != "$TARGET" ]] && rm -f "$SUBMIT"

xcrun stapler staple "$TARGET"
if [[ "$TARGET" == *.app ]]; then
  spctl --assess --type execute --verbose=2 "$TARGET"
else
  spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET"
fi
echo "Notaryzacja zakończona: $TARGET"
