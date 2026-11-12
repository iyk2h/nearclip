# Changelog

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
