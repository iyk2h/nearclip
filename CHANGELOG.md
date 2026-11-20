# Changelog

## 0.4.4 build 50

Drag a Finder file back with the mouse on your own Mac, even when you approach the shared edge diagonally. NearClip uses the native drag location and ignores stray modifier releases during pickup. Update the Mac that holds the original file.

## 0.4.4 build 49

Chat apps can redraw their attachment field as you release a file. NearClip now completes the drop when the field refreshes under the pointer in the same window. Update the receiving Mac.

## 0.4.4 build 48

Use one mouse to pick up a file on the other Mac and drag it back to a folder or an app on your own screen. Both Macs need build 48.

## 0.4.4 build 47

Drag a file across the shared screen edge in one motion. The sending Mac no longer shows a Copy to Mac panel. On the receiving Mac, images show their preview without flashing the filename. An image icon appears if the preview takes longer or is unavailable.

## 0.4.4 build 46

Drop a file on the other Mac’s Desktop, Documents, Downloads, or an ordinary folder inside one of them to save it there immediately. NearClip gives a second copy a numbered name. Send File and other Finder destinations still let the recipient choose where to save. Update the receiving Mac for this change.

## 0.4.4 build 45 — 2026-11-20

- If an image drop misses its app, drag the received file from NearClip to retry. Mouse sharing stays available.
- Releasing an active image drag checks the app under the pointer. Finder drops and manual transfers keep their local save approval.

## 0.4.4 build 44 — 2026-11-20

- Image drags show the thumbnail alone. The filename appears while a preview is unavailable.
- On a receiving Mac with build 44, apps can recognize a prepared image as a local file while you hover and show their own copy feedback. The sending Mac needs build 43 or later for early transfer.

## 0.4.4 build 43 — 2026-11-20

- Drag an image across the shared edge to start transferring it while the mouse button is held. A small thumbnail travels ahead of the file and follows the pointer. Release over an app to attach it.
- PNG and TIFF drags from apps can now use the same path as image files from Finder. Both Macs need build 43 for early transfers. The regular file transfer remains available for older peers and files over 20 MiB.

## 0.4.4 build 42 — 2026-11-19

- Drop files into apps that show a new drop zone when you hover. Small pointer movements over the same control during transfer are OK.
- If a drop fails, drag the received file directly from the Files card to try again. Double-click its name to reveal it in Finder.

## 0.4.4 build 41 — 2026-11-19

- Two build 41 Macs can send up to three file chunks before waiting for a receipt. Older peers keep the single-chunk transfer mode.
- Short file transfers finish in the background. Longer transfers show progress and a cancel button.
- A successful drop into an app clears the progress bar and Finder shortcut. If the target declines the file, use **Show in Finder** to recover it.

## 0.4.4 build 40 — 2026-11-19

- Release a file over the other Mac to start its transfer as soon as you let go. The sender keeps Finder’s drag at the shared edge while the remote pointer moves.

## 0.4.4 build 39 — 2026-11-19

- Drop a file into an app window on the other Mac. The receiving app decides whether it accepts the file. Keep the pointer over the target until the transfer finishes. Both Macs need input sharing enabled.
- Keep the sending cursor at its original height when capturing movement after a handoff. Automated tests cover entry near the top and bottom in both directions.

## 0.4.4 build 37 — 2026-11-18

- Drag one file across the shared screen edge into Finder on another build 37 Mac. The receiver can approve a folder for subsequent drops during the current connection.
- The original remains on the sending Mac. If Finder does not expose a destination, the receiver chooses where to save the file.

## 0.4.4 build 36

- NearClip opens in English by default. Choose Korean under Settings → Language and reopen the app to apply it.
- Includes input connection recovery and update retry improvements from builds 34 and 35.

## 0.4.4 build 35 — local validation

