# MacDock — working agreements

- This is an open-source personal project. There is no V1/MVP concept: whatever ships must be usable and polished. Changes only make it better, never "good enough for now".
- Native macOS only: Swift + SwiftUI, `NSStatusItem`/`MenuBarExtra`, no Electron/Tauri.
- Architecture is modular: each utility is a `DockModule` registered in `ModuleRegistry` and individually toggleable in Settings.
- The app is an agent (`LSUIElement = YES`): no Dock icon, lives in the menubar.
- Project file is generated — run `xcodegen` and never commit `MacDock.xcodeproj`.
- Project is not sandboxed; don't add entitlements that would prevent `screencapture` or Mach APIs from working.
