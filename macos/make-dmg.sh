#!/bin/bash
# Build SpareKey.app and package it as a drag-to-Applications disk image:
#   bash make-dmg.sh   -> build/SpareKey-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

bash build-app.sh
VERSION=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' ../src/sparekey/__init__.py)
STAGE=build/dmg
DMG="build/SpareKey-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/SpareKey.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag SpareKey onto this to install
hdiutil create -volname "SpareKey $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
