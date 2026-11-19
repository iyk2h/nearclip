# Sharing protocol and Windows path

File/mouse protocol additions in 0.4.0; keyboard capability in 0.4.3. This document describes the current implementation, not a Windows client release. A Windows port requires its own clipboard, file-system, input, permissions, and packaging adapters, plus interoperability tests.

## Boundaries

- `SharingProtocol.swift`: JSON wire types and validation, using Foundation only.
- `Core.swift` and `Transport.swift`: framing, authentication, encryption, and peer capability negotiation. The algorithms and wire format are portable; the current implementations use Apple's CryptoKit, Keychain, and Network framework.
- `MouseGeometry.swift`: display geometry and edge selection.
- `MouseSharing.swift`: control-session state machine plus the macOS Core Graphics event-tap adapter. `native: false` exercises the state machine without real input.
- `FileTransfer.swift`: bounded transfer state machine, background I/O, and the macOS safe-save adapter.

A Windows client can implement the same protocol in another language. Do not attempt to compile the macOS adapters unchanged. Extract a reusable native-independent state machine when adding that client.

## Existing encrypted channel

Each TCP frame starts with an unsigned 32-bit big-endian byte length. The initial hello is UTF-8 JSON containing `version`, `device`, `name`, `nonce`, and optional `syncPort`. The nonce is 32 random bytes encoded as Base64. Hello version remains `1`; 0.4 does not add hello fields, so the session key transcript stays compatible with 0.3.

The pairing secret, handshake, sorted JSON transcript, HKDF labels, and AES-GCM framing are defined in `Core.swift` and `Pairing.swift`. AES-GCM combined data is nonce, ciphertext, then authentication tag. Decrypted JSON envelopes carry monotonically increasing directional sequence numbers. Replays are rejected.

A cross-language implementation must reproduce the transcript bytes exactly, including optional-field omission, string escaping, and sorted keys. Add shared golden fixtures for transcript bytes, key derivation, and encrypted envelopes before calling a Windows implementation compatible.

## Capability negotiation

The encrypted `ready` envelope adds an optional `features` array:

```json
["files-v1", "mouse-v1", "keyboard-v1", "input-channel-v1", "input-recovery-v1", "input-metrics-v1"]
```

A peer without these capabilities continues to exchange clipboard messages. Never send a feature packet unless the authenticated peer advertised that capability. Missing features mean unsupported, not implicit consent.

A `feature` envelope has a Base64 `data` field. Its decoded value is UTF-8 JSON with one payload field named `file`, `mouse`, `keyboard`, or `gesture`. Feature JSON is limited to 128 KiB. The transport queues at most 32 feature packets. File I/O accepts at most eight queued packets and cancels an overloaded transfer.

## File transfer

A file packet contains `kind` and UUID `id`. Optional fields are `name`, signed byte `size`, byte `offset`, Base64 `bytes`, and Base64 SHA-256 `digest`.

| Kind | Fields and meaning |
| --- | --- |
| `offer` | Basename and size, from 0 through 2 GiB. No file is created yet. |
| `accept` | Recipient chose a destination. Start sending. |
| `chunk` | Exact next offset and 1–49,152 bytes. Only one chunk is outstanding. |
| `ack` | Next expected offset after the recipient wrote and hashed the chunk. |
| `finish` | SHA-256 of the full stream. Size and digest must match. |
| `complete` | Destination was committed successfully. |
| `cancel` | Decline, cancellation, failure, or timeout. |

Unanswered offers expire after 120 seconds. Active transfers expire after 30 seconds without progress. Wrong peer IDs, wrong transfer IDs, unexpected offsets, out-of-order messages, oversize packets, and digest mismatches never publish a destination file.

The recipient chooses the complete destination path. Sender names cannot contain separators, colons, control characters, dot-only names, or more than 255 UTF-8 bytes. A port must also reject its platform's reserved filenames and handle case-insensitive collisions.

The macOS adapter creates a private, exclusive temporary file in the destination directory, writes and verifies it, adds quarantine metadata, and atomically creates the destination without replacing an existing path. It requires a filesystem that supports hard links and extended attributes. It does not restore executable bits or open received files. Cancel/failure removes the partial file during normal operation. An abrupt process crash can leave a private `.nearclip-*.part` file.

Windows needs an equivalent exclusive commit, reserved-name checks, and attachment security metadata such as Mark of the Web. Do not silently weaken these checks to make a transfer succeed.

## Cross-screen file drag (build 37)

Both peers must advertise `finder-drag-v1`, `mouse-v1`, and `files-v1` and enable input sharing. The capability name is a wire identifier. A Windows Explorer adapter can use the same messages.

