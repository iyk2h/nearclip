# NearClip

Copy on one Mac. Paste on the other. NearClip is a free, ad-free app that connects two Macs on the same local network, even if they use different Apple accounts. Move the pointer across the screen edge to keep typing on the other Mac, or send a file and choose where to save it.

[**Download NearClip for Mac**](https://github.com/iyk2h/nearclip/releases/download/v0.4.4-build52/NearClip-0.4.4-build52-macOS.dmg) · [Release notes](https://github.com/iyk2h/nearclip/releases) · macOS 13 or later · Apple silicon and Intel

![NearClip demo showing text copied between Macs, a pointer crossing the screen edge, and file selection](docs/media/nearclip-connected.gif)

*A 40-second walkthrough of the English interface. The two-screen sequence is edited.*

## Make your first connection

1. On each Mac, download and open the DMG. Drag **NearClip** into **Applications** and open it there. The beta uses a self-signed certificate. If macOS blocks it, follow the [first-launch guide](docs/TROUBLESHOOTING.md#macos-blocks-the-first-launch).
2. Connect both Macs to the same Wi-Fi or Ethernet network. Allow local network access, then click **Connect** next to the other Mac. Compare the six digits and confirm on both screens.
3. Copy fresh text or an image with **⌘C**. Press **⌘V** on the other Mac. NearClip remembers the pairing for next time.

## Work across both screens

| To… | Do this |
| --- | --- |
| Share a screenshot | Press **⌃⇧⌘4**, select an area, then paste on the other Mac. |
| Use one mouse and keyboard | Enable **Mouse & Keyboard** on both Macs and grant the requested permissions. In **Screen Layout**, drag the screens to match your desk. Push the pointer across the shared edge and type. Press **⌃⌥Esc** to stop. |
| Send a file | Click **Send File**. The recipient chooses where to save it. With build 37 or later on both Macs and input sharing enabled, you can also drag a Finder file across the shared edge and release it over a Finder folder or the desktop. Build 46 saves drops directly in Desktop, Documents, Downloads, and their ordinary subfolders. Duplicate names get a number. For other Finder destinations, choose where to save. Send one regular file up to 2 GiB at a time. |
| Drop a file into an app (build 39) | Drag a file across the shared edge and release it over a window that accepts files. Keep the pointer over the target until the file arrives. If the app declines it, drag the filename from NearClip into the app to try again. |
| Drag an image | Drag an image file or a PNG or TIFF from an app across the shared edge. NearClip starts transferring supported images up to 20 MiB while you hold the mouse. Keep dragging across the edge. The image preview follows the pointer on the other Mac. Once the image is ready, compatible apps can show their drop target while you hover. Release to attach it. Release over Finder to copy it into the destination folder. |
| Bring a file back (build 48 on both Macs) | While controlling the other Mac, drag a file back across the shared edge. Keep the button down until you reach a Finder folder or an attachment field on your Mac, then release. The original file and your clipboard stay in place. |
| Change the language | In build 36 and later, open **Settings → Language**, choose English or Korean, then quit and reopen NearClip. English is the default. |
| Update NearClip | Choose **Check for Updates** from the menu bar on each Mac. Install the update and relaunch. |

NearClip sends data directly between paired Macs over an encrypted connection. It keeps no clipboard history. Send File asks the recipient where to save. Cross-screen drops use the input-sharing permissions on both Macs. Input sharing and [trackpad gestures](docs/GESTURES.md) are beta features.

## Beta feedback

Did your first paste work? Did the Macs reconnect after sleep? [Tell us how it went](https://github.com/iyk2h/nearclip/issues/new?template=beta-feedback.yml). A sentence in English or Korean is enough.

[Troubleshooting](docs/TROUBLESHOOTING.md) · [Security](SECURITY.md) · [Validation](docs/VALIDATION.md) · [Build from source](docs/DEVELOPMENT.md) · [MIT license](LICENSE)
