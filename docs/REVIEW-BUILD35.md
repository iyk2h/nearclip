# Build 35 review

This is a local beta validation build. Version 1.0.0 and public publication remain deferred.

## Input recovery

The live build 33 trace showed repeated peer handshake timeouts while the clipboard connection stayed authenticated. It did not record whether TCP connected or the authentication reply stalled, so it cannot establish the original cause.

Code review found two independent recovery defects:

- A listener that returned to `ready` could send the plaintext hello again into an already authenticated stream.
- A cancelled input listener was retained without recreation; a failed listener closed the parent clipboard/file connection.

Build 35 sends hello only once and recreates the receiving input listener on its existing advertised port. Recovery keeps the authenticated parent and its session-derived input key. Listener retries back off and stop on shutdown. Two authenticated peer handshake-timeout reports can refresh an idle listener; reports never replace a healthy input session.

Input handshakes now have their own bounded deadline. A network `waiting` error releases an unready input attempt for backoff instead of occupying the slot until the parent timer runs. Diagnostics report connecting, waiting for hello, authenticating, or ready, with bounded error codes. No keys, input content, cursor positions, or addresses are logged. Old peers can omit the new optional diagnostic fields.

These changes address reproducible recovery paths. They do not prove which path caused the earlier physical failure.

## Update installation

The failed build 33 installation logged an agent timeout at 14:00:22. Its agent only reached AppKit/Launch Services at 14:00:37. The generic Team ID text was not evidence of a certificate mismatch.

An isolated installation from a signed test fixture to the unmodified build 34 bundle succeeded on this Mac. This establishes that the existing signing configuration can install an update; the earlier startup delay remains intermittent.

Build 35 keeps archive signatures, signed-feed checks, the pinned repository, component validation, and the fixed Keychain helper. A transient download/installer error offers a user-controlled retry after the previous Sparkle cycle ends. Each attempt repeats normal verification. Signing, validation, downgrade, and cancellation errors do not use this retry path. Installation phases and error codes are recorded without file paths or credentials.

## Input status

The main window distinguishes off, disconnected, permission needed, recovering, suspended, waiting for the peer's consent, and ready. It does not claim an active session just because the transport connected. The main status stays stable during normal handoffs. Detailed settings identify active NearClip control; they do not claim to detect Apple Universal Control.

## Validation boundary

694 regression checks and 59 packaged lifecycle checks passed. Packaged Bonjour pairing, encrypted clipboard transfer, file integrity, screen layout, and shutdown passed. The 95-check network subset includes a silent input endpoint, repeated listener readiness, lost listener recreation on the same port, and five successive input interruptions during a retained parent session. Restoring the old duplicate-hello behavior in a separate source fixture caused the new real-socket regression test to fail as expected.

The build 35 updater was tested with a missing loopback feed (HTTP 404), the Retry action, and then a valid signed feed. The resulting installed test bundle exactly matched the signed build 35 bundle. The local production app retained pairing and both peers' sharing readiness after replacement. This does not show that the earlier delayed installer startup cannot recur.

Automated checks use synthetic input, temporary pasteboards, and loopback TCP. They do not move the physical cursor or type into user documents. The user deferred physical testing on November 17. Two-Mac gesture direction, sustained latency, wake, and concurrent large transfers must remain unverified for this build until that test is performed.
