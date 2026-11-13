# Development

## Requirements

Use macOS 13 or later and Apple's Command Line Tools. No package manager or third-party runtime is required.

```sh
xcode-select --install
git clone https://github.com/iyk2h/nearclip.git
cd nearclip
python3 scripts/setup-local-signing.py
bash build.sh
open build/NearClip.app
```

The build script creates one universal app for Apple Silicon and Intel. The build uses `SIGNING_IDENTITY`, or the persistent local identity configured below. Without either, an ad-hoc build can run previews and synthetic tests, but cannot read or save real pairing keys. The bundle ID is `dev.nearclip.mac`; changing it can change permission and settings behavior.

## Tests

```sh
bash test.sh
```

Tests use temporary pasteboards and local TCP connections. They do not read or write the general clipboard. Run them in a macOS GUI session with access to local networking and the pasteboard service. Network-restricted sandboxes can block integration tests.

The suite covers text and image round trips, concurrent copies, pause, reconnection, framing limits, authentication, replay, numeric pairing, direct pairing, address validation, shutdown, file consent/integrity/cleanup, screen layout convergence, mouse handoff, watchdog return, and legacy capability negotiation. Intel builds are compiled; runtime tests depend on the host architecture.

## Preview

```sh
build/NearClip.app/Contents/MacOS/NearClip --preview --light
build/NearClip.app/Contents/MacOS/NearClip --render-preview /tmp/nearclip.png --dark --settings
```

Preview mode uses sample UI state. It does not access the Keychain, general clipboard, or network. Use `--sharing --connected` for the file/mouse page. Use `--nearby`, `--connected`, `--offline`, `--paused`, or `--advanced` for other states. Combine `--connected --paused` to show a paused saved connection.

## Bundled diagnostics

Run the app bundle diagnostics after a build. These use synthetic data, not the general clipboard or saved pairing secrets.

```sh
build/NearClip.app/Contents/MacOS/NearClip --smoke-test
build/NearClip.app/Contents/MacOS/NearClip --lifecycle-smoke
```

The first checks Bonjour, encrypted clipboard/file transfer, and shared layout under the actual app identity. The second checks menu entries, inline mouse/settings expansion, pause/resume, input consent, hiding/reopening, stable geometry, and quit cleanup. Both exit when complete. Render and diagnostic modes keep their windows offscreen and use accessory activation so they do not occupy the Dock or steal focus. Tests create native mouse event objects but never post them, install real input hooks, move the system cursor, or request input permissions.

## Release

```sh
bash scripts/package.sh
```

The script creates a DMG with an Applications shortcut, a ZIP, and SHA-256 checksums. Set `SIGNING_IDENTITY` to a Developer ID Application identity to sign. Set `NOTARY_PROFILE` to a stored `notarytool` profile to notarize. Package builds fail if no stable identity is configured. A persistent self-signed beta identity is still unnotarized.

Before publishing, run the tests, inspect light and dark previews, and verify menu-bar controls and quit. Test two physical Macs for discovery, text/image sharing, sleep/wake, and a network change. Record anything that could not be tested. Do not claim two-device coverage from loopback tests.

Tag the tested commit, then attach the packages and checksums to a GitHub prerelease. Do not commit build products, local logs, credentials, addresses, or device identifiers.

## Stable beta signing without Developer ID

```sh
python3 scripts/setup-local-signing.py
bash scripts/package.sh
bash scripts/verify-update-identity.sh /path/to/previous/NearClip.app build/NearClip.app
```

Setup creates one non-extractable signing key in the login Keychain. Only `/usr/bin/codesign` is pre-authorized. Temporary key files are removed; the public certificate and fingerprint go to `~/Library/Application Support/NearClip Signing`. No root trust is added. Keep this Keychain identity; do not generate a new key for each version or on each CI run. Never commit or distribute private keys. A missing or locked configured identity fails the build instead of changing signing identity.

The upgrade check verifies that both app versions satisfy each other’s designated code requirement. This catches the changing `cdhash` requirement from ad-hoc builds. It does not replace testing Accessibility and Input Monitoring on a real Mac. The first migration from an old ad-hoc signature can require approval once. Keep the app ID, Keychain service/account, and install location stable.

Self-signing provides continuity, not Apple trust or notarization. For public Gatekeeper validation, use Developer ID and notarization. See [Apple’s code-signing guide](https://developer.apple.com/library/archive/technotes/tn2206/).

## Source map

| File | Responsibility |
| --- | --- |
| `App.swift` | App lifecycle, window, menu bar, settings |
| `Clipboard.swift` | Pasteboard formats, polling, conflict resolution |
| `Core.swift` | Restricted Keychain helper client, message types, framing, encryption |
| `Helpers/NearClipKeyStore.m` | Stable signed Keychain access, authenticated parent only |
| `Pairing.swift` | Discovery and two-sided numeric pairing |
| `Transport.swift` | Authenticated clipboard sessions and reconnect |
| `Preferences.swift` | Address parsing, saved route model, and pairing access policy |
| `SharingProtocol.swift` | Portable file/mouse message schema and layout state |
| `ScreenArrangementView.swift` | Draggable Mac arrangement canvas and keyboard alternative |
| `MouseGeometry.swift` | Display edge and position calculations |
| `MouseSharing.swift` | Input session state and macOS event adapter |
| `FileTransfer.swift` | Transfer state, background I/O, and safe destination commit |

Pairing and clipboard discovery share `_nearclip._tcp`. Pairing advertisements start with `pair-`; clipboard advertisements start with a group hint. Both peers can dial directly, so duplicate connections use a deterministic device-ID order.

## Keychain helper continuity

Build 16 moves access to the existing pairing item into `Contents/Helpers/NearClipKeyStore`. The helper verifies the live parent’s certificate-bound code requirement and requires private stdin/stdout pipes. The app verifies the helper’s certificate and identifier before launch. Pairing keys never appear in arguments, preferences, or diagnostic output.

Keep `build/keystore-cache` between release builds, or set `NEARCLIP_HELPER_CACHE` to a persistent private build directory. Cache entries are keyed by helper source and signing identity, checked by SHA-256, and signature-verified. Ordinary app edits and version increments reuse the same signed helper bytes. A helper change or new signing identity may require Keychain approval again. Do not re-sign nested helpers during an app-only update. A new build machine must use the same verified helper artifact or validate its hashes before claiming approval continuity.

After initial authorization, run `NearClip.app/Contents/MacOS/NearClip --keychain-check`. This checks the existing item without prompting and prints only success/failure. Use `bash scripts/verify-keychain-update.sh OLD_APP NEW_APP` to check signing requirements, identical helper bytes, and prompt-free reads from both app builds. It does not create, reset, print, or export pairing keys.
