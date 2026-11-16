#!/bin/bash
# Publish a reviewed, committed release. Assets must exist before the feed moves.
set -euo pipefail
cd "$(dirname "$0")/.."
package="${1:?Usage: release-update.sh PACKAGE_DIR RELEASE_NOTES}"
notes="${2:?Usage: release-update.sh PACKAGE_DIR RELEASE_NOTES}"
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit reviewed source changes before publishing.' >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$package/NearClip.app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$package/NearClip.app/Contents/Info.plist")
tag="v$version-build$build"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-build[0-9]+$ ]] || exit 1
zip="$package/NearClip-$version-build$build-macOS.zip"
dmg="$package/NearClip-$version-build$build-macOS.dmg"
[[ -f "$zip" && -f "$dmg" && -f "$notes" ]] || exit 1
# Do not publish stale packages or mismatched checksum files under a new tag.
[[ "$version" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)" &&
   "$build" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)" ]] || {
  echo 'Package version differs from committed source.' >&2; exit 1;
}
(cd "$package" && shasum -a 256 -c SHA256SUMS.txt)
lipo "$package/NearClip.app/Contents/MacOS/NearClip" -verify_arch arm64 x86_64
bash scripts/verify-updater.sh "$package/NearClip.app"
python3 scripts/prepare-update.py "$package/NearClip.app" "$zip" "$package/appcast.xml"
git push origin HEAD:main
gh release create "$tag" "$zip" "$dmg" "$package/SHA256SUMS.txt" --repo iyk2h/nearclip \
  --target "$(git rev-parse HEAD)" --draft --prerelease --title "NearClip $version · build $build beta" --notes-file "$notes"
gh release edit "$tag" --repo iyk2h/nearclip --draft=false
mkdir -p updates
cp "$package/appcast.xml" updates/appcast.xml
git add updates/appcast.xml
git commit -m "Publish signed update feed for $tag"
git push origin HEAD:main
printf 'Published %s and signed update feed.\n' "$tag"
