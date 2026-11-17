# Measuring input responsiveness

## What the numbers mean

RTT measures a probe's round trip through the input connection. It includes both apps and the network. It does not measure key-to-screen latency.

From build 31, the receiving Mac also measures mouse packet intervals. Update both Macs to collect send and receive intervals together. Open Settings and read Connection diagnostics after moving the remote cursor.

| Measurement | Meaning |
| --- | --- |
| Send interval p95 | Interval between movement messages on the source Mac |
| Receive interval p95 | Interval between those messages on the receiving Mac |
| Extra variation p95 | Positive difference between receive and send intervals |
| Input queue maximum | Local wait before an input frame is submitted for sending |

The mouse window contains at most 240 intervals. Source pauses longer than 100 ms are excluded. Each interval uses one Mac's monotonic clock. Clock origins do not need to match. Logs contain counts and durations, not cursor positions, keys, or clipboard contents.

## Repeatable physical comparison

1. Use the same two Macs, network, display settings, and input device.
2. Move the remote cursor continuously in small circles for 20 seconds.
3. Stop the cursor and click a target.
4. Type a short line in a test document.
5. Repeat while transferring a large test file.
6. Repeat with the other Mac as the source.
7. Record the build numbers, RTT, mouse intervals, and visible pauses.

Read mouse intervals on the receiving Mac. Compare runs with similar source intervals. A short idle pause is not evidence of network stutter.

If the Macs already have a wired network path, repeat the same test there. Keep other conditions fixed. A large change helps isolate the network contribution. Do not change security settings for this test.

A high-frame-rate recording that shows the physical input and target screen can measure visible response. Software RTT and decode benchmarks cannot establish that result alone.

## How to choose a change

Steady send intervals with uneven receive intervals indicate delay after the source submits movement. TCP retransmission, network scheduling, and receiver scheduling can all contribute. They require further measurement to separate.

Uneven send intervals indicate work before transmission. Check input capture, timers, and sender queueing first.

Prediction can overshoot a target. A smoothing buffer can add delay before clicks. Build 31 adds neither. It removes extra receive callbacks while preserving input order and immediate processing.
