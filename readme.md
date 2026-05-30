# Shotshot

A lightweight screenshot tool for macOS, written in Swift.

Built with a pure command-line workflow (no Xcode project).

## Current Status

Functional macOS menubar agent (LSUIElement).

### Working
- `⌘⇧S` — Rectangular region selection with reliable multi-monitor support
- `⌘⇧4` — Fullscreen capture of the main display
- PNG copied directly to the clipboard
- Proper permission handling (Accessibility, Screen Recording, Input Monitoring)
- Minimal menubar icon + Quit menu

### Not Yet Implemented
- Annotation tools
- Other platforms (Windows/Linux)

## Hotkeys

| Shortcut   | Action                    |
|------------|---------------------------|
| `⌘⇧S`      | Rectangular selection     |
| `⌘⇧4`      | Fullscreen capture        |

## Building & Running

```bash
./build.sh install    # Build + install to /Applications (recommended)
./build.sh debug      # Build + run with live console output
./build.sh build      # Just build
```

The `install` and `debug` targets place a properly signed copy in `/Applications` for reliable TCC permissions.

## Architecture

- **Capture**: Pure Swift (`Sources/Capture.swift`) using CoreGraphics + ImageIO for PNG encoding
- **UI / Hotkeys / Selection**: Swift AppKit layer (all under `Sources/`)
- **Build system**: `build.sh` only (no Xcode, no SPM, no Makefiles) — uses `swiftc` directly
- **Security**: Raw pixel buffers are explicitly zeroed immediately after PNG encoding

## Design Notes

- The previous C core + stb_image_write was removed in favor of a full Swift implementation.
- The sophisticated multi-monitor rectangular selection logic (per-display capture with largest-intersection heuristic, CGEventTap-driven cross-screen dragging, precise hole-punch overlay drawing) has been preserved.
- The project still builds with a single shell script and produces a properly signed `.app` bundle.

## Permissions

Shotshot requires:
- Accessibility (for global hotkeys)
- Screen Recording (for capture)
- Input Monitoring (for global hotkeys on newer macOS)

The app will guide you to the correct System Settings panes on first run.

## Future

- Annotation tools (the original goal)
- Possible future Windows/Linux ports (the previous C core made this easier; a Swift rewrite means those would need separate implementations or a new cross-platform layer)

---

Currently a personal project / work in progress.

> Built with [Grok Build](https://x.ai).