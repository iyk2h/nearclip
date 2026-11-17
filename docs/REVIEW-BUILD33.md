# Build 33 review — November 17, 2026

## Remaining blocking path

Build 32 moved clipboard payload reads and image conversion to a worker, but still read `changeCount`, captured baselines, checked the final clipboard count, and committed received contents on the main thread. These calls communicate with the pasteboard server and can wait. Moving only image conversion did not isolate the complete clipboard operation from input callbacks.

The physical build 32 peer reported three idle timeouts after 3.5–4 seconds without input. Two overlapped local clipboard worker reads of 13.6 and 5.6 seconds. That establishes the timeout reason and overlap, not the exact function that stopped input. Process samples did not capture the original pause.

## Changes

The production clipboard path performs all pasteboard access on one serial worker, including baseline and change-count checks and writes. Only immutable results, logical clock updates, and UI callbacks return to the main thread. The synchronous codec remains available for isolated tests.

The queue holds one active job, one newest receive or baseline, and one pending poll. Automatic polls cannot displace an explicit resend. Incoming data waits for the initial asynchronous baseline. Local changes detected before or during image preparation prevent a stale remote overwrite. Simultaneous local copies converge through logical clocks.

A short lock protects a cancellation token. No pasteboard call holds that lock. Pause, disconnect, and stop invalidate queued writes without waiting for a provider. A write already submitted to macOS cannot be cancelled; invalidation prevents subsequent queued writes.

Invalid local image data advances the observed change count, so the same failure does not trigger repeated decoding every 250 ms. Confidential-content filters and size limits remain in place. Connection-close logs now include the local probe scheduling gap at the time of closure. No network timeout or stuck-key safety limit was increased.

## Validation

See [Validation](VALIDATION.md) for final results. New fault-injection tests block the actual clipboard adapter's change-count and write operations for 4.2 seconds each while real TCP input probes continue. They also check bounded polling and prompt pause/disconnect/stop behavior. Other tests cover asynchronous simultaneous copies, echo prevention, baseline races, invalid images, and explicit resend priority. These tests use private pasteboards or an injected adapter, not the general clipboard.

The native gesture round-trip assertion now compares against the destination rendering packet. Its former fixed positive-progress expectation was incorrect on macOS 27 with natural scrolling. Existing direction-matrix checks remain in place; application gesture behavior did not change.

## Limits

The worker prevents clipboard IPC in the sharing engine from blocking the main thread. It does not eliminate provider delays, guarantee network delivery, or prove that every physical peer timeout had this cause. Both Macs need the update to isolate their own clipboard processing. Long-running physical stability and slow-provider checks remain required.

## Packaged discovery limitation

The final 671-check regression suite and 51 packaged lifecycle checks passed. Fixed signing identity, prompt-free Keychain reads, and updater integrity checks passed. Packaged Bonjour smoke failed to discover its synthetic peer in two attempts. The already-installed build 32 failed the same packaged discovery check on the current macOS 27.2.1 system. This does not isolate the cause of that failure and is not recorded as a pass. The real saved-peer connection was still active. The application transport changes in build 33 are diagnostic logging only; the functional change is clipboard scheduling.

## Installation and initial runtime check

The public updater verified the signed feed and update archive, but its installer agent did not establish its connection before the timeout on this macOS 27.2.1 system. Automatic installation failed; it is not recorded as a successful update. The validated app was then installed at the existing path after quitting the old process, with build 32 retained as a local backup. No permissions or Keychain records were reset.

The installed executable matched the release package and passed strict signature verification. Saved pairing and enabled input sharing were retained without a Keychain prompt. Input authenticated in 348 ms. The first 55 probe samples had no disconnect, but the peer still advertised build 32. Network RTT variation remained, including a 350 ms sample. Both-peer slow-provider and long-duration tests remain pending.

## CI fixture correction

GitHub Actions exposed an AppKit exception on both macOS 15 architectures. `clipboardWorkerTests` inspected `NSPasteboard.data(forType:)` from a polling assertion while the clipboard worker was updating the same object's mutable type cache. The test now waits for all queued clipboard work to finish before inspecting or releasing its private pasteboard. Fixed-duration sleeps were replaced with explicit completion waits that fail on timeout. The two-Mac simulation also uses a shared fixture queue because its two simulated Macs share one process and AppKit caches; physical Macs do not share those caches. Assertions and blocking-IPC tests remain enabled. This correction changes test code only and requires no app update.
