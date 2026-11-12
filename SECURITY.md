# Security

NearClip is an early public beta. It has automated security regression tests, but it has not had an independent security audit.

## Trust model

Use NearClip between two Macs that you control. Compare the six digits on both physical screens before accepting a new connection. Installing the same app does not grant access to another Mac's clipboard.

Pairing uses ephemeral Curve25519 key agreement, a commit/reveal exchange, and a six-digit short authentication string. Both devices must approve. The stored pairing secret has 128 bits of randomness and is held in the macOS Keychain. The six digits are not the stored secret.

Clipboard sessions use HKDF-derived directional keys and AES-GCM. Fresh connection nonces bind session keys to the handshake. Encrypted sequence numbers reject replay and reflection. The app limits message sizes before reading frame bodies and checks image dimensions before decoding.

New-pairing discovery closes after a successful pairing. On a saved setup, **Connect another Mac** opens it for at most two minutes. Cancel closes it immediately. Authenticated clipboard sessions and automatic reconnection remain available. Closing discovery does not interrupt delivery of the already-approved confirmation. On first use, discovery stays open until a Mac is paired or the app quits.

## File and mouse consent

Pairing authenticates the connection; it does not enable mouse control or accept files. A file needs a recipient-chosen destination. Both peers must explicitly enable mouse sharing. Input consent is not persisted across app restarts and is revoked when the peer is lost. Pause stops mouse control and cancels file transfers.

Mouse packets carry a fresh control-session UUID and a small whitelist of mouse actions. The receiver rejects stale sessions, unsupported buttons, invalid deltas, and unapproved entry requests. Keyboard text is not transmitted or logged. A local event tap observes key-down events only to implement emergency stop and local takeover. It is installed only while mouse sharing is enabled.

An accepted session exchanges heartbeats. A two-second loss of session traffic restores control and releases remotely held buttons. Local input, explicit stop, permission loss, and sleep also stop control. Permission revocation, screen lock, secure input, and display changes need physical-device testing; this beta has not proven all operating-system transitions.

Files use bounded chunks, receiver acknowledgments, and final size/SHA-256 verification. File I/O runs off the input/UI run loop. Sender paths are never used as destination paths. The macOS receiver creates private temporary files, applies quarantine metadata, and commits without overwriting an existing destination. It never opens the received file. Quarantine is a platform security signal, not malware scanning. Only accept files from a Mac you trust.

## Data handling

- Clipboard content stays in memory and the system clipboard. NearClip does not keep clipboard history or send telemetry. Accepted file content is written to the recipient-selected location.
- macOS preferences store the device ID, logical clock, settings, approved peer name, reconnect address, and shared screen layout. These values are not pairing secrets.
- Bonjour exposes a device name, device ID, service port, and a group discovery hint on the local network. These are not secret.
- The app skips clipboard entries marked concealed or transient. Applications that omit those markers can still expose sensitive text. Pause sharing before copying content that must remain on one Mac.
- Pause blocks clipboard content, stops mouse sharing, and cancels file transfers. Network discovery and authenticated connections can remain active. Quit closes listeners, connections, and event taps.
- Reset replaces the pairing secret and removes the saved direct route. It does not clear either Mac's system clipboard.

## Limitations

The protocol is application-specific and is not TLS. Reconnecting sessions do not provide forward secrecy against later compromise of the stored pairing secret. Local malware with access to the clipboard or unlocked keychain is outside the trust model. The app does not guarantee protection against network denial of service.

The release binary is ad-hoc signed unless release notes explicitly state Developer ID signing and notarization. Code signing identity is separate from transport encryption.

## Reporting

Do not put secrets or exploit details in public issues. Use the repository's private vulnerability reporting feature when available. If it is unavailable, open an issue that requests a private contact method and omits sensitive details.
