# Validation

## 0.4.4 build 31 — November 17, 2026

The regression suite passed 632 checks. The packaged app passed 51 lifecycle checks and encrypted network smoke. Fixed code identity, prompt-free Keychain reads, and updater tamper rejection passed. Both architectures compiled; runtime tests used Apple Silicon. A local full-duplex input burst received 26 frames in 10 callbacks, compared with at least 52 callbacks in the previous receiver structure. This is not a physical latency measurement. [Build 31 review](REVIEW-BUILD31.md) records coverage and limits. [Input responsiveness](INPUT-PERFORMANCE.md) defines the two-Mac comparison.

## 0.4.4 build 30 — November 17, 2026

The final regression suite passed 603 checks. The packaged app passed 51 lifecycle checks and the encrypted network smoke test. Fixed signing identity, prompt-free Keychain access, and updater tamper rejection passed. Both architectures compiled; runtime checks used Apple Silicon. [Build 30 review](REVIEW-BUILD30.md) records the secure-input interruption, re-entry fix, local processing benchmark, and physical limits. The suite covers input order, secure-input recovery, stale completions, encryption, file transfer, clipboard behavior, and network recovery.

The public updater installed build 30, retained the sharing choice, and reconnected input in 253 ms. The user confirmed successful desktop-switch return and re-entry. A later heartbeat/probe timeout recovered automatically, but its cause remains unresolved. See the build review for the observed limits.

## 0.4.4 build 29 — November 16, 2026

The final regression suite passed 583 checks. The packaged app passed 48 lifecycle checks and the network smoke test. Update identity and prompt-free Keychain checks passed. Modified updater and host test copies were rejected. Both architectures compiled, but runtime checks used Apple Silicon. [Build 29 review](REVIEW-BUILD29.md) records the direction and initial-route findings, test coverage, and remaining physical checks.

The direction matrix covers macOS 15, 26, and 27 adapters, both axes, both signs, all phases, and both natural-scroll settings. The initial-route test authenticates the bulk connection before exposing the input address. It checks automatic input recovery and cancellation on shutdown.

The user confirmed reversed horizontal desktop movement when the macOS 27 Mac received control on build 28. Build 29 corrects the destination posting sign. Physical confirmation after this update remains pending. These checks do not establish that intermittent network latency is resolved.

The public updater downloaded and installed build 29, then relaunched the local app. The installed executable matched the release package and passed strict signature verification. The saved peer and enabled input-sharing choice remained in place. No Keychain prompt appeared during this launch. The peer was offline, so reconnect and corrected remote direction could not be checked.

## 0.4.4 build 28 — November 16, 2026

### Physical test after peer restart

The user reported that horizontal swipes, vertical gestures, and typing worked after restarting the peer. Local logs recorded six horizontal and two vertical gestures. Each gesture had a matching began and ended phase. The local Mac received control from the macOS 27 peer on macOS 15.7.2. This confirms that direction only, not gesture rendering on a macOS 27 destination.

Two observed control sessions lasted about 43 and 21 seconds. Both ended at the return edge. The later session received 426 movement packets and reported a maximum timer delay of 10 ms. No active-session disconnect occurred in these two observed sessions. An unrelated unauthenticated handshake timed out during the earlier session without ending control.

The input channel became ready in 217 ms after the peer restart. The preceding connection authenticated its bulk channel but did not finish input setup before another peer disconnect. The reason for that initial setup stall remains unresolved.

Recent rolling p95 RTT values remained about 213–241 ms. Local send queue wait displayed 0 ms. These are transport measurements, not key-to-screen latency. Restart recovery and intermittent latency remain open issues.

### Automated and release checks

The final suite passed 451 checks. The signed universal app passed 48 lifecycle checks, packaged network smoke, update identity, and prompt-free Keychain access.

The public updater installed build 28 on the local Mac. The app reconnected with input sharing enabled. The installed executable matched the signed release package. The peer still advertised no gesture support during this observation, so physical gesture testing remains pending its update.

The affected physical peer reported OS major 27 in its authenticated ready message. Both apps showed build 27 in connection diagnostics. The 13–26 gesture gate explained why that peer did not advertise gesture support.

The new adapter constructs the macOS 27 IOHID payload locally from validated fields. Tests cover both axes, all four phases, signed fixed-point values, zero velocity, and tiny progress. They also cover unknown OS rejection and neutral source termination.

