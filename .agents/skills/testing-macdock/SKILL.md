---
name: testing-macdock
description: How to drive and verify the MacDock SwiftUI menubar app end-to-end (icon location, permission quirks, clipboard timing).
---

# Testing MacDock (SwiftUI menubar app)

MacDock is an LSUIElement agent: no Dock icon, no windows except the menubar panel and Settings.

## Locating the menubar icon
- The rail+bars menubar icon sits at approximately **x=857, y=8** in 1024x768 screenshot coords (just left of Spotlight). Menubar-icon clicks can be slow to register — click once, wait ~1s, screenshot, then retry the same coordinate before concluding failure. The panel is 360x460 anchored under the icon.

## Clipboard module timing
- `ClipboardStore.start()` runs in `onAppear` of `ClipboardView` and `lastChangeCount` snapshots at store init. **Text copied via `pbcopy` before the Clipboard tab has ever been shown in this app run will be missed.** To test history: open the Clipboard tab first, then `echo -n "sentinel" | pbcopy`, then verify the row appears (~0.5s poll). Clicking a row writes it back to NSPasteboard — verify with `pbpaste`.

## Screen Recording permission
- Non-interactive captures (`screencapture -x`, i.e. "Full Screen → File") trigger the macOS Screen Recording prompt. Grant it: prompt → Open System Settings → toggle MacDock ON (admin password required; on Devin boxes the user password is typically `devin`) → Quit & Reopen, or `kill <pid>` + `open MacDock.app`.
- The Debug build is **adhoc-signed**, so clicking "Deny" on the prompt revokes the grant and the prompt reappears on the next non-interactive capture. Never click Deny if you want captures to succeed.
- Interactive capture (`screencapture -i`, "Area → Clipboard") shows a crosshair regardless; screenshots don't capture the cursor, so verify with `pgrep -fl screencapture` (should list the running `-i` process), then Esc cancels.
- Successful file captures land in `~/Pictures/MacDock/MacDock-<yyyy-MM-dd-HHmmss>.png` and the panel shows a "Last capture" row.

## Other
- Footer "Preferences" opens a 380x200 Settings window with 3 @AppStorage module toggles (all default ON; persisted across launches).
- "Quit" terminates the app; verify with `pgrep -x MacDock`. Relaunch with `open build/Build/Products/Debug/MacDock.app` to leave the environment as found.
- Captured screenshots are written to `~/Pictures/MacDock/` — clean up or note them; they pollute nothing else.
