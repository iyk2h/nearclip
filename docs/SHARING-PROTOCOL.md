# Sharing protocol and Windows path

Protocol additions in NearClip 0.4.0. This document describes the current implementation, not a Windows client release. A Windows port requires its own clipboard, file-system, input, permissions, and packaging adapters, plus interoperability tests.

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
["files-v1", "mouse-v1"]
```

A peer without these capabilities continues to exchange clipboard messages. Never send a feature packet unless the authenticated peer advertised that capability. Missing features mean unsupported, not implicit consent.

A `feature` envelope has a Base64 `data` field. Its decoded value is UTF-8 JSON with exactly one key: `file` or `mouse`. Feature JSON is limited to 128 KiB. The transport queues at most 32 feature packets. File I/O accepts at most eight queued packets and cancels an overloaded transfer.

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

## Shared screen layout

A `layout` mouse packet includes:

```json
{"revision": 1, "author": "DEVICE-A", "left": "DEVICE-A", "right": "DEVICE-B"}
```

The identifiers must name exactly the two authenticated peers. The higher revision wins. Equal revisions compare author identifiers lexicographically. A local edit increments the highest observed revision. This makes the two views complementary and prevents feedback loops. The layout is stored locally and shared through the encrypted channel.

Only horizontal left/right arrangement is supported in 0.4. The operating system supplies its own monitor rectangles. Local monitor seams must not trigger remote handoff.

## Mouse control

`availability` advertises explicit local opt-in. It is separate from capability support. Both peers must opt in. Opt-in is not saved across app restarts. Losing the peer revokes local input consent.

1. Push against the configured outer edge for at least 150 ms with no buttons or modifiers held.
2. Send `enter` with a fresh UUID `token`, the receiver's entry `side`, and vertical `fraction` from 0 to 1.
3. The receiver accepts only when enabled, idle, and outside the short handoff cooldown. It replies `accepted`, or `deny`.
4. Only after acceptance does the sender suppress its local mouse events.
5. `input` carries `move`, `down`, `up`, or `scroll`. Each input must name the active token. Deltas are finite and bounded to ±4096; buttons are left/right/middle. Only Shift, Control, Option, and Command modifier bits are allowed.
6. Moves are coalesced at 60 Hz. Button transitions flush pending moves first. Input packets remain ordered within the encrypted TCP stream.
7. Moving back over the entry edge with no button held sends `leave`, including normalized height. The original Mac restores its cursor inside the edge.

Each active peer sends a heartbeat every 500 ms. A request times out after one second; an active session times out after two seconds without authenticated session traffic. Leaving, disconnecting, permission loss, or cancellation releases all remotely held buttons. Local physical input on the recipient reclaims control. Typing remains local and ends remote mouse control.

On macOS, Control–Option–Escape disables mouse sharing. Capture uses a session event tap; generated events carry a marker to avoid recapture. The app requests Accessibility and Input Monitoring only when the user enables mouse sharing. It also stops input on sleep, session deactivation, and the available screen-lock notification. Permission, lock-screen, and secure-input behavior still require physical-device validation.

Files and mouse messages currently share the clipboard TCP channel. Small file chunks limit blocking, but a large clipboard frame or a slow link can delay mouse traffic. The watchdog returns control instead of keeping the source captured indefinitely. Separate interactive and bulk channels are a possible follow-up after physical latency measurements.

## Platform API references

- [Apple: event taps](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))
- [Apple: cursor positioning](https://developer.apple.com/documentation/coregraphics/cgwarpmousecursorposition(_:))
- [Apple: event posting permission](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess())
- [Apple: input monitoring permission](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess())