- Keep input listener recovery separate from clipboard and file connections. Prevent duplicate hello messages after network readiness changes.
- Bound stalled input handshakes independently and report the failed connection stage.
- Show explicit input sharing states and distinguish readiness from active control.
- Offer a verified retry for transient update failures; retain all signing and feed checks.
- Physical two-Mac validation is deferred. The original intermittent handshake and installer startup failures are not claimed fully resolved.

## 0.4.4 build 34 — local validation

- Keep the mouse and keyboard switch available during input-channel recovery. Turning sharing off no longer prevents turning it back on.
- Save an explicit enable choice for the authenticated peer while its input connection recovers. Start capture only after reconnection and existing permission and session checks.
- Distinguish a pending enable choice from active input sharing. The menu bar and main window use the same behavior.
- This change does not resolve the separate input-handshake timeouts observed with build 33.

## 0.4.4 build 33 — 2026-11-17

- Move clipboard change-count checks, baseline reads, final validation, and writes off the main thread. Build 32 still performed these potentially blocking operations beside input callbacks.
- Keep polling bounded without replacing queued incoming content or an explicit resend. Retain the newest incoming copy while the initial clipboard baseline is pending.
- Preserve local-copy checks and invalidate queued writes when sharing pauses or disconnects. An OS write already in progress cannot be cancelled.
- Report invalid local images once per clipboard change instead of decoding the same invalid content on every poll.
- Record local probe scheduling delay when a connection closes, including a close received before the next timer callback.
- Input timeout and key-release limits are unchanged. Physical confirmation of the remaining peer timeouts is still required.

## 0.4.4 build 32 — 2026-11-17

- Read clipboard data and prepare image formats on a bounded serial worker. Slow clipboard providers and image conversion no longer run on the input callback thread.
- Discard stale clipboard results after newer copies, pause, disconnect, or stop. Keep confidential-content filtering and native PNG/TIFF support.
- Recheck an expired diagnostic probe when authenticated input still arrives or the local run loop was delayed. Silent peers still time out; input safety-release limits remain unchanged.
- Share bounded input-close reasons over the authenticated bulk connection when both Macs support them. Older peers do not receive new message types.
- Repeated physical peer closures still need confirmation with both Macs updated. The earlier `peerClosed` logs did not identify the remote cause.

## 0.4.4 build 31 — 2026-11-17

- Read available input bytes in bounded chunks. Complete frames run in order without separate header and body callbacks for every message.
- Keep a 4 KiB input frame limit and a 64 KiB receive limit. Partial frames stay bounded. Authentication and replay checks remain unchanged.
- Measure mouse send and receive intervals. The diagnostics distinguish steady source input from delivery bursts without synchronizing the Macs' clocks.
- No prediction or intentional smoothing delay is added. Physical smoothness and network latency need a controlled two-Mac comparison.

## 0.4.4 build 30 — 2026-11-17

- Show which Mac has Secure Event Input active. Keep the sharing choice and clear the pause after protected input ends.
- Reconcile held keys after secure input. A missed key release no longer leaves screen-edge entry blocked.
- Send accumulated mouse movement when the transport becomes writable, without waiting for another timer tick.
- Validate received feature packets without encoding them again. Packet size, content, and authentication checks remain in place.
- These changes reduce avoidable application work. They do not establish that the observed network latency spikes are resolved.

## 0.4.4 build 29 — 2026-11-16

- Horizontal gestures on macOS 27 use its posting direction and local natural-scroll preference. Vertical gestures keep their existing direction.
- An input route that becomes available after authentication triggers an automatic retry. The bulk connection stays open.
- The expanded suite covers direction across OS versions, axes, phases, signs, and both natural-scroll settings.
- Physical direction confirmation after this update remains pending. Intermittent network latency remains unresolved.

## 0.4.4 build 28 — 2026-11-16

