# Security

NearClip is an early public beta. It has automated security regression tests, but it has not had an independent security audit.

## Trust model

Use NearClip between two Macs that you control. Compare the six digits on both physical screens before accepting a new connection. Installing the same app does not grant access to another Mac's clipboard.

Pairing uses ephemeral Curve25519 key agreement, a commit/reveal exchange, and a six-digit short authentication string. Both devices must approve. The stored pairing secret has 128 bits of randomness and is held in the macOS Keychain. The six digits are not the stored secret.

Clipboard sessions use HKDF-derived directional keys and AES-GCM. Fresh connection nonces bind session keys to the handshake. Encrypted sequence numbers reject replay and reflection. The app limits message sizes before reading frame bodies and checks image dimensions before decoding.

New-pairing discovery closes after a successful pairing. On a saved setup, **Connect another Mac** opens it for at most two minutes. Cancel closes it immediately. Authenticated clipboard sessions and automatic reconnection remain available. Closing discovery does not interrupt delivery of the already-approved confirmation. On first use, discovery stays open until a Mac is paired or the app quits.

Build 16 binds a separate input connection to both authenticated parent hellos, using a distinct HKDF label and fresh child handshake. It checks the expected peer and rejects bulk messages on the input socket. With build 16 peers, either socket's failure invalidates the session. When both peers negotiate build 17 recovery, input loss ends control and clears remote consent, while the authenticated bulk connection stays open. The input socket reconnects with fresh child nonces and sequence keys; a new handoff is required. Losing the parent always closes its child. Old peers retain their previous behavior.

Keychain access uses a small signed helper with the same fixed signing certificate and its own identifier. It accepts only the live signed NearClip parent through private pipes; the app also verifies the helper before launch. The helper can only read/write the existing pairing service/account. It does not expose a network service, grant access to other applications, alter ACLs, or export the signing key. The helper binary is reused across app-only updates to keep its Keychain partition hash stable. Initial helper authorization, a changed helper, a changed certificate, or a locked Keychain can still require user action.

## File and input consent

Pairing authenticates the connection; it does not enable mouse control or accept files. Send File asks the recipient to choose a destination. Build 39 also accepts a file for an app window when both Macs allow input sharing and the file offer matches the active drop. For Finder drops, build 46 can save visible filenames directly in Desktop, Documents, Downloads, and their visible non-package subfolders. The receiver pins the directory identified at release and checks its path. The offer must match the active input session, filename, and recent release. Other resolved folders can receive an explicit folder approval for the current connection. Pausing sharing or disconnecting clears the approval. Both peers must explicitly enable mouse and keyboard sharing. From build 22, the local input-sharing choice is stored for one device ID and its pairing-group fingerprint. The fingerprint is not a pairing secret. A new pairing key cannot inherit the choice. App termination preserves the choice, but never a control token or remote availability. New installations remain off until the user enables sharing. Sleep, screen lock, inactive sessions, and temporary disconnection remove capture and release held input, but retain that choice. Readiness resumes only after all observed suspension conditions end, the same peer authenticates, and native permission checks pass. A fresh handoff and peer availability are still required. Explicit stop, emergency stop, permission loss during use, pause, pairing replacement, and a different peer clear the choice. Pause stops mouse control and cancels file transfers.

Mouse packets carry a fresh control-session UUID and a small whitelist of mouse actions. The receiver rejects stale sessions, unsupported buttons, invalid deltas, and unapproved entry requests. Keyboard support is negotiated as `keyboard-v1`. During an accepted handoff, the app transmits virtual key codes, up/down transitions, repeat state, and allowed modifier flags through the encrypted channel. The receiver requires the same session token and both peers’ explicit opt-in. Key events are not logged or persisted. Only currently held keys are tracked in memory for cleanup. The event tap is installed only while input sharing is enabled. The receiving Mac’s input source determines the text.

An accepted session exchanges heartbeats. A two-second loss of session traffic restores control and releases remotely held buttons and keys. Physical input on the receiving Mac, explicit stop, permission loss, and sleep also stop control. Secure Event Input stops control; the app never disables that protection. Permission revocation, screen lock, secure input, and display changes need physical-device testing; this beta has not proven all operating-system transitions.

Files use bounded chunks, receiver acknowledgments, and final size/SHA-256 verification. File I/O runs off the input/UI run loop. Sender paths are never used as destination paths. The macOS receiver creates private temporary files, applies quarantine metadata, and commits without overwriting an existing destination. It never opens the received file. Quarantine is a platform security signal, not malware scanning. Only accept files from a Mac you trust.

## Data handling

