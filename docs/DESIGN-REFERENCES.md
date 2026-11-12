# Design references

Reviewed on 2026-11-12 for NearClip 0.3.1.

The goal is a small native Mac utility: easy pairing, clear sharing state, and explicit trust. This is a review of public product pages, documentation, and official screenshots. It is not a hands-on usability study or a security audit of these products.

## Reference set

| Product and source | Evidence reviewed | Useful pattern | NearClip decision |
| --- | --- | --- | --- |
| [CrossPaste](https://crosspaste.com/en/tutorial/devices) | Device documentation and official device screenshot | Separate saved devices from nearby devices. Place actions next to device names. | Show saved peers in daily use and a visible device list during setup. |
| [LocalSend](https://localsend.org/) | Product page and desktop transfer screenshot | Clear task heading, item rows, explicit progress and cancellation. | Use plain state labels and a visible cancel action. Keep advanced connection details secondary. |
| [Maccy](https://maccy.app/) | Official page and instructions screenshot | Compact native menu with direct actions and visible shortcuts. | Keep menu-bar pause, settings, and Quit. Show the quit shortcut in the window. |
| [Paste](https://pasteapp.io/) | Official product page and hero screenshot | Strong separation between content, type, and metadata. | Separate device name from small connection metadata. Do not add history cards to a sync-only app. |
| [Raycast Clipboard History](https://www.raycast.com/core-features/clipboard-history) | Official page and clipboard screenshot | Dense, readable rows with secondary details. | Use compact device rows, restrained color, and clear text hierarchy. |
| [Alfred Clipboard History](https://www.alfredapp.com/help/features/clipboard/) | Help page and viewer screenshot | Keyboard actions and recognizable list entries. | Retain native keyboard controls. Omit a search field for a short nearby-device list. |
| [Dropover](https://dropoverapp.com/) | Product page and command-bar screenshot | Contextual actions in a small surface. | Reveal address entry and permission help only when requested. |
| [Blip](https://blip.net/) | Product page | Direct device-to-device transfer is presented as a small task. | Keep the main flow focused on the other Mac, rather than configuration. No file UI yet. |
| [PairDrop](https://github.com/schlagmichdoch/PairDrop) | Project documentation | Peer discovery and pairing are central concepts. | Keep nearby discovery as the default first-use path. Preserve numeric verification. |
| [Tailscale for macOS](https://tailscale.com/docs/install/mac) | Installation documentation | Native setup includes explicit operating-system permission steps. | Put permission help in troubleshooting. Do not turn the main screen into an installation checklist. |
| [Deskflow](https://github.com/deskflow/deskflow) | Project documentation | Mouse and keyboard sharing is a distinct capability. | Defer control-sharing configuration until that capability exists. |
| [Synergy](https://symless.com/synergy) | Product page | The product explains working across multiple computers. | Keep device identity prominent. Do not imply that NearClip currently shares a cursor. |
| [Apple Universal Control](https://support.apple.com/en-us/102459) | Support article and display-arrangement screenshot | Spatial display arrangement is useful for pointer movement. | Reserve spatial layout for a future cursor feature. It is unnecessary for clipboard pairing. |

Eight references include inspected screenshots; the other five are documentation or product-copy references. Third-party screenshots are not bundled with NearClip or redistributed in this repository. The application uses native AppKit controls and SF Symbols, not copied product assets.

## Resulting flow

1. On first use, show nearby Macs as rows with a **Connect** button.
2. Require matching six-digit confirmation on both Macs.
3. Close new-pairing discovery after pairing. Keep authenticated reconnection active.
4. In daily use, show the saved Mac, sharing state, pause/resume, and manual send.
5. Open new pairing only after **Connect another Mac**. Close that invitation after two minutes or cancellation. New pairing replaces the saved pairing only after confirmation and successful local key storage.
6. Keep address entry and network-permission help behind **Mac not visible?**.

## Design hypotheses and limits

The expected reduction in setup effort comes from removing the device picker and showing a Connect button on each row. Hiding advanced controls should reduce the number of decisions needed for ordinary use. These are design hypotheses, not measured conversion or usability results.

Discovery does not establish trust. Device names and short identifiers help locate a Mac, but the numeric comparison remains necessary. The UI never claims that installing the app alone makes another device trusted.

The macOS menu bar remains the persistent control surface. Closing the window and quitting the app have distinct, explicit behavior. The connection window supports light and dark appearance and uses text as well as icons to describe state.
