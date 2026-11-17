# Build 32 review — November 17, 2026

## Findings

The physical build 31 log repeatedly showed an authenticated input socket closing with `peerClosed`. The bulk connection survived. This identifies which side closed the socket, but not its reason. A separate earlier session recorded a 6.6-second local timer delay. A later input probe reported 17.8 seconds before a peer close. The available evidence does not establish why that stall occurred.

Clipboard reads, image validation, and PNG/TIFF conversion ran on the same main thread as input callbacks. A slow clipboard provider or a large image could therefore delay input and probe replies. The probe watchdog also closed a connection after a three-second reply deadline without checking recent authenticated traffic or local scheduling delay.

## Changes

Clipboard data reads and image preparation use a serial worker with one active job and one replaceable pending job. Results return to the main thread. A generation check, clipboard change count, and logical stamp prevent stale writes after a newer copy, pause, disconnect, or stop. Clipboard commits remain on the main thread. The worker retains confidential-content filtering, size limits, and PNG/TIFF support.

A missed diagnostic reply no longer closes a peer that is still sending authenticated input. A delayed local run loop starts a fresh probe instead of closing before pending callbacks can run. A silent peer still reaches the original three-second deadline on the fresh probe. Mouse and keyboard safety-release limits are unchanged.

When both Macs advertise `input-diagnostics-v1`, a child socket's close reason and bounded timing counters travel over the authenticated bulk connection. These reports do not control the app. Unknown reasons, invalid ranges, oversized reports, input-channel delivery, and unnegotiated reports are rejected. Older peers do not receive this message.

## Validation

Final results are recorded in [Validation](VALIDATION.md). The worker test holds clipboard processing for 4.2 seconds while real TCP probes continue. This models a blocked provider; it does not reproduce the original physical stall. Other cases cover replacement of pending work, local-copy races, interruption, malformed images, callback thread, confidential contents, late probe replies, and dead-peer detection. A real TCP input closure delivers its diagnostic over the surviving parent while an 8 MiB file transfer completes.

## Limits

The original peer's detailed reason was not available. These changes fix identified blocking and timeout paths, but do not establish that every physical disconnect had that cause. Both Macs must update to obtain remote close diagnostics and apply the worker fix on each side. A controlled physical test remains necessary. Network latency and clipboard-server stalls during the final commit are not eliminated by this change.

## Installed follow-up

The public updater installed build 32 on the local Mac and relaunched it. The installed executable matched the release package and passed strict code-signature verification. Saved pairing and enabled input sharing remained in place. The input channel authenticated in 215 ms. The first 33 diagnostic samples completed without an input close. The peer still advertised build 31 at this check, so remote close reports and a two-sided fix could not yet be verified.
