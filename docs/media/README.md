# NearClip walkthrough

The [40-second film](nearclip-connected.mp4?raw=true) shows the connection screen, screen arrangement, clipboard workflow, mouse and keyboard handoff, and file selection. The [GIF](nearclip-connected.gif) is the silent README preview.

## Captures and editing

The NearClip screens come from the English interface in build 36, rendered with sample connection data. The macOS TextEdit and file picker captures use demo content. Both display views were composed on one Mac. The pointer movement, edge indicators, timing, and transitions were added during editing.

The file scene ends at selection. For measured input timing, see [Input performance](../INPUT-PERFORMANCE.md).

## Soundtrack provenance

The soundtrack was synthesized for this film by [soundtrack.py](soundtrack.py), using Python's standard library. It combines sine waves, an original programmed note pattern, and short synthesized accents. No external song, sound recording, sample pack, or music service was used. There is no third-party music asset to attribute or license in this soundtrack.

Run `python3 soundtrack.py` to generate `soundtrack.wav` beside the script. The script checks duration, channel count, and peak amplitude. The generated WAV is not stored in this repository. macOS interface artwork and trademarks remain those of their respective owners.

## Validation

- MP4: 40 seconds, 1920 × 1080, with video and audio tracks. Frames from all six chapters decoded successfully.
- GIF: 960 × 540, 400 frames, 40 seconds. Every frame decoded successfully.
- Soundtrack: 40 seconds, stereo, 48 kHz; measured peak approximately −22.8 dBFS.
