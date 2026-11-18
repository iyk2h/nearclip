# Troubleshooting

## macOS blocks the first launch

Versions through 0.4.2 have ad-hoc signatures. Current builds have a persistent self-signed certificate. Neither has an Apple Developer ID signature or notarization. First check that you downloaded it from this repository's release page.

1. Try to open NearClip from Applications.
2. Open **System Settings → Privacy & Security**.
3. Find the NearClip warning.
4. Click **Open Anyway**.
5. Confirm **Open** in the next dialog.

These steps follow [Apple's app-opening instructions](https://support.apple.com/en-us/102445). Do not disable Gatekeeper or SIP. If an administrator manages your Mac or the option is unavailable, ask the administrator for help.

## The other Mac is not listed

1. Run NearClip 0.3 or later on both Macs.
2. Allow NearClip under **System Settings → Privacy & Security → Local Network**, if that setting is available on your macOS version.
3. If a Mac has a saved pairing, click **Change Mac** to make it available for a new pairing.
4. Click **Search Again**.
5. If discovery still fails, open **Can’t see your Mac?** on both Macs. Enter one Mac's displayed address through **Connect by Address** on the other.

Guest Wi-Fi, client isolation, some VPNs, and firewalls can block traffic between devices. Check the network policy if direct connection also fails. Use the address currently shown in the app; its pairing port can change after a restart.

## Connected, but paste does not work

1. Check that the state is **Connected**, not **Sharing paused**.
2. Copy a short line of plain text after the connection is established.
3. Paste it into a text editor on the other Mac.
4. Use **Send Now** to resend the current clipboard if needed.

NearClip skips clipboard entries marked as confidential or transient by their source app. It also skips file references and images over its limits. Transfer errors appear in the status panel.

## Mouse entry stops after switching desktops

Read the mouse-sharing status. A desktop can contain an app that enables macOS Secure Event Input. NearClip pauses input sharing while that protection is active.

1. On the Mac named in the pause message, finish protected input directly.
2. Leave the password field or return to an app that does not use secure input.
3. Wait for the pause message to clear.
4. Move the cursor to the screen edge again.

Build 30 retains your sharing choice and checks for recovery while idle. It also clears stale key state after hidden key-release events. Do not reset permissions or disable system protection for this condition.

## Connection fails after sleep or a network change

NearClip tries to reconnect after wake. If the saved address is no longer valid and discovery is blocked, pair again with the current address. The menu-bar command **Find Mac Again** restarts networking without opening new pairing.

## Mouse sharing does not start

1. Use NearClip 0.4 or later on both Macs.
2. On the main screen, turn on Mouse & Keyboard on both. Expand Screen Layout to change order or inspect permissions.
3. Allow NearClip in **System Settings → Privacy & Security → Accessibility** and **Input Monitoring**. Return to the app; it checks permissions again. Use **Check Again** if needed, then enable sharing. Arrange screens and change app options without restarting. Restart the app only if macOS requires it or granted permissions still have not taken effect.
4. Expand **Screen Layout**, then drag the monitor cards into the correct left-to-right order. Both Macs receive the layout. End remote mouse control before rearranging.
5. Push against the outer edge briefly with no mouse buttons or modifier keys held. A boundary between this Mac's own monitors does not hand off.

Press `⌃⌥Esc` to stop mouse sharing. On 0.4.3, the keyboard follows the pointer. Physical typing on the receiving Mac returns control. From build 22, the choice survives disconnection and restart for the same pairing. Re-enable sharing after pause or explicit stop. A slow network or a large clipboard frame can trigger the watchdog and return control; this behavior fails safely but can interrupt use.

## Mouse control returns immediately

NearClip ignores receiver mouse events with zero movement. Settings → Connection diagnostics shows the last return reason after control ends. Install the current build on both Macs to see the reason from either side.

Leave the receiving Mac's mouse, trackpad, and keyboard untouched. Push the controlling Mac's pointer across the configured edge. If it returns, note which Mac ended control and the reason shown. The reason distinguishes local input, the return edge, a rejected handoff, a timeout, and a send failure. It stays in memory and clears on the next handoff. This diagnostic does not record clipboard contents or input history.

The immediate-return report still requires a physical two-Mac retest. A passing automated test does not establish that Apple Universal Control caused the report.

## A Finder drag stays on the first Mac

Use build 37 or later on both Macs. Turn on **Mouse & Keyboard** on both and check that **Screen Layout** matches your desk. Drag one regular file to the shared edge. Keep the button down until the filename appears beside the pointer on the other screen, then release it over a Finder folder or the desktop. Escape cancels the drag.

If Finder does not expose a folder at the drop point, NearClip opens the normal save dialog. You can choose another destination there. The optional folder approval lasts until you pause sharing or disconnect. **Send File** also works with older versions.

## File transfer fails

Use Send File, then choose a destination on the recipient. Finder Copy does not send files automatically. Send one regular file up to 2 GiB; compress folders first. Symbolic links are not sent.

Choose a new destination name. NearClip does not replace existing files, even if the save dialog offers replacement. Use a local Mac folder if an external/network volume does not support the required safe-save operations or quarantine attributes. Keep the source file unchanged during transfer. Cancellation, disconnect, timeout, and digest failure remove the partial file during normal operation. A process crash can leave a private `.nearclip-*.part` file in the selected folder.

## Start at login does not work

Move NearClip to Applications and open it again. Check **System Settings → General → Login Items** for an approval request.

## Upgrade from 0.2

1. Quit the old NearClip on both Macs.
2. Replace both apps with version 0.3.
3. Open the new apps.

The existing pairing secret is preserved. For a new pairing, use 0.3 or later on both Macs. The new discovery and address exchange are not compatible with the 0.2 pairing flow.

## Remove NearClip

Quit the app, then move it from Applications to the Trash. To revoke the old pairing first, select **Settings → Forget Mac**. This replaces the old secret with a new random secret and removes the saved peer address.

To remove the remaining Keychain item, use Keychain Access to delete the item with service name `local.nearclip.pairing.v1`.

## Repeated Keychain password requests

A dialog naming `local.nearclip.pairing.v1` asks permission to read the saved pairing secret. Enter the Mac login Keychain password in the macOS dialog. **Always Allow** approves later access by the same trusted app; **Allow** approves the current access only. Never send your password in an issue or chat. See [Apple's Keychain access guide](https://support.apple.com/en-ge/guide/keychain-access/kyca1243/mac).

Versions through 0.4.2 used ad-hoc signatures. A persistent certificate preserved code identity in later test builds, but the local Keychain still approved each changed executable hash. Build 16 uses a stable signed `NearClipKeyStore` component to read the same pairing item. On the first launch, macOS can ask you to approve this component; check that it names the NearClip pairing item before choosing **Always Allow**. App-only updates reuse that component. A component or certificate change, or a locked login Keychain, can still require approval. NearClip does not weaken Keychain access rules or move the secret into an unprotected settings file.

## Permission switches are on after an update, but input is denied

Quit the old app and replace it in the same install location. Do not keep running an older copy from Downloads or a mounted DMG. The app ID remains `dev.nearclip.mac`; saved pairing and layout are retained.

A transition from an ad-hoc build to the fixed certificate can require one new Accessibility/Input Monitoring approval. Do not reset permissions for routine updates. If macOS still shows an obsolete approval during that transition, replace only the NearClip entry with the current app. The app does not edit the TCC database or reset permissions automatically.

## Apple clipboard or mouse sharing overlaps

NearClip's default relay protection applies to new clipboard content it receives. It uses Apple's current-host-only option. It cannot prevent another app's copies from using Universal Clipboard, retract content already shared, or block a manual re-copy. Changing this option affects future receives without rewriting your current clipboard.

To disable Apple clipboard sharing for this Mac, go to **System Settings → General → AirDrop & Handoff** (or **AirDrop & Continuity**) and turn off **Allow Handoff between this Mac and your iCloud devices**. This also affects app handoff and other Continuity features. NearClip does not toggle the system setting automatically. [Apple Handoff guide](https://support.apple.com/en-mt/102426).

Universal Control requires the same Apple Account on the participating devices. If it is also moving your pointer, open **System Settings → Displays → Advanced** and temporarily turn off **Allow your pointer and keyboard to move between any nearby Mac or iPad** while testing NearClip. This is separate from the Accessibility/Input Monitoring permission check. A permission error does not establish a Universal Control conflict. [Apple Universal Control guide](https://support.apple.com/en-gb/102459).
