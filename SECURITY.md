# Security

NearClip is an early public beta. It has automated security regression tests, but it has not had an independent security audit.

## Trust model

Use NearClip between two Macs that you control. Compare the six digits on both physical screens before accepting a new connection. Installing the same app does not grant access to another Mac's clipboard.

Pairing uses ephemeral Curve25519 key agreement, a commit/reveal exchange, and a six-digit short authentication string. Both devices must approve. The stored pairing secret has 128 bits of randomness and is held in the macOS Keychain. The six digits are not the stored secret.

Clipboard sessions use HKDF-derived directional keys and AES-GCM. Fresh connection nonces bind session keys to the handshake. Encrypted sequence numbers reject replay and reflection. The app limits message sizes before reading frame bodies and checks image dimensions before decoding.

New-pairing discovery closes after a successful pairing. On a saved setup, **Connect another Mac** opens it for at most two minutes. Cancel closes it immediately. Authenticated clipboard sessions and automatic reconnection remain available. Closing discovery does not interrupt delivery of the already-approved confirmation. On first use, discovery stays open until a Mac is paired or the app quits.

## Data handling

- Clipboard content stays in memory and the system clipboard. NearClip does not keep history or send telemetry.
- macOS preferences store the device ID, logical clock, settings, approved peer name, and reconnect address. These values are not pairing secrets.
- Bonjour exposes a device name, device ID, service port, and a group discovery hint on the local network. These are not secret.
- The app skips clipboard entries marked concealed or transient. Applications that omit those markers can still expose sensitive text. Pause sharing before copying content that must remain on one Mac.
- Pause blocks outgoing and incoming clipboard content. Network discovery and authenticated connections can remain active. Quit closes the listeners and connections.
- Reset replaces the pairing secret and removes the saved direct route. It does not clear either Mac's system clipboard.

## Limitations

The protocol is application-specific and is not TLS. Reconnecting sessions do not provide forward secrecy against later compromise of the stored pairing secret. Local malware with access to the clipboard or unlocked keychain is outside the trust model. The app does not guarantee protection against network denial of service.

The release binary is ad-hoc signed unless release notes explicitly state Developer ID signing and notarization. Code signing identity is separate from transport encryption.

## Reporting

Do not put secrets or exploit details in public issues. Use the repository's private vulnerability reporting feature when available. If it is unavailable, open an issue that requests a private contact method and omits sensitive details.
