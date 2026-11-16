# Build 29 review — November 16, 2026

## Findings and changes

The user reported reversed horizontal desktop movement when controlling the macOS 27 Mac. Five horizontal swipes reached the send path with matching start and end phases. The transport did not reverse their order.

The macOS 27 renderer used the captured direction without converting it to the destination posting convention. Build 29 converts progress and horizontal velocity together. It accounts for the destination natural-scroll preference. Vertical gestures and two-finger scrolling keep their existing path.

The input dialer also returned without retry when its resolved address was unavailable after authentication. A real TCP test reproduced that intermediate state. Build 29 retries without replacing the authenticated bulk connection. A shutdown test checks that the retry stops.

These changes do not establish why the earlier physical connection needed an app restart. That failure had no input-ready event before the peer restarted.

## Regression coverage

The final suite passed 583 checks without posting system input or accessing the general clipboard. The packaged app passed 48 lifecycle checks and the network smoke test. Update identity and prompt-free Keychain checks passed. Modified updater and host test copies were rejected. Both architectures compiled, but runtime checks used Apple Silicon. Coverage includes:

- Gesture direction across macOS 15, 26, and 27 adapters, both axes, both signs, all phases, and both natural-scroll settings.
- Native payload layout, cancellation, stale sessions, echo prevention, and unsupported OS rejection.
- Keyboard modifiers, repeat events, key release, secure input, emergency stop, and input ordering during bulk transfer.
- Sleep, lock, wake, explicit stop, peer restart, stale routes, input-channel recovery, and shutdown cancellation.
- Clipboard text and image validation, transfer ordering, file consent, file integrity, file races, and cleanup.
- Pairing approval, authentication, tamper rejection, replay rejection, legacy capabilities, and update selection.

The local TCP burst delivered 24 ordered input frames during a 20 MiB clipboard transfer in 11 ms. This is not physical Wi-Fi latency. Local stale-route recovery took 812 ms.

## Physical speed observations

Build 28 logs still showed rolling input RTT p95 values around 178–252 ms. Local send queue wait displayed 0 ms. A separate TCP snapshot reported about 33 ms smoothed RTT and 31 ms variation for the input connection. Those measurements cover different windows and cannot establish key-to-screen latency.

ICMP probes to the connected peer received no replies. The authenticated TCP connection remained usable. No ICMP reply is not evidence of TCP packet loss.

The direction and retry changes do not claim to solve latency spikes. A physical before-and-after speed claim remains unsupported.

## Remaining physical checks

The public updater installed build 29 and relaunched the local app. The executable matched the release package and passed signature verification. The saved peer and enabled input-sharing choice remained in place, with no Keychain prompt during this launch. The peer was offline.

Corrected left/right desktop direction on the macOS 27 destination needs user confirmation after installation. Repeat sleep/wake and updates on both physical Macs also remain unverified. The existing source-Mac-to-local-Mac gesture and typing success is recorded in `VALIDATION.md`.