- Gesture negotiation includes macOS 27. The adapter adds its required local IOHID payload.
- The source Mac receives a neutral terminal event after a forwarded swipe to close local Dock tracking.
- The adapter restores the echo-prevention marker after native event conversion.
- Unknown OS generations remain disabled. Peer messages still contain only validated gesture fields.
- Physical gestures on macOS 27 remain experimental. This release does not claim to fix the remaining network latency spikes.

## 0.4.4 build 27 — 2026-11-16

- The input channel sends up to four small frames without waiting for each send completion. Packet order and the queue limit stay fixed.
- Input connections use responsive traffic priority and disable TCP acknowledgment stretching. Bulk connections keep their existing settings.
- Active remote control prevents App Nap. Idle system sleep remains available.
- The signed update feed includes this build. Existing users can update inside NearClip on both Macs.
- This release includes the clipboard, gesture, and diagnostic changes from local builds 23–26. Physical four-finger behavior remains unverified.

## Local test — 0.4.4 build 26

- Read the kernel product version before falling back to Foundation for gesture compatibility checks.
- Observe Dock-control and companion gesture events; suppress companions during a forwarded swipe.
- Include an optional OS major version in the authenticated ready message and show clearer capability-failure guidance.
- Add bounded gesture/capability diagnostics without clipboard content, key codes, or coordinates.
- The reported physical four-finger failure is not yet verified as resolved. Build 25 was a local diagnostics-only build.

## Local test — 0.4.4 build 24

- Keep duplicate gesture-start events from reaching the source Mac's Dock during remote control.
- Cancel a stalled swipe after eight seconds without gesture progress, even if heartbeats continue.
- Stop received mouse input immediately when Secure Event Input becomes active.
- Reject truncated PNG clipboard data before replacing existing content.
- Explain gesture support and finger-count settings in expanded mouse controls.
- Extend regression coverage for sleep/lock, stale file callbacks, destination races, and gestures during bulk transfers.

## Local test — 0.4.4 build 23

- Add experimental continuous three-/four-finger Dock swipe forwarding during accepted remote control.
- Cancel active swipe animations on session end and reject stale or malformed gesture packets.
- Keep legacy peers compatible through capability negotiation. Physical gesture behavior is not yet verified.

## 0.4.4 build 22 — 2026-11-16

- Use compact native cards for clipboard, input, and files. Keep screen arrangement optional and move diagnostics into Settings.
- Remember input sharing for the same authenticated pairing across app restarts and updates. Explicit stop and emergency stop clear the choice.
- Use a fresh discovered route after a short saved-address attempt. Retry failed connections with bounded backoff.
- Give one peer priority for startup dialing. Keep a timed direct fallback when discovery cannot connect.
- Hide permission repair buttons after approval. Retry a remembered choice when permissions become available, without another permission prompt.
- Keep the existing signing identity, Keychain helper, and signed update channel.

## 0.4.3 builds 13–21 — 2026-11-16

- Add signed in-app updates, a separate input connection, input recovery, and connection diagnostics.


- Build 15 moves bulk clipboard preparation and large-frame decoding off the input thread, bounds ordinary movement in flight, and reduces idle input maintenance to 1 Hz.
- Add content-free input/transport diagnostic logs and a scoped collection script. See the measured [runtime review](docs/PERFORMANCE-REVIEW.md) for evidence and remaining bottlenecks.

- Build 14 sends the first mouse sample immediately, batches continuous movement at the existing 120 Hz target, and flushes movement before clicks or modifier changes. Reuse the native event source for received pointer events.
- Keep the main status and menu status stable during pointer handoffs. Keep the edge indicator; do not show a diagnostic line for a normal edge return.

- Build 13 keeps peer-specific sharing enabled across sleep and temporary disconnection. Resume only after unlock/session restoration; explicit stop and emergency stop remain off.
- Target 120 Hz cursor batching, preserve trackpad scroll/momentum phases, and display the build number to distinguish test packages. Native three-/four-finger system gestures remain unsupported.

