#!/bin/sh
# Builds dist/Claude Top.app (universal, signed).
#
# Environment:
#   SIGN_IDENTITY  Code-signing certificate name. Default: "Claude Top Local".
#                  If it is not in the keychain, the script uses ad-hoc signing.
#   BUNDLE_ID      Default: local.claudetop
#   VERSION        Default: 0.1.0
#   ARCHS          Default: "arm64 x86_64"
set -eu
cd "$(dirname "$0")/.."

APP_NAME="Claude Top"
BUNDLE_ID="${BUNDLE_ID:-local.claudetop}"
VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Claude Top Local}"
ARCHS="${ARCHS:-arm64 x86_64}"
MIN_MACOS="14.0"

APP="dist/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"

app_bins=""
hook_bins=""
for arch in $ARCHS; do
  triple="$arch-apple-macosx$MIN_MACOS"
  echo "==> Building for $arch"
  swift build -c release --triple "$triple" --product ClaudeTop
  swift build -c release --triple "$triple" --product claude-top-hook
  bin_path="$(swift build -c release --triple "$triple" --show-bin-path)"
  app_bins="$app_bins $bin_path/ClaudeTop"
  hook_bins="$hook_bins $bin_path/claude-top-hook"
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
# shellcheck disable=SC2086
lipo -create $app_bins -output "$MACOS/ClaudeTop"
# shellcheck disable=SC2086
lipo -create $hook_bins -output "$MACOS/claude-top-hook"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "==> Drawing app icon"
  iconset="$(mktemp -d)/AppIcon.iconset"
  swift scripts/make-icon.swift "$iconset"
  iconutil -c icns "$iconset" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$RESOURCES/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>ClaudeTop</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Claude Top controls iTerm2 to bring the window of a Claude Code session to the front.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Claude Top sends light changes to the webhook that you set in Settings.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
PLIST

if security find-identity -p codesigning | grep -q "\"$SIGN_IDENTITY\""; then
  identity="$SIGN_IDENTITY"
else
  identity="-"
  echo "warning: No certificate named \"$SIGN_IDENTITY\". Using ad-hoc signing."
  echo "warning: macOS will ask again for iTerm2 control and Keychain access after each build."
  echo "warning: See README.md, section \"Signing certificate\"."
fi

echo "==> Signing with identity: $identity"
codesign --force --sign "$identity" --identifier "$BUNDLE_ID.hook" "$MACOS/claude-top-hook"
codesign --force --sign "$identity" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

echo "==> Done: $APP"
