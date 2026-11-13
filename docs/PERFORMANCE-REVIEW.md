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

## Remaining priorities

1. **Bulk transfer can still delay input on the wire.** Clipboard, file, and input frames share one ordered TCP connection. Once a large frame has started, later input cannot overtake it. A separate authenticated input channel or a negotiated chunked clipboard protocol needs compatibility and failure-handling tests. Current queue logs distinguish this from main-thread processing delay.
2. **Keychain approval still repeats on some updates.** Fixed designated-requirement checks pass, but build 14 still required user approval. The exact Keychain ACL cause has not been established. Do not claim that local signing eliminates prompts or weaken Keychain protection.
3. **Gesture and physical-transition coverage is incomplete.** Native three-/four-finger system gestures remain unsupported. Sustained bidirectional movement, physical sleep/wake, lock/unlock, and simultaneous large-image copying need tests with both Macs on the same build.

## Collect diagnostics

After reproducing a problem, run:

```sh
bash scripts/diagnostics.sh "/path/to/NearClip.app" 10m
```

This reads only NearClip's input and transport categories from the local macOS log. It does not upload anything. Look for `control_end`, `send_queue_slow`, `send_queue_full`, `clipboard_prepare_slow`, and `frame_decode_slow`. A processing-duration notice does not by itself mean that the main thread was blocked.
