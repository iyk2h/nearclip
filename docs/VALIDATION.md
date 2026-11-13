# 0.4.3 local test build validation

Validated locally on macOS 15.7.2, Apple Silicon. File and mouse sharing are experimental. No claim of successful physical two-Mac mouse control is made.

## Automated regression suite

**230 checks passed locally.** The suite uses synthetic identities, temporary files, and separate pasteboards. It does not read or write the general clipboard, install input hooks, post mouse events, move the user's cursor, or request input permissions.

The new zero-movement receiver test failed against 0.4.2 and passes after the fix. Each handoff scenario now asserts that control was accepted before testing its return path. Leftward and rightward handoffs, zero-movement events, vertical local takeover, return reasons, and the optional reason field's wire compatibility are covered. The keyboard tests also cover explicit consent, capability negotiation, repeat and modifier events, stale tokens, held-key cleanup, timeout, local takeover, secure input, emergency stop, and encrypted TCP delivery. The physical report of an immediate return and real keyboard typing still need confirmation with this build.

Coverage includes:

- Existing text/image fidelity, pause/resume, local TCP, framing, encryption, tampering, replay, numeric pairing, address parsing, and shutdown.
- File-offer consent; no disk writes before acceptance; bounded chunks; exact offsets; SHA-256 verification; empty files; original-file preservation; private/quarantined destinations; no overwrite; symlink/directory rejection; timeout, corruption, and cancellation cleanup.
- Real encrypted TCP file streaming through background I/O workers and encrypted screen-layout exchange.
- Capability negotiation and continued clipboard operation with a clipboard-only peer.
- Shared layout convergence and one-sided edits updating both device positions.
- Default-off input control, edge dwell/acceptance, normalized entry height, stale-token rejection, held-button cleanup, missing-heartbeat return, reverse-edge return, emergency stop, physical-input takeover, and click/late-acceptance races.
- Multiple local displays, negative monitor origins, and native Core Graphics event construction. Constructed events are inspected but never posted.

## Packaged application diagnostics

The final signed 0.4.3 bundle passed Bonjour discovery and numeric pairing, encrypted synthetic clipboard transfer, a streamed file with digest verification, encrypted layout exchange, and session cleanup under its actual bundle identity on November 13, 2026.

The final signed keyboard/edge-bar bundle passed **30 lifecycle checks** without installing input hooks, including the click-through, nonactivating indicator and menu-bar Quit, Command-Q, pause/resume, inline mouse/settings expansion, input default-off state, pause revoking input control, pairing controls, stable window geometry, hide/reopen, and termination. Arrangement checks exercise AppKit drag events without posting system input: no publication before drop, dragging either card updates a synthetic peer, clicks preserve order, Escape and outside drops cancel, the accessible swap action synchronizes, and disconnects cancel editing.

These are same-Mac synthetic tests. They do not replace physical-device input testing.

## UI review

The linked 0.4.2 light, dark, and disconnected sharing screens were rendered and inspected. The compact main screen and expanded settings were also checked after removing the tabs. The previews use synthetic device names and no real connection. The 0.4.3 change adds a return-reason line, keyboard controls, and an edge bar; these images have not been refreshed for those changes.

- [Sharing, light appearance](sharing.png)
- [Sharing, dark appearance](sharing-dark.png)
- [Connected](connected.png)
- [Settings](settings.png)

The [reference review](DESIGN-REFERENCES.md) explains the earlier UI direction. Native controls are labeled, but a full VoiceOver and keyboard traversal audit remains outstanding.

## Distribution

The build script produces one arm64/x86_64 app. The final 0.4.3 package uses a persistent self-signed certificate and is not notarized. Signing completed after approval. Two builds with different bundle versions and the final package satisfy each other’s designated code requirement. Retention of Accessibility/Input Monitoring on a physical upgrade still requires a user check. CI runs regression tests, universal compilation, and signature checks on Apple Silicon and Intel hosts. Release notes link the corresponding run.

## Required physical-device checks

Before treating input sharing as stable, test:

1. Both Macs granting Accessibility and Input Monitoring, then enabling mouse sharing.
2. Handoff and return in each direction, clicks, double-clicks, scrolling, and drags within the receiving Mac.
3. Different resolutions/scales, monitor changes, local multi-monitor seams, and shared-layout changes.
4. Control–Option–Escape, local input takeover, disconnect during a held click, sleep, lock/unlock, secure input, and permission revocation.
5. Large files, cancellation, disk-full/read-only destinations, slow networks, and simultaneous clipboard/image activity.
6. Intel GUI behavior, login startup, and accessibility.

The earlier clipboard-only 0.2 build worked on two physical Macs in this project. A user also confirmed a real Mac-to-Mac text paste with 0.4.1. These results do not validate native mouse or file behavior. The current-host-only option is covered by local clipboard write paths; prevention of Apple relay still needs a physical multi-device check. Windows interoperability and a Windows client are not implemented. No independent security audit has been performed.
