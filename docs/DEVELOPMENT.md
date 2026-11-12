# Development

## Requirements

Use macOS 13 or later and Apple's Command Line Tools. No package manager or third-party runtime is required.

```sh
xcode-select --install
git clone https://github.com/iyk2h/nearclip.git
cd nearclip
bash build.sh
open build/NearClip.app
```

The build script creates one universal app for Apple Silicon and Intel. The default signature is ad-hoc. The bundle ID is `dev.nearclip.mac`; changing it can change permission and settings behavior.

## Tests

```sh
bash test.sh
```

Tests use temporary pasteboards and local TCP connections. They do not read or write the general clipboard. Run them in a macOS GUI session with access to local networking and the pasteboard service. Network-restricted sandboxes can block integration tests.

The suite covers text and image round trips, concurrent copies, pause, reconnection, framing limits, authentication, replay, numeric pairing, direct pairing, address validation, and shutdown. Intel builds are compiled; runtime tests depend on the host architecture.

## Preview

```sh
build/NearClip.app/Contents/MacOS/NearClip --preview --light
build/NearClip.app/Contents/MacOS/NearClip --render-preview /tmp/nearclip.png --dark --settings
```

Preview mode uses sample UI state. It does not access the Keychain, general clipboard, or network. Use `--nearby`, `--connected`, `--offline`, `--paused`, or `--advanced` for other states. Combine `--connected --paused` to show a paused saved connection.

## Bundled diagnostics

Run the app bundle diagnostics after a build. These use synthetic data, not the general clipboard or saved pairing secrets.

```sh
build/NearClip.app/Contents/MacOS/NearClip --smoke-test
build/NearClip.app/Contents/MacOS/NearClip --lifecycle-smoke
```

The first checks Bonjour under the actual app identity. The second checks menu entries, pause/resume, settings navigation, hiding/reopening, and quit cleanup. Both exit when complete.

## Release

```sh
bash scripts/package.sh
```

The script creates a DMG with an Applications shortcut, a ZIP, and SHA-256 checksums. Set `SIGNING_IDENTITY` to a Developer ID Application identity to sign. Set `NOTARY_PROFILE` to a stored `notarytool` profile to notarize. Without these values, label the release as an unnotarized beta.

Before publishing, run the tests, inspect light and dark previews, and verify menu-bar controls and quit. Test two physical Macs for discovery, text/image sharing, sleep/wake, and a network change. Record anything that could not be tested. Do not claim two-device coverage from loopback tests.

Tag the tested commit, then attach the packages and checksums to a GitHub prerelease. Do not commit build products, local logs, credentials, addresses, or device identifiers.

## Source map

| File | Responsibility |
| --- | --- |
| `App.swift` | App lifecycle, window, menu bar, settings |
| `Clipboard.swift` | Pasteboard formats, polling, conflict resolution |
| `Core.swift` | Keychain, message types, framing, encryption |
| `Pairing.swift` | Discovery and two-sided numeric pairing |
| `Transport.swift` | Authenticated clipboard sessions and reconnect |
| `Preferences.swift` | Address parsing, saved route model, and pairing access policy |

Pairing and clipboard discovery share `_nearclip._tcp`. Pairing advertisements start with `pair-`; clipboard advertisements start with a group hint. Both peers can dial directly, so duplicate connections use a deterministic device-ID order.
