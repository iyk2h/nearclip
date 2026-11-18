#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?Usage: build-updater.sh APP}"
vendor="$(bash scripts/fetch-sparkle.sh)"
helper="$app/Contents/Helpers/NearClipUpdater.app"
mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Frameworks" "$helper/Contents/Resources"
ditto Helpers/ko.lproj "$helper/Contents/Resources/ko.lproj"
mkdir -p "$helper/Contents/Resources/en.lproj"
touch "$helper/Contents/Resources/en.lproj/Localizable.strings"
ditto "$vendor/Sparkle.framework" "$helper/Contents/Frameworks/Sparkle.framework"
cp "$vendor/LICENSE" "$helper/Contents/Resources/Sparkle-LICENSE.txt"
cat > "$helper/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.nearclip.updater</string>
<key>CFBundleName</key><string>NearClip Update</string>
<key>CFBundleExecutable</key><string>NearClipUpdater</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
for arch in arm64 x86_64; do
  xcrun clang -arch "$arch" -mmacosx-version-min=13.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
    -framework AppKit -framework Security -F "$vendor" -framework Sparkle \
    -Wl,-rpath,@executable_path/../Frameworks Helpers/NearClipUpdater.m -o "$helper/Contents/MacOS/updater-$arch"
done
xcrun lipo -create "$helper/Contents/MacOS/updater-arm64" "$helper/Contents/MacOS/updater-x86_64" -output "$helper/Contents/MacOS/NearClipUpdater"
rm "$helper/Contents/MacOS/updater-arm64" "$helper/Contents/MacOS/updater-x86_64"
identity="${SIGNING_IDENTITY:-}"
profile="${NEARCLIP_SIGNING_IDENTITY_FILE:-$HOME/Library/Application Support/NearClip Signing/identity.txt}"
if [[ -z "$identity" && -f "$profile" ]]; then identity="$(cat "$profile")"; fi
identity="${identity:--}"
# The separate updater loads Sparkle. Local self-signed certificates have no
# Apple Team ID, so library validation cannot be used for this helper.
# The main app and fixed Keychain helper KEEP hardened runtime unchanged.
options=(--timestamp=none)
if [[ -n "${NOTARY_PROFILE:-}" || "$identity" == "Developer ID Application:"* ]]; then options=(--options runtime --timestamp); fi
framework="$helper/Contents/Frameworks/Sparkle.framework/Versions/B"
for service in "$framework"/XPCServices/*.xpc; do
  codesign --force "${options[@]}" --preserve-metadata=entitlements --sign "$identity" "$service"
done
codesign --force "${options[@]}" --sign "$identity" "$framework/Autoupdate"
codesign --force "${options[@]}" --sign "$identity" "$framework/Updater.app"
codesign --force "${options[@]}" --sign "$identity" "$helper/Contents/Frameworks/Sparkle.framework"
codesign --force "${options[@]}" --sign "$identity" "$helper"
codesign --verify --deep --strict "$helper"
