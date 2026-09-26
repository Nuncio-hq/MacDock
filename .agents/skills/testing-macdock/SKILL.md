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

## Admin scan + Empty Trash (PR #7)
- "Macintosh HD (administrator)" sidebar entry triggers an `osascript "with administrator privileges"` password sheet — the box user password `devin` works; authenticated scan shows "Scanning as administrator…" with rate + ETA.
- Scan views show "X MB/s · N items/s" once data flows; ETA "~Ts left" appears only when scanning "/".
- "Empty Trash" button in the Freed banner calls `emptyTrash()` which uses `try?` on `~/.Trash` removal — if the app lacks Trash access (TCC `SystemPolicyAppData`), it silently does nothing: banner dismisses, no error, Trash untouched. Check `sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "select service,client,auth_value from access where client like '%MacDock%'"` and verify with `du -sh ~/.Trash` — the UI gives no signal either way. On a box where Trash is restricted this feature cannot be verified positively.

### Empty Trash error surfacing (cb4d073+)
- On TCC denial the app shows an orange "Couldn't read the Trash…" banner with a "Privacy Settings" button (opens System Settings → Full Disk Access) and a ✕ dismiss.
- Granting FDA under automation: the "+" picker often doesn't open. Workaround: `tccutil reset SystemPolicyAllFiles hq.nuncio.MacDock`, then `open -R` the app in Finder, drag the icon onto the FDA list, authenticate, Quit & Reopen, then killall + relaunch again (grant must exist BEFORE the process launches). Verify with `sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "select service,client,auth_value from access where client like '%MacDock%'"` → auth_value 2 = allowed.
- Even with FDA allowed, removing ~/.Trash items may still fail if items carry the `com.apple.macl` xattr (TCC per-app data ACL — visible via `ls -la@`). On this box emptyTrash() still got permission-denied post-grant; the error banner handles it gracefully. Success-path verification may need a properly-signed build or a different machine.

### Finder empty-trash fallback (37a0213+)
- If direct FileManager removal of ~/.Trash fails, the app runs `tell application "Finder" to empty trash` — first call pops a "MacDock wants access to control 'Finder'" consent; Allow empties the whole Trash including com.apple.macl-protected items (verified: 57MB → 0B).
- Note: rebuilding the adhoc binary invalidates the previous FDA grant (cdhash changes → SystemPolicyAllFiles flips back to 0). Grants must be re-done per build.

### Sparkle updates (devin/sparkle-updates)
- Footer "Updates" button runs Sparkle's `checkForUpdates` — with an empty/unreachable appcast it shows a benign "Update Error!" dialog (Cancel Update), not a crash.
- If the menubar icon is hidden by another app's menus (e.g. Simulator running fullscreen menubars), drive the panel via `osascript -e 'tell application "System Events" to tell process "MacDock" to perform action "AXPress" of menu bar item "MenuBarIcon" of menu bar 2'`.
- Verify Sparkle wiring: `ls Contents/Frameworks/Sparkle.framework` and PlistBuddy `SUFeedURL`/`SUPublicEDKey`.

### Storage Manager: interaction quirks + AX fallback (worktree build)
- Release build at `build-release/Build/Products/Release/` may need adhoc re-sign before it runs: `codesign --force --sign - Contents/Frameworks/Sparkle.framework && codesign --force --deep --sign - .` (Team ID mismatch kills launch).
- If the Storage window renders but clicks do nothing (hit-test shows the right AXCell but no action — happens after other windows steal focus), it stays wedged; either reopen via panel "Open Storage Manager" (openWindow does NSApp.activate) or drive via AX: sidebar = `outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1` (rows 2-5 = Home/HD/admin/Folder); results table = `outline 1 of scroll area 1 of group 2 of splitter group 1 of group 1`; select via `set value of attribute "AXSelected" of row N of o to true`; then ⌫/Return keys reach the window.
- FSEvents banner: while the screen recorder writes to ~/screencasts the home scan never leaves "Storage is still changing…" — to see the "changed…Refresh" flip, scan a quiet scratch dir and write into it.
- Deletion guidance is path-prefix matched (DeletionGuidance.swift): dmg/pkg/xip rules only apply inside ~/Downloads AND files only appear in Biggest files which has no guidance footer — file-type guidance is not reachable in the UI.
