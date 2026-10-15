#!/bin/sh
# Builds the app, then packs it in dist/ClaudeTop-<version>.dmg.
set -eu
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
export VERSION

scripts/build-app.sh

dmg="dist/ClaudeTop-$VERSION.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "dist/Claude Top.app" "$staging/"
ln -s /Applications "$staging/Applications"

echo "==> Making $dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "Claude Top" -srcfolder "$staging" -ov -format UDZO "$dmg"
echo "==> Done: $dmg"
