# Build 31 review — November 17, 2026

## Findings and changes

The previous input receiver requested each frame's header and body separately. Each complete input frame therefore required at least two receive callbacks. Burst delivery repeated that work for every movement and key event.

The updated receiver requests available bytes with a minimum of one byte. It does not wait to fill its receive buffer. It parses complete frames in order and retains only an incomplete frame. Each input frame remains limited to 4 KiB. Each received chunk remains limited to 64 KiB.

Authentication, message order, replay rejection, and independent bulk transport remain unchanged. The implementation does not predict cursor movement, drop input, or add a smoothing delay.

## Measurements

A full-duplex local TCP test received 26 input frames in 10 callbacks. The earlier exact-read path would require at least 52 callbacks for those frames. This measures reduced callback work, not a physical latency reduction.

New mouse timing compares source and arrival intervals. Synthetic 120 Hz input produced 8 ms intervals on both sides. The same input grouped into 50 ms bursts produced 50 ms arrival p95 and 42 ms excess p95. Different clock origins did not alter the result.

These diagnostics distinguish source pacing from delivery variation. They cannot separate network delay from receiver scheduling or measure absolute one-way latency.

## Validation

The regression suite passed 632 checks. The packaged app passed 51 lifecycle checks and encrypted network smoke. Fixed code identity, prompt-free Keychain reads, and updater tamper rejection passed. Both architectures compiled; runtime tests used Apple Silicon. New cases cover combined frames, fragmented headers and bodies, bytewise delivery, partial EOF, invalid lengths, bounded buffers, legacy timing, idle gaps, and full-duplex input during a 20 MiB clipboard transfer. Tests did not post system input or access the general clipboard.

## Physical comparison still required

Earlier build 30 logs varied from about 99 ms to 320 ms RTT p95. That variability prevents a reliable speed claim from a short before-and-after sample.

Use the [input measurement procedure](INPUT-PERFORMANCE.md) after both Macs update. Measure continuous motion and the same movement during a file transfer in each direction. Physical smoothness and end-to-end latency remain unverified for this build.