- Show a click-through vertical edge bar while crossing, then a thin control marker.
- Share keyboard input during accepted handoffs, after both peers opt in and negotiate support. Release held keys on return, timeout, and stop.
- Stop input when macOS Secure Event Input is active; never forward the emergency chord.
- Use one persistent signing identity for beta packages and verify identity across updates.

- Keep remote mouse control when the receiver gets a mouse event with zero movement.
- Prevent immediate return at the entry edge: move into the receiving screen before a sustained outward push can return control. Reset the push after a pause, inward motion, a click, or a new session.
- Show the last return reason and the Mac that ended control. Send only a fixed reason code to the paired Mac; keep it in memory.
- Require an accepted handoff before each mouse regression scenario. Restore both peers' availability in the reconnect test.
- Build 12 was confirmed receiving control from a second physical Mac after the entry-edge fix. Reverse-direction and extended input testing remain outstanding.

## 0.4.2 — 2026-11-12

- Combine connection, mouse sharing, and file transfer on one screen.
- Expand or collapse screen arrangement and permissions below the mouse toggle; keep settings inline.
- Show missing input permissions separately and check again when the app becomes active. Request only the missing permission from an explicit enable action.
- Default new received clipboard items to Apple current-host-only scope, with an option to allow Apple relay. This does not block other apps or change Handoff settings.
- Add Keychain and Apple Continuity guidance with explicit limitations.
- Keep automated diagnostics offscreen and out of the Dock.

## 0.4.1 — 2026-11-12

- Replace the left/right menu with draggable monitor cards for the two paired Macs.
- Apply a completed drop to both Macs through the existing authenticated layout protocol.
- Add a keyboard-accessible Swap order button and cancel incomplete drags on Escape, connection changes, or remote layout changes.
- Keep arrangement edits unavailable during remote mouse control.
- Show connection state, identify this Mac, and update the English setup guide.

## 0.4.0 — 2026-11-12

- Add explicit single-file transfer, up to 2 GiB, with recipient acceptance, progress, cancellation, checksums, and safe saving.
- Add opt-in mouse movement, clicking, dragging within the remote Mac, and scrolling across an outer screen edge.
- Synchronize left/right screen layout between the paired Macs.
- Add Control–Option–Escape, local takeover, heartbeats, held-button cleanup, and input consent revocation on disconnect.
- Keep file I/O off the input run loop and bound transfer queues.
- Negotiate features through the authenticated channel while retaining clipboard-only peer support.
- Document the portable message format and remaining work for a Windows client.
- Mark mouse/file features experimental until physical two-Mac validation is complete.


## 0.3.1 — 2026-11-12

- Replace the nearby-device picker with named device rows and individual Connect buttons.
- Separate first-use discovery from daily sharing. Show saved-device identity and offline reconnection state.
- Close new-pairing discovery after approval. Require an explicit, two-minute invitation to replace a saved pairing.
- Put address entry and permission help behind a disclosure. Keep pause, send, and Quit easy to reach.
- Reduce window size in daily use and refine native light/dark styling.
- Document 13 design references and update the English setup guide.


## 0.3.0 — Public beta

- Add a visible Quit button and standard Command-Q / Command-W shortcuts.
- Ask whether to quit or stay in the menu bar when closing the window. Allow the user to remember the choice.
- Split connection controls and preferences into tabs. Support light and dark appearance.
- Add login-at-startup controls, disconnect confirmation, pairing cancellation, and a selectable local address.
- Use one declared Bonjour service with distinct pairing and clipboard names.
- Exchange authenticated reconnect ports during pairing and save approved direct routes.
- Resolve simultaneous connections deterministically. Clear active connections on shutdown.
- Add tests for direct pairing, direct transport, address validation, and lifecycle cleanup.
- Add a universal build, DMG packaging, checksums, CI, and public documentation.

This beta is not notarized. Cross-device compatibility and sleep/wake coverage are described in the release validation notes.
