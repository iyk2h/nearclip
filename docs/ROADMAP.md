# Roadmap

## Available in the 0.4 experimental beta

- Text and image clipboard sync between Macs.
- Explicit, recipient-approved single-file transfer.
- Opt-in mouse movement, clicks, and scrolling across a screen edge.
- Drag-to-arrange monitor cards for shared left-to-right Mac order, set from either Mac.

## In the 0.4.3 test build

- Keyboard input follows an accepted mouse handoff, with held-key cleanup.
- Edge progress bars and return-reason diagnostics.
- Persistent local signing and upgrade identity checks.

## Build 37 beta

Drag a regular file from Finder across the screen edge and release it on the other Mac. Verify folder targeting and cancellation on two physical Macs.

## Next validation work

Test two physical Macs across sleep, lock/unlock, disconnects, display scaling, multiple monitors, secure input, slow networks, long transfers, and input-permission changes. Validate Intel GUI behavior and accessibility. Sign and notarize builds when a Developer ID identity is available.

## Windows support

Add a Windows client that uses the [same protocol](SHARING-PROTOCOL.md). First validate cross-language transcript, key-derivation, and encryption fixtures. The first milestone is pairing a Mac and a Windows PC and copying plain text in both directions. Follow with images, safe file transfers, and mouse and keyboard handoff. Add Explorer drops once both input and file transfers work. Test each milestone in both directions.

The current app and binaries are macOS-only. No Windows release date is set.

## Later features

- File batches, folders, resumable transfers.
- Individual display placement, vertical arrangement, and alignment between displays.

## Naming

A broader name can be considered as the product expands. Preserve the bundle identity, Keychain access, saved pairing, and settings through any rename.