1. When one regular file crosses the shared edge, the sender includes its basename in `mouse.enter.draggedFileName`. The receiver accepts the input session and displays the name beside the pointer.
2. On release, the sender flushes pending motion and sends `dropFile` with the active input token. The receiver resolves the drop position locally and replies with `dropReady` for that token. Escape before release cancels the handoff.
3. After the matching acknowledgement, the sender issues a normal file offer on the bulk channel, using the input token as the transfer ID. The recipient approves the destination, or reuses an explicit approval for that folder on this connection. If the destination cannot be identified, the recipient chooses it in the save dialog.

On macOS build 39, a drop over an application window can use the same correlated offer to stage the verified file in the receiver’s cache. NearClip checks the active input session and drop target again before passing a local file URL through an AppKit drag session. The destination chooses whether to accept it.

Only the basename crosses the network during the drag. Each platform handles its own drag session, resolves its own destination directory, and creates the copy under its own filesystem rules. Older peers can still use **Send File**.

## Shared screen layout

A `layout` mouse packet includes:

```json
{"revision": 1, "author": "DEVICE-A", "left": "DEVICE-A", "right": "DEVICE-B"}
```

The identifiers must name exactly the two authenticated peers. The higher revision wins. Equal revisions compare author identifiers lexicographically. A local edit increments the highest observed revision. This makes the two views complementary and prevents feedback loops. The layout is stored locally and shared through the encrypted channel.

Only horizontal left/right arrangement is supported in 0.4. The operating system supplies its own monitor rectangles. Local monitor seams must not trigger remote handoff.

## Mouse control

`availability` advertises explicit local opt-in. It is separate from capability support. Both peers must opt in. From build 22, local opt-in is saved for a device ID and pairing-group fingerprint. Losing the peer stops capture and ends its input session. Reconnect, wake, and restart can restore readiness for the same authenticated pairing after sleep/lock/session suspensions clear and native permissions pass. Remote availability and control-session tokens are never restored. Explicit stop, pause, a different peer, and new pairing clear it.

1. Push against the configured outer edge for at least 150 ms with no buttons or modifiers held.
2. Send `enter` with a fresh UUID `token`, the receiver's entry `side`, and vertical `fraction` from 0 to 1.
3. The receiver accepts only when enabled, idle, and outside the short handoff cooldown. It replies `accepted`, or `deny`.
4. Only after acceptance does the sender suppress its local mouse events.
5. `input` carries `move`, `down`, `up`, or `scroll`. Each input must name the active token. Deltas are finite and bounded to ±4096; buttons are left/right/middle. Only Shift, Control, Option, and Command modifier bits are allowed. Scroll packets may include optional `scrollPhase` (0, 1, 2, 4, 8, or 128) and `momentumPhase` (0–3); only scroll input may carry them. Older peers omit or ignore these fields.
6. Moves are coalesced at 60 Hz. Button transitions flush pending moves first. Input packets remain ordered within the encrypted TCP stream.
7. Moving back over the entry edge with no button held sends `leave`, including normalized height. The original Mac restores its cursor inside the edge.

Each active peer sends a heartbeat every 500 ms. A request times out after one second; an active session times out after two seconds without authenticated session traffic. Leaving, disconnecting, permission loss, or cancellation releases all remotely held buttons. Local physical input on the recipient reclaims control. With a peer that lacks keyboard capability, typing remains local and ends remote mouse control. Zero-delta receiver mouse events do not reclaim control. A `leave` can include an optional bounded `endReason` code; unknown codes use a generic message.

On macOS, Control–Option–Escape disables mouse sharing. Capture uses a session event tap; generated events carry a marker to avoid recapture. The app requests Accessibility and Input Monitoring only when the user enables mouse sharing. It also stops input on sleep, session deactivation, and the available screen-lock notification. Permission, lock-screen, and secure-input behavior still require physical-device validation.

Build 16 negotiates `input-channel-v1`. When both peers support it, the encrypted parent `ready.data` contains Base64-encoded JSON `{"port": <nonzero UInt16>}`. The lower device ID dials that port on the existing connection's resolved remote host. No extra Bonjour service or unencrypted input endpoint is advertised.

The child secret is HKDF-SHA256 of the pairing key, with sorted-key JSON for the device-sorted array of both parent hellos as salt, info `NearClip authenticated input channel v1`, and 32 output bytes. The child performs the usual hello/ready exchange with fresh nonces, expected peer identity, independent directional cipher keys, and sequence counters. It advertises only mouse and keyboard capabilities. Every child frame is limited to 4 KiB; files and clipboard are rejected. The peer is published only after both connections authenticate.

