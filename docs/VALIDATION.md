# 0.4.0 validation

Validated locally on macOS 15.7.2, Apple Silicon. File and mouse sharing are experimental. No claim of successful physical two-Mac mouse control is made.

## Automated regression suite

**149 checks passed locally.** The suite uses synthetic identities, temporary files, and separate pasteboards. It does not read or write the general clipboard, install input hooks, post mouse events, move the user's cursor, or request input permissions.

Coverage includes:

- Existing text/image fidelity, pause/resume, local TCP, framing, encryption, tampering, replay, numeric pairing, address parsing, and shutdown.
- File-offer consent; no disk writes before acceptance; bounded chunks; exact offsets; SHA-256 verification; empty files; original-file preservation; private/quarantined destinations; no overwrite; symlink/directory rejection; timeout, corruption, and cancellation cleanup.
- Real encrypted TCP file streaming through background I/O workers and encrypted screen-layout exchange.
- Capability negotiation and continued clipboard operation with a clipboard-only peer.
- Shared layout convergence and one-sided edits updating both device positions.
- Default-off input control, edge dwell/acceptance, normalized entry height, stale-token rejection, held-button cleanup, missing-heartbeat return, reverse-edge return, emergency stop, physical-input takeover, and click/late-acceptance races.
- Multiple local displays, negative monitor origins, and native Core Graphics event construction. Constructed events are inspected but never posted.

## Packaged application diagnostics

The packaged app passed Bonjour discovery and numeric pairing, encrypted synthetic clipboard transfer, a streamed file with digest verification, encrypted layout exchange, and session cleanup under its actual bundle identity.

The preview-mode lifecycle diagnostic passed **17 checks**, including menu-bar Quit, Command-Q, pause/resume, sharing/settings navigation, input default-off state, pause revoking input control, pairing controls, stable window geometry, hide/reopen, and termination.

These are same-Mac synthetic tests. They do not replace physical-device input testing.

## UI review

Light and dark sharing screens were rendered and inspected. Connection and settings screens were also checked after adding the Sharing tab. The previews use synthetic device names and no real connection.

- [Sharing, light appearance](sharing.png)
- [Sharing, dark appearance](sharing-dark.png)
- [Connected](connected.png)
- [Settings](settings.png)

The [reference review](DESIGN-REFERENCES.md) explains the earlier UI direction. Native controls are labeled, but a full VoiceOver and keyboard traversal audit remains outstanding.

## Distribution

The build script produces one arm64/x86_64 app. Packages have an ad-hoc signature and are not notarized. CI runs regression tests, universal compilation, and signature checks on Apple Silicon and Intel hosts. Release notes link the corresponding run.

## Required physical-device checks

Before treating input sharing as stable, test:

1. Both Macs granting Accessibility and Input Monitoring, then enabling mouse sharing.
2. Handoff and return in each direction, clicks, double-clicks, scrolling, and drags within the receiving Mac.
3. Different resolutions/scales, monitor changes, local multi-monitor seams, and shared-layout changes.
4. Control–Option–Escape, local input takeover, disconnect during a held click, sleep, lock/unlock, secure input, and permission revocation.
5. Large files, cancellation, disk-full/read-only destinations, slow networks, and simultaneous clipboard/image activity.
6. Intel GUI behavior, login startup, and accessibility.

The earlier clipboard-only 0.2 build worked on two physical Macs in this project. That result does not validate 0.4 mouse or file behavior. Windows interoperability and a Windows client are not implemented. No independent security audit has been performed.
