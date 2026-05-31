# Shotshot — Annotation Feature Design

**Date:** 2026-05-31
**Status:** Approved (brainstorm)

## Goal

Add image annotation to Shotshot, the original goal of the project. Two new
menubar entries drive it:

- **Annotate on screenshot** — a checkable toggle. When on, a region capture
  (`⌘⇧S`) opens the new annotation editor after capturing. Off by default
  behavior is unchanged.
- **Annotate recent screenshots** — a submenu listing recent captures; picking
  one opens it in the editor.

This requires Shotshot to start persisting captures to disk (it is currently
clipboard-only), which becomes the "recent" history.

## Scope decisions

| Decision | Choice |
|----------|--------|
| Source of "recent" | Shotshot's own saved history |
| Capture behavior | Save to disk **and** copy to clipboard (clipboard behavior preserved) |
| Save location | `~/Pictures/Shotshot` |
| "Annotate on screenshot" | Checkable toggle; auto-opens editor for **region captures only**. Fullscreen (`⌘⇧4`) never auto-opens. State persists across launches. |
| "Annotate recent screenshots" | Submenu of the last ~10 captures, newest first |
| Editor output | **Copy** to clipboard and **Save copy** (`<name>-annotated.png`); original untouched |
| Editor window | Standard resizable floating window |
| Tools (v1) | Select/move, Rectangle, Ellipse, Highlighter/freehand, Crop, color swatches, thickness slider, undo/redo |
| Out of v1 (intentional) | Arrow, Text, Blur/pixelate |

## Architecture

The existing `Sources/` AppKit layer is preserved. Two new components are added
and two existing controllers gain a small amount of wiring.

### Menu — `StatusItemController` (modified)

```
Shotshot ▾
  ✓ Annotate on screenshot       (checkable toggle)
  Annotate recent screenshots ▸  (submenu, built lazily)
      <timestamp>  <filename>
      …
  ───────────────
  Quit Shotshot
```

- The toggle reads/writes its state in `UserDefaults` (key e.g.
  `annotateOnScreenshot`). Toggling flips the menu item's `.state`.
- The submenu is rebuilt from `CaptureStore.recent(limit:)` each time the menu
  opens (via `NSMenuDelegate.menuNeedsUpdate`), so it always reflects the
  current folder. Each item's action opens that file in the editor.
- A shared application coordinator (the `AppDelegate` or a small holder) exposes
  the `CaptureStore` and a method to open the editor, so both the status item
  and the capture controllers can reach them.

### `CaptureStore` (new) — `Sources/CaptureStore.swift`

Owns the history folder and all filesystem concerns.

- `directoryURL` → `~/Pictures/Shotshot`, created on first use.
- `save(_ pngData: Data) -> URL?` — writes a timestamped PNG
  (`Shotshot YYYY-MM-DD at HH.mm.ss.png`); returns the URL or nil on failure.
- `recent(limit: Int) -> [URL]` — PNGs in the folder sorted newest-first by
  creation date.
- `saveAnnotatedCopy(of original: URL, pngData: Data) -> URL?` — writes
  `<basename>-annotated.png` next to the original.

Filename generation, recent-sorting, and the annotated-name derivation are pure
functions (no global state) so they can be unit-tested.

### `AnnotationEditor` (new) — `Sources/AnnotationEditor.swift`

A standard resizable `NSWindow` containing a top toolbar (layout B) and a canvas
view.

**Activation policy:** the app is a menubar agent (`.accessory`). When an editor
opens it sets `NSApp.setActivationPolicy(.regular)` and activates; when the last
editor window closes it returns to `.accessory`. A small counter or window-set
tracks how many editors are open.

**Data model (vector overlay; base image immutable):**

- `baseImage: CGImage` — the loaded screenshot, never mutated.
- `annotations: [Annotation]` — ordered. Each annotation is an enum/struct:
  - `.rectangle(rect, color, thickness)`
  - `.ellipse(rect, color, thickness)`
  - `.freehand(points, color, thickness)` (highlighter = translucent variant)
- `cropRect: CGRect?` — optional crop in image coordinates.
- Current tool, current color, current thickness.

**Canvas view (`NSView`):**

- Draws the (cropped) base image scaled-to-fit, then annotations on top.
- Maps between view points and image points (retina/backing-scale aware) so
  annotations are stored in image coordinates and export at native resolution.
- Mouse down/drag/up create or move annotations depending on the active tool.
- Select/move tool hit-tests existing annotations and drags them.

**Undo/redo:** backed by `NSUndoManager`. Each mutating action (add annotation,
move annotation, set crop) registers its inverse, so toolbar buttons and the
standard `⌘Z` / `⌘⇧Z` both work.

**Toolbar (layout B — single top strip):** Select/move · Rectangle · Ellipse ·
Highlighter/freehand · Crop · color swatches · thickness slider · undo · redo.
Bottom-right action bar: **Save copy** and **Copy**.

**Export / flatten:** render `baseImage` (cropped to `cropRect`) into a
`CGContext` at native pixel size, draw annotations on top, encode PNG via
ImageIO (reusing the existing PNG path in `Capture` where practical). Used by
both Copy (→ clipboard) and Save copy (→ `CaptureStore`).

### Capture paths (modified)

Both capture entry points change from "encode → clipboard" to
"encode → save to disk + clipboard", then optionally open the editor:

- `HotkeyController.takeScreenshot()` (fullscreen `⌘⇧4`): save + clipboard. Never
  auto-opens the editor.
- `RectSelectionController.handleMouseUp()` (region `⌘⇧S`): save + clipboard;
  if the `annotateOnScreenshot` toggle is on, open the editor with the saved
  image.

## Data flow

```
⌘⇧S region → Capture.rect → PNG
   → CaptureStore.save(...)         (history)
   → clipboard
   → if toggle on: AnnotationEditor.open(url)

⌘⇧4 fullscreen → Capture.fullscreen → PNG
   → CaptureStore.save(...) + clipboard   (no editor)

Menu "Annotate recent" → AnnotationEditor.open(url)

Editor "Copy"      → flatten → clipboard
Editor "Save copy" → flatten → CaptureStore.saveAnnotatedCopy(...)
```

## Error handling

- **Folder create / write failure:** log; show a brief non-blocking alert. The
  capture still reaches the clipboard, so no data is lost even if disk save
  fails.
- **Opening a missing/unreadable file** (deleted after the menu was built):
  show an alert and do not open the editor.
- **Empty / zero-size capture:** skipped, as today.
- **Editor close with unsaved annotations:** annotations are non-destructive and
  the original is always on disk; closing simply discards the overlay (no
  prompt in v1).

## Testing

No test target exists today (single `swiftc` build via `build.sh`). Keep testing
lightweight: extract pure functions — timestamped filename generation, recent
file sorting, annotated-name derivation, and the flatten/export geometry (crop +
annotation rendering into a context) — and exercise them with a small debug
self-check or minimal Swift tests. AppKit UI glue (window, toolbar wiring) stays
thin and is verified manually by running the app.

## Out of scope (v1)

- Arrow and Text tools (most common elsewhere; deliberately deferred).
- Blur / pixelate redaction.
- Overwriting the original file in place.
- Pulling from macOS system screenshots or any non-Shotshot source.
- Windows/Linux.
