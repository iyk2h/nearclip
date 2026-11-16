# Experimental trackpad gestures — build 28

NearClip forwards horizontal and vertical Dock swipes for Spaces, Mission Control, and App Exposé. It sends continuous progress and end or cancel phases. It does not replace a swipe with a fixed keyboard shortcut.

Both peers must advertise `dock-swipe-v1`. Both users must enable input sharing, and the pointer must cross to the other Mac first. The source Mac recognizes three- or four-finger swipes from its trackpad settings. NearClip does not change those settings. Pinch, rotation, and arbitrary touch contacts are excluded.

## macOS compatibility

The adapter supports the native event layouts for macOS 13–27. This range is not a claim of physical testing on each version. Unknown OS generations keep gestures local.

Build 27 logs established that the affected peer reported macOS 27. The previous 13–26 gate disabled its gesture capability. Build 28 adds the IOHID payload that macOS 27 requires, rather than only extending that gate.

NearClip constructs the payload locally from validated axis, phase, progress, and velocity fields. It does not accept serialized native events from a peer. The adapter restores the echo-prevention marker after native conversion, which otherwise clears that marker. On macOS 27, a neutral physical terminal event closes the source Dock gesture state after forwarding.

## Session boundaries

A current authenticated session, receiving role, both input choices, and the negotiated capability are required. Secure Event Input stops control. Disconnect, timeout, lock, pause, and session end cancel the active received gesture. A swipe without progress for eight seconds also cancels, even if connection heartbeats continue.

Duplicate starts cannot leak to the source Dock during remote control. Companion events remain suppressed while NearClip owns the swipe.

## Validation limits

Tests construct and inspect native events without posting system input. Coverage includes byte offsets, signed fixed-point values, native conversion, the echo marker, phase ordering, stale tokens, unknown senders, cancellation, and legacy fallback.

The build 28 adapter tests run on macOS 15.7.2. A physical test forwarded gestures from macOS 27 to macOS 15.7.2 after a peer restart. The user confirmed horizontal swipes, vertical gestures, and typing. Logs recorded six horizontal and two vertical gestures with matching start and end phases. The reverse direction and gesture rendering on a macOS 27 destination remain unverified. The signed update feed distributes this experimental beta through the existing updater.

Diagnostics record capability flags, OS major versions, gesture phase and axis, and input role. They exclude clipboard content, key codes, pointer positions, and raw native events.

## References and license

- [Apple trackpad event handling](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html) describes system gesture precedence.
- [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher/blob/main/Sources/ISS/ISS.c) defines Dock fields and the macOS 27 terminal-event handling.
- [InstantSpaceSwitcher IOHID serialization](https://github.com/jurplel/InstantSpaceSwitcher/blob/main/Sources/ISS/event_serialize.c) defines the macOS 27 payload layout.
- [Third-party notices](../THIRD_PARTY_NOTICES.md) includes the MIT license for the adapted layout. The app bundle also includes this notice.
