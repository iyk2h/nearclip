# Build 30 review — November 17, 2026

## Desktop return and re-entry

Two physical sessions ended with `secureInput` about one second after a horizontal gesture ended. The input connection remained available. This supports a secure-input interruption, but does not identify which app enabled it.

The code also retained local held keys when secure input hid their release events. A regression test reproduces that sequence. The updated state machine reconciles those keys with native key state after secure input ends. It keeps keys that remain physically down.

Both apps now exchange an optional secure-input flag through the authenticated input connection. The main screen identifies the blocked Mac. Idle polling clears the pause after secure input ends. The sharing choice remains enabled, but a new edge gesture is required. No input is forwarded while protection is active.

Older peers can ignore the optional status field. They still receive the existing secure-input session-end reason. Pairing, permission grants, and system security settings are unchanged.

## Input processing

A pending mouse delta previously waited for the next 120 Hz timer after a send completion. It now drains when the transport accepts another packet. Tests check accumulated distance, click order, stale completions, and secure input starting before completion.

Received feature packets no longer pass through a second JSON encoding for validation. Structural, size, and field validation still apply. Authentication and replay checks remain in the transport.

An optimized local benchmark compared six alternating runs of 20,000 synthetic mouse, keyboard, and gesture packets. The upper-median decode time changed from about 223 ms to 107 ms. This measures decoding work only. It is not a network or user-visible latency measurement.

## Validation

The final regression suite passed 603 checks. The packaged app passed 51 lifecycle checks and the encrypted network smoke test. Fixed signing identity, prompt-free Keychain access, and updater tamper rejection passed. Both architectures compiled; runtime checks used Apple Silicon. It includes secure-input pause, retained consent, remote status, idle recovery, missing key releases, and completion-time input protection. No system input was posted, and the general clipboard was not accessed.

## Physical limits

Before this change, recent input RTT p95 values were about 220–250 ms. A separate TCP snapshot showed a smoothed RTT of 70–100 ms. These measurements cover different windows. They do not measure key-to-screen latency.

This build does not establish that those network spikes are resolved. The exact desktop-switch sequence and a two-Mac speed comparison still need physical validation after both apps update.