Mouse, keyboard, layout, and input availability use the child channel; clipboard and files stay on the parent. Input frames cannot overtake each other but can overtake bulk frames. Without `input-recovery-v1`, a failure of either established channel closes the whole session and invokes normal held-input cleanup. Reconnection derives fresh keys and requires fresh input availability/session acceptance. Older peers use the original single-channel path; both Macs need build 16 for separation. The two sockets still share physical network bandwidth, so separation does not guarantee latency under network saturation.

## Version, recovery, and metrics (build 17)

The encrypted `ready` envelope can carry `app: {"version":"0.4.3","build":17}`. It does not change the hello transcript. Version strings must contain three numeric components; builds are nonnegative bounded integers. Missing metadata is shown as unknown, never guessed from capabilities.

Both peers must negotiate `input-recovery-v1`. The parent becomes ready once it authenticates, independently of input readiness. The higher device ID keeps its input listener open. The lower ID reconnects to the authenticated input port with delays of 0.5, 1, 2, 4, then 8 seconds. It keeps at most one candidate and one retry. Each retry repeats the child handshake with fresh nonces. An input transition updates a separate connection generation; the app releases held input and clears remote availability without cancelling file work. Local opt-in remains scoped to the same peer. Closing the parent cancels all child connections, probes, and retries. Invalid candidates never deliver input.

With `input-metrics-v1`, the child sends `probe` envelopes with a UTF-8 UUID in `data`, once a second, with at most one probe outstanding. The peer replies with `probe-reply` carrying the same UUID. Only a matching pending reply creates an RTT sample, using local monotonic time. A probe older than three seconds closes the unresponsive child and starts negotiated recovery. Probes use the same authenticated sequencing and bounded send queue as input. RTT therefore includes software scheduling and transport queues; it is not display latency. Up to 60 RTT samples and 120 input queue samples stay in memory. Diagnostics record aggregates at most once per ten seconds, without input content or coordinates.

## Keyboard control (0.4.3)

The `keyboard-v1` feature is separate from `mouse-v1`. The mouse `availability` packet carries optional `keyboardEnabled`; missing means false. Keyboard input requires negotiated capability, opt-in on both peers, an accepted mouse session, and the same UUID token. Pairing or capability support alone does not permit input.

A keyboard packet carries `token`, `action` (`down`, `up`, or `modifiers`), macOS virtual `keyCode` (0–127), `flags`, and `isRepeat`. Only Caps Lock, Shift, Control, Option, Command, numeric-pad, and Fn flag bits are accepted. Modifier events must use a known modifier key code. Repeat is allowed only for a held ordinary key-down. Stale-session and wrong-peer events are discarded. Pending mouse motion flushes before keyboard transitions so a click and following text remain ordered.

The sender suppresses a forwarded key locally. The receiver uses its own input language. Leaving, timeout, disconnect, pause, and emergency stop release remote keys and modifiers. Physical keyboard input on the receiver ends control. Control–Option–Escape is consumed locally and is never sent. Secure Event Input stops control rather than being disabled. Media keys, Touch ID, and automatic input-language synchronization are not included.

These key codes are macOS-specific. A Windows adapter needs an explicit key-code mapping and interoperability tests; it must not interpret these values as Windows virtual keys directly.

## Platform API references

- [Apple: event taps](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))
- [Apple: cursor positioning](https://developer.apple.com/documentation/coregraphics/cgwarpmousecursorposition(_:))
- [Apple: event posting permission](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess())
- [Apple: input monitoring permission](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess())

- [Apple: keyboard event construction](https://developer.apple.com/documentation/coregraphics/cgevent/init(keyboardeventsource:virtualkey:keydown:))


### Experimental Dock swipes (build 23)

`dock-swipe-v1` is negotiated on the parent and separate input connection. A `gesture` feature packet contains a current control `token`, `axis` (1 horizontal or 2 vertical), `phase` (1 began, 2 changed, 4 ended, 8 cancelled), finite `progress` (absolute value at most 16), bounded `velocityX/Y` (absolute value at most 10000), and boolean `inverted`. No arbitrary native event data is accepted. The receiving state requires a began phase before updates or termination, and the axis cannot change mid-gesture. Session teardown emits a local cancel for any active received swipe. From build 24, eight seconds without gesture progress also ends control and cancels the swipe; heartbeats do not extend this gesture deadline. Old peers never receive this feature. See [gesture limits](GESTURES.md).


Build 26 ready envelopes may include `osMajor` (integer 10–99). It is diagnostic metadata inside the authenticated message; older peers may omit or ignore it. It does not grant input permission or override negotiated capabilities. Capability logs distinguish the local advertisement, peer advertisement, and negotiated result.
