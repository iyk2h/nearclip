# Trackpad swipe development build (24)

Build 23 adds experimental forwarding of horizontal and vertical Dock swipes. These are the macOS gestures for Spaces, Mission Control, and App Exposé. It forwards continuous progress and end/cancel phases. It does not replace a swipe with a fixed keyboard shortcut.

Both peers must advertise `dock-swipe-v1`. Mouse sharing must be enabled on both peers, and a pointer handoff must be accepted before any gesture is sent. The source Mac recognizes three- or four-finger swipes according to its trackpad settings. NearClip does not change either Mac's settings. The destination handles the resulting Dock gesture; this is not a copy of its finger-count preferences. Pinch, rotation, and arbitrary touch contacts are excluded.

## Implementation limits

Apple does not expose a public API for forwarding these system gestures. The adapter isolates undocumented type 30/subtype 23 fields. It advertises support only on macOS 13–26. This range is a compatibility gate, not a claim of physical testing on every version. Unknown OS generations leave gestures local. The implementation sends a bounded typed packet, never an opaque native event or arbitrary field list.

An authenticated session token, current receiving role, both input opt-ins, and the negotiated capability are required. Secure Event Input stops control. A disconnect, timeout, lock, pause, or handoff end cancels an active received gesture. Events carry the existing input marker to prevent feedback.

Build 24 suppresses duplicate starts during a remote swipe. If a received swipe makes no progress for eight seconds, control ends and the native swipe is cancelled, even while connection heartbeats continue. Expanded mouse controls show whether the peer supports this beta feature.

## Validation

Tests construct native events without posting them. They cover the codec, native field round trip, phase ordering, stale tokens, unknown senders, terminal cancellation, invalid values, and legacy fallback. A local encrypted TCP test checks capability negotiation and delivery through the separate input connection.

Physical four-finger capture, suppression of the source Mac's Dock animation, and the destination's animation remain unverified. Do not treat this development build as a verified system-gesture release. The public update feed remains on build 22 until these behaviors are checked.

## References

- [Apple: Handling Trackpad Events](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html): system-wide gestures take precedence over ordinary app handlers.
- [InstantSpaceSwitcher event definitions](https://github.com/jurplel/InstantSpaceSwitcher/blob/main/Sources/ISS/ISS.c): Dock event type, subtype, phase, progress, and axis field definitions.
- [dockswipe](https://github.com/oomol-lab/dockswipe): independent implementation documents the companion marker and legacy Dock event field layout.

The NearClip adapter uses those field definitions with its own typed transport and session state. It does not vendor either project or use private multitouch device access.
