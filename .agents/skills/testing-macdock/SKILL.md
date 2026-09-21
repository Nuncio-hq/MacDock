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

## Storage Manager window
- Monitor tab → click the "Disk Analyzer" row to expand it → "Open Storage Manager" link opens the 960×640 "MacDock Storage" window. It may open behind other windows after TCC prompts steal focus — click its title bar to refocus.
- First Home Folder scan fires a chain of TCC prompts mid-scan: "data from other apps", Desktop, Downloads, Documents, Photos Library (Allow Full Access), Apple Music/media library. Click Allow on each; the scan continues. Some hiding spots show "restricted" if access is denied — that's correct behavior.
- Drill-down: double-click a table row; "< Back" returns. Single-click a row reveals the footer action bar (Reveal in Finder / Drill down / Move to Trash); right-click shows the same context menu. "Reveal in Finder" opens Finder with the item selected.

## Staged delete collector
- Current design (commit a72bc4a+): dragging rows into the dashed bar only HOLDS items (chips + total bytes, "Put back" and red "Delete (n)" buttons). Nothing deletes until Delete is pressed; Delete plays a ~1.4s garbage-truck (🚚) animation then trashes. Put back plays a fly-back animation and restores.
- Drags can be done with computer-use mouse_down/mouse_move/mouse_up or a `swift -e` CGEvent script (no pyobjc/cliclick on the box). ~30% of drops silently miss the bar — screenshot to confirm the chip appeared.
- Chip ✕ hitbox is tiny (~8×8 px real = ~5 scaled px): scaled coords ~(429,550). If clicks miss, hit-test with `AXUIElementCopyElementAtPosition` (screen is 1600×1200 real; tool coords are 1024×768 — multiply by 1.5625) then click its exact center.
- Verify delete vs restore by `ls`-ing the scanned dir and `~/.Trash` — the bar clears in both cases so visuals alone are ambiguous.
- The results table lists directories only; plain files don't appear as rows (treemap shows files). Scan a scratch dir (create with dd'd files) via sidebar "Folder…" + Cmd+Shift+G in the NSOpenPanel.
- Context-menu and footer "Move to Trash" also stage into the collector (not instant delete).

## Other
- Footer "Preferences" opens a 380x200 Settings window with 3 @AppStorage module toggles (all default ON; persisted across launches).
- "Quit" terminates the app; verify with `pgrep -x MacDock`. Relaunch with `open build/Build/Products/Debug/MacDock.app` to leave the environment as found.
- Captured screenshots are written to `~/Pictures/MacDock/` — clean up or note them; they pollute nothing else.
