# Shotshot

A lightweight screenshot tool for macOS, written primarily in C.

The goal is maximum code sharing for future Windows and Linux ports.

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

- **Core**: Single C file (`core/capture.c`) using a fixed-size global arena allocator
- **PNG**: Vendored `stb_image_write.h`
- **Platform layer**: Thin Objective-C shell (mac/)
- **Build system**: `build.sh` only (no Xcode, no Makefiles)
- **Clipboard**: Approach A — platform copies bytes out, core immediately zeros the arena

## Design Constraints

- As much portable C as possible
- No malloc/free in the core (arena only)
- Single `.c` file for the capture logic
- Simple command-line build

## Permissions

Shotshot requires:
- Accessibility (for global hotkeys)
- Screen Recording (for capture)
- Input Monitoring (for global hotkeys on newer macOS)

The app will guide you to the correct System Settings panes on first run.

## Future

The long-term plan is to keep the C core as large as possible so that Windows and Linux ports can reuse the capture, encoding, and clipboard logic with minimal changes.

---

Currently a personal project / work in progress.

> Built with [Grok Build](https://x.ai).