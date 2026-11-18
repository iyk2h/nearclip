# NearClip walkthrough

The [40-second film](nearclip-connected.mp4?raw=true) shows the connection screen, screen arrangement, clipboard workflow, mouse and keyboard handoff, and file selection. The [GIF](nearclip-connected.gif) is the silent README preview.

## Captures and editing

NearClip build 35 and macOS TextEdit were captured on one Mac. The document and selected file contain demo text. Both display views use those captures. Display framing, cursor movement, edge indicators, timing, and transitions were added during editing.

This is a product demonstration, not simultaneous footage of two Macs or a latency benchmark. The file picker was cancelled during capture; the film does not document a completed file transfer. The captures include the existing device labels and macOS interface. They contain no pairing secrets or real clipboard content.

Build 35 was a local development build when captured. This media change does not publish that build or change the build 33 download and update feed.

## Soundtrack provenance

The soundtrack was synthesized for this film by [soundtrack.py](soundtrack.py), using Python's standard library. It combines sine waves, an original programmed note pattern, and short synthesized accents. No external song, sound recording, sample pack, or music service was used. There is no third-party music asset to attribute or license in this soundtrack.

Run `python3 soundtrack.py` to generate `soundtrack.wav` beside the script. The script checks duration, channel count, and peak amplitude. The generated WAV is not stored in this repository. macOS interface artwork and trademarks remain those of their respective owners.

## Validation

- MP4: 40 seconds, 1920 × 1080, with video and audio tracks. Frames from all six chapters decoded successfully.
- GIF: 960 × 540, 400 frames, 40 seconds. Every frame decoded successfully.
- Soundtrack: 40 seconds, stereo, 48 kHz; measured peak approximately −22.8 dBFS.
