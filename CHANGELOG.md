# Changelog

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