- New received clipboard items use Apple’s current-host-only option by default to prevent their onward Universal Clipboard sharing. This setting does not control other apps’ copies, already-shared content, or manual re-copying. No system Handoff setting is changed.
- Clipboard content stays in memory and the system clipboard. NearClip does not keep clipboard history or send telemetry. Ordinary transfers are written to the recipient-selected location. Native app drops retain the verified file in a private, uniquely named folder under the NearClip user cache so the target app can read it later.
- macOS preferences store the device ID, logical clock, settings, approved peer name, reconnect address, and shared screen layout. These values are not pairing secrets.
- Bonjour exposes a device name, device ID, service port, and a group discovery hint on the local network. These are not secret.
- The app skips clipboard entries marked concealed or transient. Applications that omit those markers can still expose sensitive text. Pause sharing before copying content that must remain on one Mac.
- Pause blocks clipboard content, stops mouse sharing, and cancels file transfers. Network discovery and authenticated connections can remain active. Quit closes listeners, connections, and event taps.
- Reset replaces the pairing secret and removes the saved direct route. It does not clear either Mac's system clipboard.

## Limitations

The protocol is application-specific and is not TLS. Reconnecting sessions do not provide forward secrecy against later compromise of the stored pairing secret. Local malware with access to the clipboard or unlocked keychain is outside the trust model. The app does not guarantee protection against network denial of service.

The current beta uses a persistent local certificate. Its private key stays in the developer’s login Keychain and is not shipped. Package builds require a stable signing identity and do not silently fall back to ad-hoc signing. This is not Apple Developer ID signing or notarization. The signature binds updates to the same signing key; it does not establish Apple trust. Code signing identity is separate from transport encryption.

## Reporting

Do not put secrets or exploit details in public issues. Use the repository's private vulnerability reporting feature when available. If it is unavailable, open an issue that requests a private contact method and omits sensitive details.

## Local diagnostics

Build 15 records fixed control/connection reason codes, counts, queue waits, and processing durations in the local macOS unified log. Input content, pointer coordinates, clipboard data, names, network addresses, file paths, and pairing secrets are not included in these application diagnostic messages. The collection script reads only these categories and does not upload them. This does not control what macOS itself records in its own diagnostic categories.

## Update checks

Build 17 can request public release metadata from `api.github.com` once a day. The setting can be disabled. Requests use an ephemeral session with no cookies or credential store; they do not contain a device ID, peer identity, pairing key, clipboard, file, or input content. GitHub receives normal connection metadata such as the public IP address. HTTP redirects are rejected. Download links must use HTTPS and the exact `github.com/iyk2h/nearclip/releases/download/` path. In build 21, explicit install actions use the separate verified updater described below. Automatic metadata checks never install an update. Drafts, malformed versions, unsupported assets, and older versions cannot become an offered upgrade.

## In-app updates

Build 21 includes Sparkle 2.10.1 in a separate, signed `NearClipUpdater.app`. The build pins the SHA-256 digest of Sparkle's official archive. The main app verifies the updater's designated signing requirement and nested code before opening it. The updater accepts only its enclosing, same-signer NearClip bundle as the installation target.

The feed URL is pinned to this repository's `updates/appcast.xml`. Update downloads are restricted to this repository's HTTPS GitHub release paths. Sparkle must verify the appcast signature and the update archive's Ed25519 signature before extraction. Signed-feed validation failures never expire into an unsigned fallback. The release signing key is unique to NearClip and stays in the maintainer's login Keychain. No private key, GitHub token, pairing secret, or clipboard content is included in requests or releases. System profiling is disabled.

The appcast carries the product bundle identifier. `SURequireFeedBundleIdentifier` is retained for forward compatibility; Sparkle 2.10.1 does not implement that newer feed-level option. Archive target matching is enforced by Sparkle's installer. The dedicated NearClip signing key is not shared with other products.

The local beta uses a persistent self-signed certificate and is not notarized. Its main app and fixed Keychain helper retain hardened runtime. The separate updater cannot use library validation with a self-signed certificate without an Apple Team ID; its bundle and embedded framework are signed and verified before launch. It does not read pairing keys or request input-control permissions. Developer ID distribution enables hardened runtime on the updater as well.

Installation requires an explicit user choice. Existing file transfers must finish or be cancelled before opening the updater. App termination releases held input and closes transport. An ordinary restart does not automatically grant input control; the user enables it again. Sparkle handles installation and relaunch; the app does not run downloaded shell scripts or request root access itself.


Development build 23 negotiates `dock-swipe-v1` for experimental system swipes. It accepts only bounded, typed gesture fields on an authenticated input connection, during an accepted receiving session with both input opt-ins. It does not deserialize arbitrary CGEvent data. Session teardown cancels an active received swipe. The native adapter uses undocumented Dock fields and is disabled on unknown OS generations; physical gesture behavior remains unverified.
