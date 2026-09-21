# MacDock

A modular macOS menubar utility — system monitor, clipboard history, screenshots, and more. All-in-one, native, open source.

![icon](docs/icon-dark.png)

## Modules

- **Monitor** — live CPU, memory, disk, and network throughput in a compact panel.
- **Clipboard** — persistent searchable history, pinning, paste-as-plain-text.
- **Screenshot** — area/window/fullscreen capture to clipboard or `~/Pictures/MacDock`.

Each module can be toggled on or off in Settings.

## Requirements

- macOS 15+
- Xcode 26+ and [XcodeGen](https://github.com/yonsm/XcodeGen) (`brew install xcodegen`)

## Build & Run

```sh
xcodegen            # generates MacDock.xcodeproj
make build          # or: xcodebuild -scheme MacDock build
make run            # builds and launches the app (menubar only, no Dock icon)
```

## Philosophy

Every change that lands must leave the app in a genuinely usable state — no MVP, no placeholder versions; only better.

## License

MIT
