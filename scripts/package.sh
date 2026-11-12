#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-build}"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
bash build.sh "$out"
mkdir -p "$out/dmg-stage"
ditto "$out/NearClip.app" "$out/dmg-stage/NearClip.app"
ln -sfn /Applications "$out/dmg-stage/Applications"
hdiutil create -volname NearClip -srcfolder "$out/dmg-stage" -ov -format UDZO "$out/NearClip-$version-macOS.dmg"
ditto -c -k --sequesterRsrc --keepParent "$out/NearClip.app" "$out/NearClip-$version-macOS.zip"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  : "${SIGNING_IDENTITY:?SIGNING_IDENTITY is required for notarization}"
  xcrun notarytool submit "$out/NearClip-$version-macOS.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$out/NearClip.app"
  xcrun stapler staple "$out/NearClip-$version-macOS.dmg"
  ditto -c -k --sequesterRsrc --keepParent "$out/NearClip.app" "$out/NearClip-$version-macOS.zip"
fi
(cd "$out" && shasum -a 256 "NearClip-$version-macOS.dmg" "NearClip-$version-macOS.zip" > SHA256SUMS.txt)
echo "Packaged NearClip $version in $out"
