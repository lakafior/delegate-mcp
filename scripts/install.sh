#!/usr/bin/env bash
# Buduje i instaluje Delegate.app w /Applications (na własnym Macu, bez notaryzacji).
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
osascript -e 'tell application "Delegate" to quit' 2>/dev/null || true
sleep 1
rm -rf /Applications/Delegate.app
ditto dist/Delegate.app /Applications/Delegate.app
# Zbudowana lokalnie aplikacja nie ma atrybutu kwarantanny, ale na wszelki wypadek:
xattr -dr com.apple.quarantine /Applications/Delegate.app 2>/dev/null || true
open /Applications/Delegate.app
echo "Zainstalowano w /Applications. W Ogólne kliknij „Napraw” przy Claude, jeśli wpis wskazuje starą ścieżkę."
