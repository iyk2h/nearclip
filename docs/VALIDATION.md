# 0.3.1 validation

Validated locally on macOS 15.7.2, Apple Silicon. This is a public beta. Local integration tests do not establish that all physical two-Mac setups work.

## Automated checks

- **82 regression checks passed.** Coverage includes Unicode text, PNG/TIFF fidelity, pause/resume, local TCP, framing limits, authenticated encryption, tampering, replay, numeric pairing, address parsing, direct transfer, and shutdown.
- New pairing-policy checks cover first use, saved peers, explicit invitations, cancellation, and migration after authenticating a legacy peer.
- A real local connection to an expired invitation is rejected before verification, even when the UI expiry timer has not run.
- Pairing tests close discovery immediately after approval and confirm that both peers still receive the pairing confirmation.

Tests use synthetic identities and separate temporary pasteboards. They do not read or write the general clipboard.

## UI review

Reviewed 13 official reference sources, including screenshots from eight products. [Reference notes](DESIGN-REFERENCES.md) distinguish observed patterns from design hypotheses.

The first rendering pass exposed inconsistent button alignment and excess space in the empty list. A second pass corrected row sizing, button widths, and the scroll document's coordinate system.

The final light and dark previews cover nearby devices, a connected Mac, a saved offline Mac, paused sharing, settings, and expanded connection help. Screenshots use synthetic names and status. They do not show a real remote connection.

- [Nearby devices](connection.png)
- [Connected](connected.png)
- [Paused](paused.png)
- [Settings](settings.png)

## Packaged diagnostics

The packaged Bonjour pairing, encrypted synthetic transfer, and session cleanup diagnostics passed. The lifecycle diagnostic passed 14 checks, including pause/resume, settings, opening and closing new pairing, menu-bar-only operation, reopening, quit, and stable window geometry across repeated status updates. Run them as described in [Development](DEVELOPMENT.md#bundled-diagnostics).

## Distribution and remaining checks

The app is built for arm64 and x86_64 and uses an ad-hoc signature. It is not Developer ID signed or notarized.

The earlier 0.2 build worked on two physical Macs in this project. The 0.3.1 changes still need physical two-Mac checks for discovery, text/image sharing, sleep/wake, router changes, VPNs, and login startup. Full VoiceOver, keyboard traversal, and Intel GUI testing are not complete. No independent security audit has been performed.
