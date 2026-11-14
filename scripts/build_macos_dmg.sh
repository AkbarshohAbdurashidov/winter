#!/bin/zsh
# Builds a universal release of Winter.app and packs it into dist/Winter-<version>.dmg.
# Usage: scripts/build_macos_dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')
APP=build/macos/Build/Products/Release/Winter.app
DMG=dist/Winter-$VERSION-macOS.dmg

# Account/Pro features need the backend URL (see docs/MONETIZATION.md);
# without it the app builds as the plain free version.
DEFINES=()
[ -n "${WINTER_API_URL:-}" ] && DEFINES+=(--dart-define=WINTER_API_URL="$WINTER_API_URL")
[ -n "${WINTER_API_KEY:-}" ] && DEFINES+=(--dart-define=WINTER_API_KEY="$WINTER_API_KEY")
flutter build macos --release "${DEFINES[@]+"${DEFINES[@]}"}"
# Re-sign ad hoc so the bundle is consistently signed (no Developer ID available).
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
rm -f "$DMG"
hdiutil create -volname "Winter" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
echo "$DMG"
