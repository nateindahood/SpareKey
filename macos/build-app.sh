#!/bin/bash
# Build SpareKey.app (needs the Xcode command line tools: xcode-select --install)
#   ./build-app.sh            -> build/SpareKey.app
#   ./build-app.sh --install  -> also copy it to /Applications
set -euo pipefail
cd "$(dirname "$0")"

# keep the bundled data in step with the Linux copy
cp ../src/sparekey/data/keymap.json ../src/sparekey/data/layout_s98.json Sources/SpareKeyKit/Data/

# ARCH_FLAGS="--arch arm64 --arch x86_64" builds one app for Apple Silicon and Intel Macs (used by CI)
ARCH_FLAGS="${ARCH_FLAGS:-}"
swift build -c release $ARCH_FLAGS
BIN="$(swift build -c release $ARCH_FLAGS --show-bin-path)"
APP=build/SpareKey.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SpareKey" "$APP/Contents/MacOS/"
cp -R "$BIN/SpareKey_SpareKeyKit.bundle" "$APP/Contents/Resources/"
cp AppIcon.icns "$APP/Contents/Resources/"   # made by ../packaging/icons/make-icons.py
VERSION=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' ../src/sparekey/__init__.py)
cat >"$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SpareKey</string>
  <key>CFBundleDisplayName</key><string>SpareKey</string>
  <key>CFBundleIdentifier</key><string>io.github.nateindahood.sparekey</string>
  <key>CFBundleExecutable</key><string>SpareKey</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
# Release builds are signed with the SpareKey certificate (macos/SpareKey-signing.pem) so macOS keeps the
# Input Monitoring permission across versions; CI sets SIGN_IDENTITY. Without it the build is signed ad hoc.
SIGN="${SIGN_IDENTITY:--}"
codesign --force --deep --sign "$SIGN" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$APP"
if [ "$SIGN" != "-" ]; then
    REQ="$(codesign -d -r- "$APP" 2>&1)"
    echo "$REQ" | grep -q 'certificate leaf' || { echo "unexpected signature: $REQ" >&2; exit 1; }
fi
echo "Built $APP"
if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/SpareKey.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/SpareKey.app"
fi