An initial native conversion test failed because CGEvent deserialization cleared the echo marker. The adapter now restores the marker after conversion. The final test passed. Native conversion tests ran on macOS 15.7.2 without posting input. Physical macOS 27 capture and animation remain unverified.

With both physical peers on build 27, individual RTT log samples included 17–50 ms. The rolling p95 remained around 240–270 ms. Local queue wait displayed 0 ms, and observed control sessions reported timer delays of 0–3 ms. These measurements do not establish end-to-end keyboard latency or resolution of intermittent stalls. Build 28 changes gestures, not the input transport.


## 0.4.4 build 27 — November 16, 2026

The regression suite passed 430 checks. The signed universal app passed 48 lifecycle checks and the packaged network smoke test.

The input burst test sent 24 mouse and keyboard frames during a 20 MiB clipboard transfer. All frames arrived in order in 5 ms over loopback. Modifier transitions, repeat events, key releases, and an interleaved keepalive retained their order. Closing a saturated input channel completed each submission once. The total input queue stayed bounded.

Physical logs before the change showed input-channel p95 around 200–250 ms and queue waits up to 47 ms. These are transport measurements, not key-to-screen measurements. The exact cause of the Wi-Fi delay is not established. Results with both physical Macs on build 27 remain pending.

The input send window holds at most four frames. Input connections use [responsive traffic priority](https://developer.apple.com/documentation/network/nwparameters/serviceclass-swift.property) and [disable acknowledgment stretching](https://developer.apple.com/documentation/network/nwprotocoltcp/options/disableackstretching). Active control uses a [user-initiated activity that permits idle system sleep](https://developer.apple.com/documentation/foundation/processinfo/activityoptions/userinitiatedallowingidlesystemsleep). These changes reduce avoidable waiting without changing input authorization or packet order.

Both bundles passed the same signing requirements and noninteractive pairing-key reads. The Keychain helper bytes stayed identical. The updater rejected modified host and updater test copies.

The public signed feed offered build 27 to the installed build 26 app. The built-in updater downloaded and installed the release, then restarted NearClip. The installed executable matched the release package. Its signature passed validation. Pairing, input permissions, and the enabled input choice stayed in place. The app reconnected to the existing peer without a password prompt.

The peer still used build 24 during this observation. Round-trip spikes remained after the local update, including one 621 ms sample. This does not establish a physical latency improvement. Both-peer testing remains necessary.

Physical four-finger gestures remain unverified. Build 27 includes the capability diagnostics from build 26. The peer must update before those diagnostics can report its OS major version.

## 0.4.4 build 22 — November 16, 2026

The final regression suite passed 344 checks. The signed universal app passed 45 lifecycle checks. The packaged Bonjour, clipboard, file, and screen-layout smoke test passed before the final startup-dial adjustment. The final transport suite covers that adjustment, startup fallback, repeated peer restart, and cancellation on shutdown.

New tests cover a stalled saved address plus a working discovery result. The final local TCP run restored the separate input connection in 811 ms, before the 12-second handshake timeout. This is a local test, not a Wi-Fi latency claim. Tests also cover saved input choices, pairing-key replacement, locked startup, fresh remote consent, emergency stop, and different-peer rejection.

Light and dark main views, first connection, focused Settings, and expanded arrangement were inspected. Settings stays in a compact scrollable window. The input switch keeps its state when arrangement is collapsed. Diagnostics and return reasons stay in Settings.

The current Mac retained Accessibility and Input Monitoring approval. The old and new bundles passed noninteractive Keychain checks with identical helper bytes. No Keychain password was requested during the observed app replacements. Native input permission continuity on other Macs is not established by this check.

A physical restart reproduced about 26 seconds of input preparation with the earlier startup logic. After giving one device priority for startup dialing, one observed restart restored input in about 1.6 seconds. The input switch stayed enabled without a click. A subsequent receiving-control session lasted 3.8 seconds and ended at the return edge. The peer did not report a build number. These observations do not establish sustained latency, both directions, or results with both Macs on build 22.

Remaining physical checks: both Macs on build 22, repeated sleep/wake and lock/unlock, Wi-Fi changes, sustained bidirectional keyboard/mouse use, and simultaneous large transfers. Apple Developer ID notarization is unavailable because no Developer ID account/certificate is configured. The beta retains its existing local signing identity.

Validated locally on macOS 15.7.2, Apple Silicon. File and mouse sharing are experimental. Receiving control from a second physical Mac was confirmed with build 12. The complete bidirectional input matrix remains unverified.

## Build 21 in-app update validation

326 regression checks and 44 packaged lifecycle checks passed. The app and updater validated each other's signed bundle identity; changing the updater's embedded resource caused both validation paths to reject the test copy. Build 20 and build 21 retained the same main-app designated requirement and identical Keychain helper, with prompt-free pairing reads.

A separate older test app used a compile-time-only loopback feed override. Sparkle accepted a correctly signed feed and rejected a feed changed after signing. A corrupted download was rejected before installation, leaving the old app at build 20. With the correct signed archive restored, the user-facing update flow downloaded, verified, replaced the app with build 21, and automatically relaunched it from the same fixture path. The installed executable matched the target byte-for-byte; its bundle signature verified. It reconnected to the existing peer. The canonical installed app remained build 20 during this fixture test.

The final distribution has no loopback feed override. It uses the pinned public HTTPS feed and signed archive. The final rebuild after the end-to-end test changed only the user guidance text; lifecycle and component-signature checks were rerun. These tests do not establish physical Wi-Fi/sleep recovery or Apple notarization.

## Build 20 recovery and menu validation

326 automated checks passed. New loopback tests connect to a saved peer within a two-second bound before the four-second periodic retry, preserve the authenticated connection ID through path changes/manual retry, reconnect after a simulated unavailable/available path transition, clear warnings after authentication, and cancel queued recovery on stop. Error classification tests distinguish Bonjour PolicyDenied, network unavailability, and generic failures without assuming the peer app is closed.

The signed package passed 44 lifecycle checks. Menu actions enable/disable input while the window stays hidden, synchronize left/right screen changes through a synthetic peer, retain the stop action during input recovery, and disable layout actions without a peer.

The signed build also passed Bonjour pairing, encrypted synthetic clipboard/file/layout smoke tests. Build 19 and build 20 satisfy the same signing requirements and use identical Keychain helper bytes; both passed prompt-free Keychain reads.

After installation, build 20 retained both native input permissions, reconnected to the existing peer, received clipboard content, and restored input readiness. That peer did not report build metadata. The final launch still took about 25 seconds to make the input channel ready after an initial handshake timeout; the duplicate-attempt guard did not eliminate this delay. Its cause is not established. Repeat the test with both peers updated before claiming a physical reconnect speed improvement.

These checks simulate path transitions over local TCP. They do not verify physical Wi-Fi changes, sleep/wake timing, remote mouse smoothness, or both Macs running build 20. That physical matrix remains pending.

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

## 2026-11-16 — build 23 gesture development check

- Regression suite: 367 checks passed, including gesture state/codec tests and real encrypted loopback delivery on the input connection. Initial sandbox runs could not open test listeners; the full run passed outside the sandbox. A fixture layout error was corrected before the passing run.
- Signed universal app: arm64 and x86_64 compilation passed; packaged lifecycle suite: 45 checks passed.
- Build 22 and build 23 satisfy the same designated code-signing requirement. NearClipKeyStore is byte-identical.
- Canonical local app was replaced with build 23. The main window showed `0.4.4 · 23`; the remembered input-sharing switch remained on. No permission or Keychain prompt appeared during this launch.
- ZIP: `NearClip-0.4.4-build23-test-macOS.zip`. Public update feed remains build 22.
- No physical four-finger input, remote Dock animation, or two-Mac build 23 test was performed. See GESTURES.md for scope and compatibility limits.


## 2026-11-16 — build 24 sequential ten-round review

See [the ten-round review](REVIEW-10-ROUNDS.md) for each reproduction, change, result, and remaining limit. Combined regression: **421 checks passed**. Signed-app lifecycle: **48 checks passed**. Packaged Bonjour/clipboard/file/layout smoke passed. Fixed signing identity, identical Keychain helper, prompt-free reads across build 23/24, and updater tamper rejection passed. Dark/light expanded layouts were visually inspected.

Build 24 is installed locally, with the enabled input-sharing choice preserved after restart. ZIP: `NearClip-0.4.4-build24-test-macOS.zip`. Physical gesture and remote-Mac behavior remain unverified; public feed remains build 22.
