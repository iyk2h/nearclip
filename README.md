# NearClip

Copy on one Mac. Paste on the other. NearClip connects two Macs on the same local network, even if they use different Apple accounts. Move the pointer across the screen edge to keep typing on the other Mac, or send a file and choose where to save it.

[**Download NearClip for Mac**](https://github.com/iyk2h/nearclip/releases/download/v0.4.4-build36/NearClip-0.4.4-build36-macOS.dmg) · [Release notes](https://github.com/iyk2h/nearclip/releases) · macOS 13 or later · Apple silicon and Intel

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
| Send a file | Click **Send File**. The recipient chooses where to save it. Send one file up to 2 GiB at a time. Compress folders first. |
| Change the language | In build 36 and later, open **Settings → Language**, choose English or Korean, then quit and reopen NearClip. English is the default. |
| Update NearClip | Choose **Check for Updates** from the menu bar on each Mac. Install the update and relaunch. |

NearClip sends data directly between paired Macs over an encrypted connection. It keeps no clipboard history. File transfers need the recipient’s approval, and input sharing needs permission on both Macs. Input sharing and [trackpad gestures](docs/GESTURES.md) are beta features.

[Troubleshooting](docs/TROUBLESHOOTING.md) · [Security](SECURITY.md) · [Validation](docs/VALIDATION.md) · [Build from source](docs/DEVELOPMENT.md) · [MIT license](LICENSE)
