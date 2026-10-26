#!/usr/bin/env bash
# Buduje i podpisuje binarki z `swift build` tą samą tożsamością i identyfikatorami co Delegate.app.
# Keychain ufa im wtedy tak jak zainstalowanej aplikacji, więc nie pyta o hasło przy każdym
# przebudowaniu (podpis ad-hoc zmienia się przy każdej kompilacji i ACL go nie rozpoznaje).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-debug}"
if [[ -z "${SIGN_ID:-}" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -E 'Apple Development|Developer ID Application' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
fi
if [[ -z "$SIGN_ID" ]]; then
  echo "Brak certyfikatu Apple Development / Developer ID (security find-identity -v -p codesigning)." >&2
  exit 1
fi

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
codesign --force --sign "$SIGN_ID" --identifier com.mar.delegate "$BIN/Delegate"
codesign --force --sign "$SIGN_ID" --identifier com.mar.delegate.mcp "$BIN/delegate-mcp"
echo "Podpisano ($SIGN_ID): $BIN/Delegate, $BIN/delegate-mcp"
