# Roadmap

## Available in the 0.4 experimental beta

- Text and image clipboard sync between Macs.
- Explicit, recipient-approved single-file transfer.
- Opt-in mouse movement, clicks, and scrolling across a screen edge.
- Shared horizontal device layout, set from either Mac.

## Next validation work

Test two physical Macs across sleep, lock/unlock, disconnects, display scaling, multiple monitors, secure input, slow networks, long transfers, and input-permission changes. Validate Intel GUI behavior and accessibility. Sign and notarize builds when a Developer ID identity is available.

## Windows support

Add a Windows client that uses the [same protocol](SHARING-PROTOCOL.md). First validate cross-language transcript, key-derivation, and encryption fixtures. Then implement Windows discovery, credential storage, clipboard formats, safe file saving, monitor geometry, input capture, and input injection. Test Mac ↔ Windows in both directions.

The current app and binaries are macOS-only. No Windows release date is set.

## Later features

- English interface.
- Keyboard sharing with separate opt-in and held-key cleanup.
- File batches, folders, resumable transfers, and drag-and-drop sending.
- Vertical screen layout and richer monitor arrangement.
- Separate interactive/bulk network channels if latency testing justifies them.

## Naming

A broader name can be considered as the product expands. Preserve the bundle identity, Keychain access, saved pairing, and settings through any rename.
