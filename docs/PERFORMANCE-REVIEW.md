# Runtime review — November 13, 2026

This review used the current Mac's application logs, a four-second process sample, code inspection, and synthetic data. It did not collect clipboard content or keystrokes. The raw operating-system logs stay outside this repository.

## Evidence

The sampled main thread was waiting for events in 3,209 of 3,257 samples. That short sample did not establish sustained CPU overload or reproduce a live pointer stall. The current-process log contained 159 TCC IPC entries, consistent with the once-per-second permission watchdog. Those entries alone are not permission failures.

The original clipboard preparation path ran JSON encoding, encryption, and frame construction on the main thread. A release-optimized synthetic benchmark produced these medians over three runs:

| Payload | Prepare and frame | Decrypt and decode |
| --- | ---: | ---: |
| 1 KiB | 0.05 ms | 0.02 ms |
| 1 MiB | 30.06 ms | 3.28 ms |
| 20 MiB | 612.95 ms | 66.31 ms |

These are local processing times, not network transfer times. The payload was generated text, not a user's clipboard or a PNG benchmark.

## Changes in build 15

- Prepare outgoing clipboard frames on a serial worker. Keep the outbound sequence reserved until preparation and sending finish. Decode authenticated frames over 256 KiB on a separate serial worker. Keep small input frames on their direct path. Apply state and clipboard callbacks on the main thread.
- In the local TCP regression run, `send()` returned in about 0.02 ms for 20 MiB after scheduling background preparation. This measures caller responsiveness only; the encoding and transfer still take time.
- Permit only one ordinary movement packet in flight. Accumulate further motion locally until transport completes, with the existing bounded deltas. Explicit clicks, key events, scrolling, and modifier changes flush preceding movement to preserve order. This prevents ordinary movement from filling the 32-frame send queue during a bulk operation.
- Run input maintenance at 1 Hz when waiting locally, 10 Hz during request/receive, and 120 Hz while controlling another Mac. Event taps still receive physical events directly. Keep the permission watchdog and emergency stop.
- Log control transitions, fixed return reasons, suspension/resume, timer delays, queue waits, and connection close reasons. Do not log input content, pointer coordinates, device names, addresses, file names, pairing codes, or clipboard content. Slow-queue notices are limited to one per five seconds.

## Observed after installation

The signed build 15 reconnected and reported both native input permissions granted. Its scoped diagnostic log recorded an authenticated connection in 173 ms and a receiving-control session lasting 41,746 ms, with 382 movement packets, ending normally at the return edge. The maximum reported maintenance-timer delay was 1 ms during that session. This is not a measurement of end-to-end pointer latency or a large-transfer stress test. Keychain approval was still required.

## Changes in build 16

Input uses a second authenticated TCP connection when both peers advertise support. It has independent encryption sequences and is bound to the current parent handshake. The real loopback regression delivers input before a pending 20 MiB clipboard completes. Clipboard/file traffic still shares physical bandwidth with input. Older peers retain the original protocol.

A metadata-only inspection of the existing pairing item found three `cdhash:` partitions, with no Team ID partition. This matches [Apple's securityd implementation](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp), which uses an executable hash for signed code outside its recognized Apple developer categories. A fixed designated requirement alone does not keep that hash stable.

The new restricted Keychain helper keeps its signed executable unchanged during app-only updates. It validates the signed parent, and the parent validates the helper. It reads the original item without changing its ACL or pairing secret. Initial authorization and a changed helper/certificate can still prompt. After initial authorization, the installed app and a version-bumped re-signed verification bundle both passed noninteractive Keychain reads. Their main-app CDHashes differed and helper bytes matched. An unrelated caller was denied without secret output. The native Accessibility and Input Monitoring approvals also remained granted.

## Changes in build 17

- Exchange validated version/build metadata inside the encrypted ready envelope; show matched, mismatched, or unknown versions.
- Negotiate independent input recovery. A real TCP test interrupted input during an 8 MiB file: verified file delivery and clipboard delivery continued, the parent connection ID stayed unchanged, and input recovered through a fresh child connection. Old peers retain their previous teardown behavior.
- Measure input-channel RTT once per second, keeping at most 60 samples. Show latest RTT, p95, variation between consecutive samples, and maximum recent input queue wait in Settings. Fixed aggregate logs are limited to once per ten seconds. The data does not measure display presentation time.
- Check official public GitHub releases on demand or once per day, with automatic checks configurable. Validate HTTPS repository paths and versions; never recommend a downgrade or install a downloaded file automatically.

Before the build 17 update, build 16 logs showed a 51.3-second physical receiving-control session with 497 movement packets, ending at the return edge. The reported maintenance delay was 0 ms at integer precision. This does not establish zero transport latency. Build 17 adds direct transport measurements for subsequent physical tests.

## Changes in build 20

- Observe network-path changes with `NWPathMonitor`. Debounce available-path events by 150 ms and retry saved-peer connections immediately on startup/wake. Keep the four-second fallback retry. A path event does not close a healthy session or block local traffic when internet reachability is absent.
- Prevent Bonjour from opening a second outbound attempt while the saved-address attempt for that same authenticated device identity is pending.
- Recover failed attempts and negotiated input channels without resetting working clipboard/file connections. The manual Find again action uses the same recovery path. Stop cancels queued recovery and the path monitor.
- Distinguish Bonjour `PolicyDenied` (-65570), network unavailability, and generic connection recovery. A timeout does not imply that the peer app is closed or a privacy permission is missing. The classification follows [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). Clear stale guidance after successful authentication.
- Add menu-bar input-sharing and screen-order controls. They use the existing consent and layout paths. Swapping is disabled during remote control; sharing can still be stopped during input recovery.

## Remaining physical checks

Native three-/four-finger system gestures remain unsupported. Sustained bidirectional movement, physical sleep/wake, lock/unlock, and simultaneous large-image copying need tests with both Macs on build 17. Loopback ordering does not establish end-to-end input latency over the user's network.

## Collect diagnostics

After reproducing a problem, run:

```sh
bash scripts/diagnostics.sh "/path/to/NearClip.app" 10m
```

This reads only NearClip's input and transport categories from the local macOS log. It does not upload anything. Look for `control_end`, `send_queue_slow`, `send_queue_full`, `clipboard_prepare_slow`, and `frame_decode_slow`. A processing-duration notice does not by itself mean that the main thread was blocked.


## Changes in build 22

A working discovery result can replace an unauthenticated saved-address attempt after a 750 ms head start. The old direct attempt is closed before the replacement starts. This keeps the legacy duplicate-election rule from receiving two outgoing connections from one device. Tests use a TCP listener that accepts but never authenticates the old route. The final local run reached separate-input readiness in 811 ms.

The lower device identity starts direct dialing immediately. The higher identity gives that peer a startup opportunity, then uses a 4.5-second fallback if necessary. Failed connections retry with bounded backoff. Stop cancels route replacement, retry, and fallback work. Tests cover primary dialing, secondary fallback without discovery, repeated server restarts, and shutdown.

Before this change, two physical starts authenticated bulk traffic promptly but needed about 26 seconds to prepare input. After the change, one physical start restored input in about 1.6 seconds, measured from the first startup recovery event to local input enablement. It then received control for 3.8 seconds and returned at the edge. The remote build remains unknown. This supports further testing of startup election; it does not prove the complete cause of every previous timeout or a general Wi-Fi speed guarantee.
