# 0.4.3 local test build validation

Validated locally on macOS 15.7.2, Apple Silicon. File and mouse sharing are experimental. Receiving control from a second physical Mac was confirmed with build 12. The complete bidirectional input matrix remains unverified.

## Automated regression suite

**316 checks passed locally for build 17.** The suite uses synthetic identities, temporary files, and separate pasteboards. It does not read or write the general clipboard, install input hooks, post mouse events, move the user's cursor, or request input permissions.

On November 13, a physical handoff reached the receiving Mac, then ended with `returnEdge`. A new test reproduced an immediate return from a reverse delta at the four-point entry inset and failed against build 11. Build 12 requires inward travel before return and a sustained outward push. Tests cover both directions, interrupted pushes, and fresh-session reset. The build passed the packaged lifecycle checks and mutual signing-identity verification against build 11. After installing build 12 on the receiving Mac, its UI showed active remote control and the user confirmed controlling it from the other Mac. A later observation showed an edge return. Accessibility and Input Monitoring remained granted across the build 11 to 12 replacement; a Keychain access prompt still required user approval. The origin of the unexpected reverse delta has not been established. Reverse-direction handoff, sustained keyboard/shortcut use, and the full physical matrix below remain unverified.

The new zero-movement receiver test failed against 0.4.2 and passes after the fix. Each handoff scenario now asserts that control was accepted before testing its return path. Leftward and rightward handoffs, zero-movement events, vertical local takeover, return reasons, and the optional reason field's wire compatibility are covered. The keyboard tests also cover explicit consent, capability negotiation, repeat and modifier events, stale tokens, held-key cleanup, timeout, local takeover, secure input, emergency stop, and encrypted TCP delivery. The immediate-return fix has one successful physical receiving-side confirmation; extended keyboard testing remains outstanding.

Coverage includes:

- Existing text/image fidelity, pause/resume, local TCP, framing, encryption, tampering, replay, numeric pairing, address parsing, and shutdown.
- File-offer consent; no disk writes before acceptance; bounded chunks; exact offsets; SHA-256 verification; empty files; original-file preservation; private/quarantined destinations; no overwrite; symlink/directory rejection; timeout, corruption, and cancellation cleanup.
- Real encrypted TCP file streaming through background I/O workers and encrypted screen-layout exchange.
- Capability negotiation and continued clipboard operation with a clipboard-only peer.
- Shared layout convergence and one-sided edits updating both device positions.
- Default-off input control, edge dwell/acceptance, normalized entry height, stale-token rejection, held-button cleanup, missing-heartbeat return, reverse-edge return, emergency stop, physical-input takeover, and click/late-acceptance races.
- Multiple local displays, negative monitor origins, and native Core Graphics event construction. Constructed events are inspected but never posted.

Build 13 adds synthetic checks for sleep/lock overlap, same-peer reconnect, explicit-stop persistence, held-input cleanup, stale-token rejection after wake, peer replacement, and scroll/momentum phase transport. The 120 Hz timer is a scheduling target, not a measured end-to-end rate. Physical sleep/wake recovery, bidirectional control, and scrolling feel still require user testing with both Macs updated.

Build 14 adds deterministic timing tests: immediate first/after-idle movement, 1000 Hz burst coalescing, final-sample delivery, click ordering, modifier boundaries, and Secure Event Input during immediate dispatch. These establish scheduling behavior; they do not measure physical pointer latency or smoothness over Wi-Fi.

Build 15 tests cover movement backpressure, click ordering with queued movement, late-completion isolation, adaptive maintenance intervals, and encrypted ordering between a 20 MiB background-prepared clipboard and queued input. Local synthetic timing and remaining limits are documented in [the runtime review](PERFORMANCE-REVIEW.md).

Build 16 adds real two-socket input delivery during a 20 MiB clipboard operation and an 8 MiB streamed file, parent-session key binding, old-session rejection, input replay rejection, old input-peer fallback, rejection of files/clipboard on the input socket, and either-channel cleanup. The input packet arrived before the bulk clipboard completed in the loopback test. This establishes independent transport ordering, not physical Wi-Fi latency.

