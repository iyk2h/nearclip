#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
out="${1:-build}"
mkdir -p "$out/NearClip.app/Contents/MacOS" "$out/NearClip.app/Contents/Resources" "$out/module-cache"
sdk="$(xcrun --show-sdk-path)"
for arch in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -O -warnings-as-errors -parse-as-library -target "$arch-apple-macos13.0" -sdk "$sdk" \
    -module-cache-path "$out/module-cache" Sources/*.swift \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist -o "$out/NearClip-$arch"
done
xcrun lipo -create "$out/NearClip-arm64" "$out/NearClip-x86_64" -output "$out/NearClip.app/Contents/MacOS/NearClip"
cp Info.plist "$out/NearClip.app/Contents/Info.plist"
cp THIRD_PARTY_NOTICES.md "$out/NearClip.app/Contents/Resources/THIRD_PARTY_NOTICES.md"
xcrun swift -module-cache-path "$out/module-cache" scripts/make-icon.swift "$out/AppIcon.iconset"
xcrun iconutil -c icns "$out/AppIcon.iconset" -o "$out/NearClip.app/Contents/Resources/AppIcon.icns"
bash scripts/build-keychain-helper.sh "$out/NearClip.app"
bash scripts/build-updater.sh "$out/NearClip.app"
bash scripts/sign-app.sh "$out/NearClip.app"
echo "Built $out/NearClip.app"
