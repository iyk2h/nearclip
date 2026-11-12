# Roadmap

These are proposed directions, not features included in the current release. They do not have release dates.

## 1. Make clipboard sharing dependable

- Verify two physical Macs through sleep, wake, network changes, and long sessions.
- Improve discovery errors and reconnection feedback.
- Add an English interface.
- Sign and notarize release builds when a Developer ID identity is available.

## 2. Add explicit file transfer

Start with a **Send file** action for the paired Mac. Show the file name and size before transfer. Let the recipient choose whether to accept it and where to save it. Show progress, cancel, and failure states.

Do not send a Finder selection automatically because it was copied. Keep file transfer separate from automatic text and image sharing. Validate received paths, avoid silent overwrite, and use bounded streaming for large files.

## 3. Explore mouse and keyboard sharing

Let users arrange their two screens and opt into moving control across a screen edge. Provide an immediate escape shortcut that returns control to the local Mac. Handle lost connections, sleep, permission changes, and different display scales.

This needs a separate input-control design. Clipboard pairing alone must not silently grant input control. Start with two Macs; wider platform support is a later decision.

## Naming

NearClip describes the current clipboard app. A broader name can be considered before file or input sharing ships. A rename must preserve the bundle identity, Keychain access, settings, and upgrade path.
