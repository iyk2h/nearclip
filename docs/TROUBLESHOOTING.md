# Troubleshooting

## macOS blocks the first launch

The current beta has an ad-hoc signature. It does not have an Apple Developer ID signature or notarization. First check that you downloaded it from this repository's release page.

1. Try to open NearClip from Applications.
2. Open **System Settings → Privacy & Security**.
3. Find the NearClip warning.
4. Click **Open Anyway**.
5. Confirm **Open** in the next dialog.

These steps follow [Apple's app-opening instructions](https://support.apple.com/en-us/102445). Do not disable Gatekeeper or SIP. If an administrator manages your Mac or the option is unavailable, ask the administrator for help.

## The other Mac is not listed

1. Run NearClip 0.3 or later on both Macs.
2. Allow NearClip under **System Settings → Privacy & Security → Local Network**, if that setting is available on your macOS version.
3. If a Mac has a saved pairing, click **Connect another Mac (`다른 Mac 연결`)** to make it available for a new pairing.
4. Click **Find again (`다시 찾기`)**.
5. If discovery still fails, open **Mac not visible? (`Mac이 보이지 않나요?`)** on both Macs. Enter one Mac's displayed address through **Connect by address (`주소로 연결…`)** on the other.

Guest Wi-Fi, client isolation, some VPNs, and firewalls can block traffic between devices. Check the network policy if direct connection also fails. Use the address currently shown in the app; its pairing port can change after a restart.

## Connected, but paste does not work

1. Check that the state is **Sharing clipboard (`클립보드 공유 중`)**, not **Paused (`공유가 일시 정지됐어요`)**.
2. Copy a short line of plain text after the connection is established.
3. Paste it into a text editor on the other Mac.
4. Use **Send now (`지금 보내기`)** to resend the current clipboard if needed.

NearClip skips clipboard entries marked as confidential or transient by their source app. It also skips file references and images over its limits. Transfer errors appear in the status panel.

## Connection fails after sleep or a network change

NearClip tries to reconnect after wake. If the saved address is no longer valid and discovery is blocked, pair again with the current address. The menu-bar command **Find connection again (`연결 다시 찾기`)** restarts networking without opening new pairing.

## Mouse sharing does not start

1. Use NearClip 0.4 or later on both Macs.
2. Open Sharing (`공유`) and enable Mouse sharing (`마우스 공유 켜기`) on both.
3. Allow NearClip in **System Settings → Privacy & Security → Accessibility** and **Input Monitoring**. Return to the app and enable sharing again. A restart may be needed after changing input permissions.
4. In 0.4.1 or later, drag the monitor cards into the correct left-to-right order. Both Macs receive the layout. End remote mouse control before rearranging.
5. Push against the outer edge briefly with no mouse buttons or modifier keys held. A boundary between this Mac's own monitors does not hand off.

Press `⌃⌥Esc` to stop mouse sharing. Typing stays local and returns mouse control. Re-enable sharing after a pause, disconnect, or app restart. A slow network or a large clipboard frame can trigger the watchdog and return control; this behavior fails safely but can interrupt use.

## File transfer fails

Use Send file (`파일 보내기…`), then choose a destination on the recipient. Finder Copy does not send files automatically. Send one regular file up to 2 GiB; compress folders first. Symbolic links are not sent.

Choose a new destination name. NearClip does not replace existing files, even if the save dialog offers replacement. Use a local Mac folder if an external/network volume does not support the required safe-save operations or quarantine attributes. Keep the source file unchanged during transfer. Cancellation, disconnect, timeout, and digest failure remove the partial file during normal operation. A process crash can leave a private `.nearclip-*.part` file in the selected folder.

## Start at login does not work

Move NearClip to Applications and open it again. Check **System Settings → General → Login Items** for an approval request.

## Upgrade from 0.2

1. Quit the old NearClip on both Macs.
2. Replace both apps with version 0.3.
3. Open the new apps.

The existing pairing secret is preserved. For a new pairing, use 0.3 or later on both Macs. The new discovery and address exchange are not compatible with the 0.2 pairing flow.

## Remove NearClip

Quit the app, then move it from Applications to the Trash. To revoke the old pairing first, select **Settings (`설정`) → Forget connection (`연결 해제…`)**. This replaces the old secret with a new random secret and removes the saved peer address.

To remove the remaining Keychain item, use Keychain Access to delete the item with service name `local.nearclip.pairing.v1`.