Build 17 adds authenticated peer-version metadata, numeric version/build ordering, bounded latency samples, matching/expired probes, official-download URL validation, prerelease filtering, and downgrade prevention. A real TCP test interrupts input during an 8 MiB file transfer, verifies the completed file, receives clipboard content during recovery without changing the parent connection, and then exchanges input and RTT probes through a new child connection. Shutdown cancels pending retries. Build 16 fallback still tears down both sockets.

## Packaged application diagnostics

Build 17 passed 38 packaged lifecycle checks, including input-only outage/recovery, retained local opt-in, fresh remote consent, file controls during input loss, and update controls. Its signed-bundle discovery/pairing/clipboard/file/layout smoke test passed. A live update check returned public `v0.4.2` and correctly declined to offer it over local 0.4.3 build 17. Build 16 and build 17 passed the same-helper and noninteractive Keychain checks; the installed build 17 then opened without a new prompt and retained both native input permissions. Initial UI verification correctly reported the still-older peer's version as unknown.

Build 16 passed 34 lifecycle checks and signed-bundle discovery, pairing, clipboard, file, layout, and cleanup tests. The installed app reconnected to its saved peer, retained both input permissions, and enabled local input sharing. The peer had not yet been updated/enabled for a physical two-channel control test.

After one initial `NearClipKeyStore` approval, the installed bundle, another bundle location, and a version-bumped re-signed verification bundle all read the existing pairing item without a prompt. The original and verification main-app CDHashes differed; their helper bytes were identical. An unrelated Python parent with pipes was rejected with status 77 and zero output, including after approval. The diagnostic did not print or change the pairing secret. The version-bumped verification bundle was not installed or distributed. Helper-source or signing-certificate changes and locked-Keychain behavior are not covered by the prompt-free result.

Build 15 passed 34 packaged lifecycle checks, its signed-bundle Bonjour/clipboard/file/layout smoke test, and signing-identity verification against build 14. After installation, the saved peer reconnected and input permissions remained granted. The live diagnostic log recorded a 41.7-second receiving-control session ending at the return edge. Keychain approval still required a user action. Physical bulk-transfer smoothness and sleep/wake remain pending.

Build 14 passed 34 packaged lifecycle checks and mutual signing-identity verification against build 13. After installation, the main window showed build 14, both native input permissions granted, and both peers ready. Keychain access still prompted and the user approved it. The unchanged header during live handoffs and physical smoothness comparison have not yet been confirmed by the user.

Build 13 passed 34 packaged lifecycle checks, including overlapping sleep/lock callbacks and explicit-stop behavior. It also passed mutual signing-identity verification against build 12. After installation on this Mac, Accessibility and Input Monitoring remained granted, the saved peer reconnected, and both peers reported input readiness. A real sleep/wake cycle and a build-13 peer update remain unverified.

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

The build script produces one arm64/x86_64 app. The final 0.4.3 package uses a persistent self-signed certificate and is not notarized. Signing completed after approval. Two builds with different bundle versions and the final package satisfy each other’s designated code requirement. Accessibility and Input Monitoring remained granted on this Mac after replacement of build 11 with build 12. This does not guarantee retention on every Mac or eliminate Keychain prompts. CI runs regression tests, universal compilation, and signature checks on Apple Silicon and Intel hosts. Release notes link the corresponding run.

## Required physical-device checks

Before treating input sharing as stable, test:

1. Both Macs granting Accessibility and Input Monitoring, then enabling mouse sharing.
2. Handoff and return in each direction, clicks, double-clicks, scrolling, and drags within the receiving Mac.
3. Different resolutions/scales, monitor changes, local multi-monitor seams, and shared-layout changes.
4. Control–Option–Escape, local input takeover, disconnect during a held click, sleep, lock/unlock, secure input, and permission revocation.
5. Large files, cancellation, disk-full/read-only destinations, slow networks, and simultaneous clipboard/image activity.
6. Intel GUI behavior, login startup, and accessibility.

The earlier clipboard-only 0.2 build worked on two physical Macs in this project. A user also confirmed a real Mac-to-Mac text paste with 0.4.1. These results do not validate native mouse or file behavior. The current-host-only option is covered by local clipboard write paths; prevention of Apple relay still needs a physical multi-device check. Windows interoperability and a Windows client are not implemented. No independent security audit has been performed.
