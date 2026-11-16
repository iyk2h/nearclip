#!/bin/bash
# Prepare an isolated, locally signed older app. Never distribute this fixture.
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="${1:?Usage: prepare-update-test.sh APP TEST_DIR LOOPBACK_FEED_URL}"
test_dir="${2:?}"
feed="${3:?}"
[[ "$feed" == http://127.0.0.1:* ]] || exit 1
app="$test_dir/NearClip.app"
[[ ! -e "$app" ]] || { echo 'Use a fresh test directory.' >&2; exit 1; }
ditto "$source_app" "$app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 20' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NearClipTestFeedURL string $feed" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :SUDefaultsDomain string dev.nearclip.update-tests' "$app/Contents/Info.plist"
helper="$app/Contents/Helpers/NearClipUpdater.app"
xcrun clang -mmacosx-version-min=13.0 -O2 -fobjc-arc -Wall -Wextra -Werror -DNEARCLIP_UPDATE_TESTING \
  -framework AppKit -framework Security -F build/vendor/sparkle-2.10.1 -framework Sparkle \
  -Wl,-rpath,@executable_path/../Frameworks Helpers/NearClipUpdater.m -o "$helper/Contents/MacOS/NearClipUpdater"
identity="${SIGNING_IDENTITY:-$(cat "$HOME/Library/Application Support/NearClip Signing/identity.txt")}"
codesign --force --timestamp=none --sign "$identity" "$helper"
bash scripts/sign-app.sh "$app"
"$helper/Contents/MacOS/NearClipUpdater" --configuration-check
printf 'Prepared isolated fixture: %s\n' "$app"
