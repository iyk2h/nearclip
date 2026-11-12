# Changelog

## 0.4.2 — 2026-11-12

- Combine connection, mouse sharing, and file transfer on one screen.
- Expand or collapse screen arrangement and permissions below the mouse toggle; keep settings inline.
- Show missing input permissions separately and check again when the app becomes active. Request only the missing permission from an explicit enable action.
- Default new received clipboard items to Apple current-host-only scope, with an option to allow Apple relay. This does not block other apps or change Handoff settings.
- Add Keychain and Apple Continuity guidance with explicit limitations.
- Keep automated diagnostics offscreen and out of the Dock.

## 0.4.1 — 2026-11-12

- Replace the left/right menu with draggable monitor cards for the two paired Macs.
- Apply a completed drop to both Macs through the existing authenticated layout protocol.
- Add a keyboard-accessible Swap order button and cancel incomplete drags on Escape, connection changes, or remote layout changes.
- Keep arrangement edits unavailable during remote mouse control.
- Show connection state, identify this Mac, and update the English setup guide.

## 0.4.0 — 2026-11-12

- Add explicit single-file transfer, up to 2 GiB, with recipient acceptance, progress, cancellation, checksums, and safe saving.
- Add opt-in mouse movement, clicking, dragging within the remote Mac, and scrolling across an outer screen edge.
- Synchronize left/right screen layout between the paired Macs.
- Add Control–Option–Escape, local takeover, heartbeats, held-button cleanup, and input consent revocation on disconnect.
- Keep file I/O off the input run loop and bound transfer queues.
- Negotiate features through the authenticated channel while retaining clipboard-only peer support.
- Document the portable message format and remaining work for a Windows client.
- Mark mouse/file features experimental until physical two-Mac validation is complete.


## 0.3.1 — 2026-11-12

- Replace the nearby-device picker with named device rows and individual Connect buttons.
- Separate first-use discovery from daily sharing. Show saved-device identity and offline reconnection state.
- Close new-pairing discovery after approval. Require an explicit, two-minute invitation to replace a saved pairing.
- Put address entry and permission help behind a disclosure. Keep pause, send, and Quit easy to reach.
- Reduce window size in daily use and refine native light/dark styling.
- Document 13 design references and update the English setup guide.


## 0.3.0 — Public beta

- Add a visible Quit button and standard Command-Q / Command-W shortcuts.
- Ask whether to quit or stay in the menu bar when closing the window. Allow the user to remember the choice.
- Split connection controls and preferences into tabs. Support light and dark appearance.
- Add login-at-startup controls, disconnect confirmation, pairing cancellation, and a selectable local address.
- Use one declared Bonjour service with distinct pairing and clipboard names.
- Exchange authenticated reconnect ports during pairing and save approved direct routes.
- Resolve simultaneous connections deterministically. Clear active connections on shutdown.
- Add tests for direct pairing, direct transport, address validation, and lifecycle cleanup.
- Add a universal build, DMG packaging, checksums, CI, and public documentation.

This beta is not notarized. Cross-device compatibility and sleep/wake coverage are described in the release validation notes.
