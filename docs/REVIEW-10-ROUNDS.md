# Sequential local review — 2026-11-16

This review uses ten sequential rounds. Each round records its scope, evidence, change (if needed), and verification before the next round starts. It does not claim physical two-Mac testing. Fixtures do not post native input or use the general clipboard.

## Round 1 — Gesture sequence ownership

Reproduced a duplicate-begin event returning “leave local” while a remote swipe was active. The source now suppresses invalid sequence updates it already owns, without forwarding them. Before: duplicate-begin assertion failed. After: 25 gesture checks passed (`audit24-r1-after.txt`).

## Round 2 — Missing gesture termination

Reproduced a stalled gesture staying active despite nine seconds without gesture progress because heartbeats reset the session clock. Added an eight-second gesture-specific idle limit that cancels the native animation and returns control. Before: idle-gesture assertion failed. After: 26 gesture checks passed (`audit24-r2-after.txt`).

## Round 3 — Immediate secure-input boundary

Reproduced an input packet being applied after Secure Event Input became active but before the maintenance tick. Mouse session messages now check this boundary immediately. Before: received-move assertion failed. After: six checks passed for move, button, and scroll (`audit24-r3-after.txt`).

## Round 4 — Sleep, lock, and session interruption

Added a four-state interruption matrix: sleep, display sleep, screen lock, and inactive session. Each releases held keys/cancels gestures, retains local choice, and rejects stale input after resume. Explicit off during overlapping suspensions stays off. Found and removed a physical-display dependency in an existing simulated resume test. All 37 checks passed (`audit24-r4-after.txt`); no new production defect in these suspension paths.

## Round 5 — File races and stale callbacks

Added races for a destination created after acceptance, source growth/truncation, a failed callback from an old transfer, old/foreign cancels, and wrong acknowledgement offsets. All 24 file checks passed (`audit24-r5.txt`); original destination bytes and private partial-file cleanup remain correct. No production change was needed.

## Round 6 — Clipboard privacy and malformed payloads

Reproduced a truncated PNG with readable dimensions replacing existing clipboard content. ImageIO reported this recoverable image as complete, so status checks alone did not solve it. Added bounded PNG chunk-boundary/IEND validation and native image validation before writing. All five ignored markers remain excluded even for explicit sending; invalid UTF-8 and truncated images preserve the prior clipboard. All 28 checks passed (`audit24-r6-after.txt`) using unique test pasteboards.

## Round 7 — Concurrent bulk/input and connection recovery

Extended the 20 MiB clipboard and 8 MiB file tests to include negotiated Dock swipes as well as mouse input. Both input types arrived before bulk completion; input ordering was preserved. Stale-route replacement, repeated reconnects, input-channel recovery, startup dial election, legacy negotiation, and crypto rejection checks passed. All 67 checks passed (`audit24-r7.txt`). This is loopback evidence, not physical Wi-Fi latency.

## Round 8 — Capability guidance and native UI

The expanded mouse settings did not explain absent gesture support. Added distinct disconnected, legacy-peer, unsupported-OS, and supported-beta guidance, including which Mac controls finger-count settings. The signed universal build passed 48 native lifecycle checks (`audit24-r8-lifecycle.txt`). Dark and light expanded-layout renders were inspected; text fits, permissions remain readable, and settings/close/quit flows pass.

## Round 9 — Update trust and Keychain identity

Both build 23 and build 24 satisfy the same designated signing requirement. The Keychain helper is byte-identical; both app versions read the pairing key without a prompt. Main/updater configuration checks pass, and deliberately modified updater/host fixture copies are rejected. The two `FAIL` lines in the negative-test log are expected rejection evidence, followed by passing assertions. No security controls or signing identities were changed. Logs: `audit24-r9-identity.txt`, `audit24-r9-updater.txt`.

## Round 10 — Combined regression and installed build

The combined regression suite passed all 421 checks (`audit24-r10-full.txt`). This includes every truncated prefix of the PNG fixture, oversized chunk lengths, and normal consecutive horizontal/vertical swipe completion. The packaged app passed Bonjour pairing, synthetic clipboard transfer, file integrity, encrypted layout, and network shutdown checks (`audit24-r10-smoke.txt`).

Installed the identical signed build 24 at the canonical app path. Its main window displayed `0.4.4 · 24` and retained the enabled mouse/keyboard choice across replacement and restart. The initial window was awaiting automatic reconnection; this review does not claim a new physical two-Mac test. No Keychain or permission prompt appeared. Kept build 23 as a local recovery copy. Created `NearClip-0.4.4-build24-test-macOS.zip`; public update feed is unchanged.

## Result and limits

Ten rounds completed in order. Four production defects were reproduced and corrected: duplicate swipe ownership, missing swipe termination, delayed secure-input enforcement for mouse packets, and truncated PNG acceptance. Added capability guidance and regression coverage for interruption, file races, and bulk/input concurrency. Final totals: 421 regression checks and 48 native lifecycle checks passed; packaged smoke and signature/Keychain/tamper checks passed.

Physical four-finger capture/source suppression, the remote Dock animation, real sleep/wake, and physical Wi-Fi performance remain unverified. No remote-Mac interaction was requested. Tests used simulated input and unique pasteboards, not the user's general clipboard. No new system permission, TCC reset, signing identity, or public auto-update was applied.
