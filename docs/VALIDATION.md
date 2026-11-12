# 0.3.0 validation

Validated on an Apple Silicon Mac. This is a public beta, not a claim of full production or accessibility certification.

## Iteration 1: App controls

The previous window had no visible Quit control. Closing the window left sharing active.

Added a visible Quit button, standard application menus, Command-Q and Command-W, a close-action choice, and a saved close preference. Added a settings page for login startup and disconnect.

The packaged lifecycle diagnostic passed 10 checks: menu-bar Quit, Command-Q registration, pause state, resume state, settings navigation, keep-running close, menu-bar-only activation, window reopening, quit request, and termination callback. The close-choice sheet and macOS login-item approval still need manual testing on additional machines.

## Iteration 2: Connection recovery

The previous two-service discovery had failed under the installed app identity. Pairing and clipboard discovery now share one declared service with distinct name prefixes.

Added direct pairing addresses and authenticated reconnect-port exchange. Saved routes are created only after both confirmations. Simultaneous connections select the same physical connection. Shutdown clears sessions. Stale discovery callbacks are ignored after restart.

The regression suite passed **75 checks**, including real local TCP, image fidelity, framing limits, tampering, replay, pause, numeric pairing, address parsing, direct pairing, direct transfer, and shutdown. A separate diagnostic inside the actual packaged app passed Bonjour pairing, encrypted synthetic transfer, and connection cleanup.

## Iteration 3: UI and distribution

Screenshots exposed broken tab rendering and missing backgrounds. Replaced the tab header with native buttons and rendered with the effective appearance. Reduced the window height, used monospaced status and address text, and added address copy.

The final screens were rendered and visually inspected:

1. **Connection — pass:** state and main controls are visible. Address fallback is below nearby discovery. [Screenshot](connection.png)
2. **Settings — pass:** close behavior, login startup, and disconnect are separated from pairing. [Screenshot](settings.png)
3. **Connected — pass:** the approved peer and last activity appear above the controls. [Screenshot](connected.png)
4. **Paused — pass:** the screen states that sending and receiving are paused. Manual send is disabled. [Screenshot](paused.png)

These screenshots use synthetic state and do not prove a remote Mac is connected. Native accessibility inspection found labeled buttons and tabs. Full VoiceOver, contrast, and keyboard traversal audits were not completed.

The universal binary includes arm64 and x86_64. The package has an ad-hoc signature. A DMG, ZIP, and checksums are provided. No valid Developer ID signing identity was available, so this release is not notarized.

## Remaining physical-device checks

The earlier 0.2 build was used successfully on two physical Macs. The 0.3 changes have local integration and packaged diagnostics coverage, but have not yet been verified across two physical Macs. Check sleep/wake, router changes, VPN behavior, Intel runtime, and login startup before calling this a stable release.
