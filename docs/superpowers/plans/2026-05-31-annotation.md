# Annotation Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an annotation editor to Shotshot, persist every capture to `~/Pictures/Shotshot`, and add two menubar entries: a checkable "Annotate on screenshot" toggle (region captures auto-open the editor) and an "Annotate recent screenshots" submenu.

**Architecture:** Pure, AppKit-free logic (`CaptureStore`, `Annotation`, `AnnotationRenderer`) is unit-tested via a new `./build.sh test` target. AppKit UI (`AnnotationCanvasView`, `AnnotationEditorController`) is built on top and verified by building + running. The base screenshot is immutable; annotations are a vector overlay flattened on export. Undo/redo uses snapshot-based `NSUndoManager`.

**Tech Stack:** Swift + AppKit + CoreGraphics + ImageIO, compiled directly with `swiftc` via `build.sh` (no Xcode/SPM). macOS deployment target 14.0, arm64.

**Spec:** `docs/superpowers/specs/2026-05-31-annotation-design.md`

---

## File Structure

**New (pure, AppKit-free — covered by `./build.sh test`):**
- `Sources/CaptureStore.swift` — history folder I/O + pure filename/sort helpers.
- `Sources/Annotation.swift` — `RGBAColor`, `Annotation` model, hit-test, move.
- `Sources/AnnotationRenderer.swift` — view↔image coordinate math, scene drawing, flatten-to-PNG.
- `Tests/run_tests.swift` — standalone assert-based test runner.

**New (AppKit UI — verified by build + manual run):**
- `Sources/AnnotationCanvasView.swift` — flipped `NSView` canvas: draws the scene, handles mouse, owns undo.
- `Sources/AnnotationEditorController.swift` — window + top toolbar (layout B), tool/color/thickness state, Copy / Save copy, activation-policy management.
- `Sources/Settings.swift` — `UserDefaults`-backed toggle state.

**Modified:**
- `build.sh` — add a `test` target.
- `Sources/AppDelegate.swift` — `shared` accessor + `openEditor(url:)` coordinator that retains open editors.
- `Sources/StatusItemController.swift` — toggle item + recent submenu.
- `Sources/HotkeyController.swift` — fullscreen capture also saves to disk.
- `Sources/RectSelectionController.swift` — region capture saves to disk + auto-opens editor when toggle is on.
- `readme.md` — document the feature.

---

## Task 1: Test harness + `CaptureStore` pure helpers

**Files:**
- Modify: `build.sh` (add `test` target)
- Create: `Sources/CaptureStore.swift`
- Create: `Tests/run_tests.swift`

- [ ] **Step 1: Add the `test` target to `build.sh`**

Insert this case branch immediately before the `clean)` case (around `build.sh:96`):

```bash
  test)
    echo "Running unit tests..."
    mkdir -p "$BUILD_DIR"
    TEST_BIN="$BUILD_DIR/shotshot-tests"
    swiftc \
      -o "$TEST_BIN" \
      -target "arm64-apple-macos$DEPLOYMENT_TARGET" \
      -g -Onone \
      -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers \
      Sources/CaptureStore.swift \
      Tests/run_tests.swift
    "$TEST_BIN"
    ;;

```

Also update the usage line at the bottom of the file:

```bash
    echo "Usage: $0 [build|run|debug|install|test|clean]"
```

- [ ] **Step 2: Write the failing test runner**

Create `Tests/run_tests.swift`:

```swift
import Foundation
import CoreGraphics
import ImageIO

// Minimal assert-based test runner. Exits non-zero if any check fails.
var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("ok   - \(message)")
    } else {
        print("FAIL - \(message)")
        failures += 1
    }
}

func makeCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

func makeDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
    var c = DateComponents()
    c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
    return makeCalendar().date(from: c)!
}

// MARK: - CaptureStore pure helpers

func testCaptureStorePure() {
    let date = makeDate(2026, 5, 31, 14, 2, 3)
    check(CaptureStore.timestampedFilename(date: date, calendar: makeCalendar())
          == "Shotshot 2026-05-31 at 14.02.03.png",
          "timestampedFilename formats with zero-padding")

    let orig = URL(fileURLWithPath: "/tmp/Shotshot 2026-05-31 at 14.02.03.png")
    check(CaptureStore.annotatedName(for: orig)
          == "Shotshot 2026-05-31 at 14.02.03-annotated.png",
          "annotatedName appends -annotated before extension")

    let noExt = URL(fileURLWithPath: "/tmp/foo")
    check(CaptureStore.annotatedName(for: noExt) == "foo-annotated",
          "annotatedName handles missing extension")

    let a = (url: URL(fileURLWithPath: "/tmp/a.png"), date: makeDate(2026, 1, 1, 0, 0, 0))
    let b = (url: URL(fileURLWithPath: "/tmp/b.png"), date: makeDate(2026, 1, 2, 0, 0, 0))
    check(CaptureStore.sortedNewestFirst([a, b]) == [b.url, a.url],
          "sortedNewestFirst orders newest first")
}

// === add new test calls above this line ===

testCaptureStorePure()

if failures > 0 {
    print("\n\(failures) check(s) FAILED")
    exit(1)
} else {
    print("\nAll checks passed")
    exit(0)
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `./build.sh test`
Expected: FAIL — compile error, `cannot find 'CaptureStore' in scope` (the file doesn't exist yet).

- [ ] **Step 4: Create `Sources/CaptureStore.swift` with the pure helpers**

```swift
import Foundation

/// Owns the on-disk screenshot history folder (~/Pictures/Shotshot) and all
/// filesystem concerns for saving and listing captures. AppKit-free so it can
/// be unit-tested via `./build.sh test`.
enum CaptureStore {

    // MARK: - Pure helpers (unit-tested)

    /// Filename for a capture taken at `date`,
    /// e.g. "Shotshot 2026-05-31 at 14.02.03.png".
    static func timestampedFilename(date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "Shotshot %04d-%02d-%02d at %02d.%02d.%02d.png",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Derives the annotated-copy filename: "foo.png" -> "foo-annotated.png".
    static func annotatedName(for original: URL) -> String {
        let ext = original.pathExtension
        let base = original.deletingPathExtension().lastPathComponent
        return ext.isEmpty ? base + "-annotated" : base + "-annotated." + ext
    }

    /// Sorts (url, date) pairs newest-first and returns the URLs.
    static func sortedNewestFirst(_ entries: [(url: URL, date: Date)]) -> [URL] {
        entries.sorted { $0.date > $1.date }.map { $0.url }
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./build.sh test`
Expected: PASS — all four checks print `ok`, ends with "All checks passed", exit 0.

- [ ] **Step 6: Commit**

```bash
git add build.sh Sources/CaptureStore.swift Tests/run_tests.swift
git commit -m "Add test harness and CaptureStore pure helpers"
```

---

## Task 2: `CaptureStore` filesystem operations

**Files:**
- Modify: `Sources/CaptureStore.swift`
- Modify: `Tests/run_tests.swift`

- [ ] **Step 1: Write the failing test**

In `Tests/run_tests.swift`, add this function above the `// === add new test calls above this line ===` marker:

```swift
func testCaptureStoreFilesystem() {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("shotshot-test-\(UInt64(Date().timeIntervalSince1970 * 1000))")
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    let data = Data([0x89, 0x50, 0x4e, 0x47]) // not a real PNG; bytes round-trip is enough
    let d1 = makeDate(2026, 5, 31, 10, 0, 0)
    let d2 = makeDate(2026, 5, 31, 11, 0, 0)
    let u1 = CaptureStore.save(data, in: tmp, date: d1, calendar: makeCalendar())
    let u2 = CaptureStore.save(data, in: tmp, date: d2, calendar: makeCalendar())
    check(u1 != nil && u2 != nil, "save writes files and returns URLs")
    check((try? Data(contentsOf: u1!)) == data, "saved bytes round-trip")

    let recent = CaptureStore.recent(limit: 10, in: tmp)
    check(recent.count == 2, "recent lists both PNGs")
    check(recent.first == u2, "recent is newest-first")

    let limited = CaptureStore.recent(limit: 1, in: tmp)
    check(limited == [u2], "recent respects the limit")

    let annotated = Data([1, 2, 3])
    let au = CaptureStore.saveAnnotatedCopy(of: u1!, pngData: annotated)
    check(au?.lastPathComponent == CaptureStore.annotatedName(for: u1!),
          "saveAnnotatedCopy uses the -annotated name")
    check((try? Data(contentsOf: au!)) == annotated, "annotated bytes round-trip")
}
```

And add its call next to the existing call, just above the marker:

```swift
testCaptureStoreFilesystem()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./build.sh test`
Expected: FAIL — compile error, `extra argument 'in' in call` / `cannot find` for `save(_:in:date:calendar:)`, `recent(limit:in:)`, `saveAnnotatedCopy(of:pngData:)`.

- [ ] **Step 3: Add the filesystem operations to `Sources/CaptureStore.swift`**

Add these members inside the `CaptureStore` enum, after the pure helpers:

```swift
    // MARK: - Filesystem operations

    /// The history directory (~/Pictures/Shotshot), created on first access.
    /// Returns nil if it cannot be created.
    static var directoryURL: URL? {
        let fm = FileManager.default
        guard let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = pictures.appendingPathComponent("Shotshot", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { return nil }
        }
        return dir
    }

    /// Saves PNG data under a timestamped name in `dir`. Returns the URL or nil.
    static func save(_ pngData: Data, in dir: URL,
                     date: Date = Date(), calendar: Calendar = .current) -> URL? {
        let url = dir.appendingPathComponent(timestampedFilename(date: date, calendar: calendar))
        do { try pngData.write(to: url); return url } catch { return nil }
    }

    /// Convenience: saves into the default history directory.
    @discardableResult
    static func save(_ pngData: Data) -> URL? {
        guard let dir = directoryURL else { return nil }
        return save(pngData, in: dir)
    }

    /// Up to `limit` recent PNGs in `dir`, newest-first.
    static func recent(limit: Int, in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        let pngs = urls.filter { $0.pathExtension.lowercased() == "png" }
        let entries: [(url: URL, date: Date)] = pngs.map { url in
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate ?? .distantPast
            return (url, date)
        }
        return Array(sortedNewestFirst(entries).prefix(limit))
    }

    /// Convenience: lists from the default history directory.
    static func recent(limit: Int) -> [URL] {
        guard let dir = directoryURL else { return [] }
        return recent(limit: limit, in: dir)
    }

    /// Writes annotated PNG data next to `original` as "<base>-annotated.png".
    static func saveAnnotatedCopy(of original: URL, pngData: Data) -> URL? {
        let url = original.deletingLastPathComponent()
            .appendingPathComponent(annotatedName(for: original))
        do { try pngData.write(to: url); return url } catch { return nil }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./build.sh test`
Expected: PASS — new checks print `ok`, ends with "All checks passed".

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStore.swift Tests/run_tests.swift
git commit -m "Add CaptureStore filesystem operations"
```

---

## Task 3: `Annotation` model

**Files:**
- Modify: `build.sh`
- Create: `Sources/Annotation.swift`
- Modify: `Tests/run_tests.swift`

- [ ] **Step 1: Add `Annotation.swift` to the test target**

In `build.sh`, in the `test)` branch, add the source file to the `swiftc` invocation so it reads:

```bash
      Sources/CaptureStore.swift \
      Sources/Annotation.swift \
      Tests/run_tests.swift
```

- [ ] **Step 2: Write the failing test**

In `Tests/run_tests.swift`, add above the marker:

```swift
func testAnnotationModel() {
    let a = Annotation(tool: .rectangle,
                       points: [CGPoint(x: 10, y: 20), CGPoint(x: 4, y: 8)],
                       color: .red, thickness: 3)
    check(a.boundingRect == CGRect(x: 4, y: 8, width: 6, height: 12),
          "boundingRect normalizes corner order")
    check(a.hitTest(CGPoint(x: 5, y: 9), tolerance: 0), "hitTest true inside")
    check(!a.hitTest(CGPoint(x: 100, y: 100), tolerance: 0), "hitTest false outside")
    check(a.hitTest(CGPoint(x: 2, y: 8), tolerance: 3),
          "hitTest true within tolerance band")

    let moved = a.moved(byX: 5, y: -2)
    check(moved.points == [CGPoint(x: 15, y: 18), CGPoint(x: 9, y: 6)],
          "moved offsets every point")
    check(a.points == [CGPoint(x: 10, y: 20), CGPoint(x: 4, y: 8)],
          "moved leaves the original unchanged")
}
```

And add the call above the marker:

```swift
testAnnotationModel()
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `./build.sh test`
Expected: FAIL — `cannot find 'Annotation' in scope`.

- [ ] **Step 4: Create `Sources/Annotation.swift`**

```swift
import CoreGraphics
import Foundation

/// An sRGB color stored as components, with a `CGColor` bridge. AppKit-free.
struct RGBAColor: Equatable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    static let red    = RGBAColor(r: 0.89, g: 0.23, b: 0.23, a: 1)
    static let yellow = RGBAColor(r: 0.96, g: 0.77, b: 0.09, a: 1)
    static let green  = RGBAColor(r: 0.23, g: 0.81, b: 0.42, a: 1)
    static let white  = RGBAColor(r: 1,    g: 1,    b: 1,    a: 1)

    /// The swatches shown in the toolbar, in order.
    static let palette: [RGBAColor] = [.red, .yellow, .green, .white]
}

/// A single annotation drawn over the base image. Geometry is in image pixel
/// coordinates (origin top-left, y increasing downward).
struct Annotation: Equatable {
    enum Tool: Equatable {
        case rectangle
        case ellipse
        case freehand
        case highlighter
    }

    var tool: Tool
    /// rectangle/ellipse: two corner points (any order).
    /// freehand/highlighter: the polyline path.
    var points: [CGPoint]
    var color: RGBAColor
    var thickness: CGFloat

    /// Normalized bounding box of `points`.
    var boundingRect: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// True if `point` is within `tolerance` of the annotation (bounding-box test).
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        boundingRect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    /// A copy translated by (dx, dy).
    func moved(byX dx: CGFloat, y dy: CGFloat) -> Annotation {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return copy
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./build.sh test`
Expected: PASS — all checks `ok`.

- [ ] **Step 6: Commit**

```bash
git add build.sh Sources/Annotation.swift Tests/run_tests.swift
git commit -m "Add Annotation model with hit-test and move"
```

---

## Task 4: `AnnotationRenderer` — geometry + flatten

**Files:**
- Modify: `build.sh`
- Create: `Sources/AnnotationRenderer.swift`
- Modify: `Tests/run_tests.swift`

- [ ] **Step 1: Add `AnnotationRenderer.swift` to the test target**

In `build.sh`, in the `test)` branch, the source list becomes:

```bash
      Sources/CaptureStore.swift \
      Sources/Annotation.swift \
      Sources/AnnotationRenderer.swift \
      Tests/run_tests.swift
```

- [ ] **Step 2: Write the failing test**

In `Tests/run_tests.swift`, add this pixel-sampling helper and test above the marker:

```swift
// Reads the RGBA (0–1) of one pixel from a CGImage by redrawing it 1:1.
func samplePixel(_ image: CGImage, x: Int, y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
    let w = image.width, h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    // CGContext row 0 is the bottom; convert from top-left y.
    let row = h - 1 - y
    let i = (row * w + x) * 4
    return (CGFloat(buf[i]) / 255, CGFloat(buf[i+1]) / 255,
            CGFloat(buf[i+2]) / 255, CGFloat(buf[i+3]) / 255)
}

func makeWhiteImage(_ w: Int, _ h: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

func testAnnotationRenderer() {
    // Coordinate mapping: 100x50 image fit into 200x200 view -> scale 2, centered vertically.
    let frame = AnnotationRenderer.imageFrame(imageSize: CGSize(width: 100, height: 50),
                                              in: CGSize(width: 200, height: 200))
    check(frame == CGRect(x: 0, y: 50, width: 200, height: 100), "imageFrame aspect-fits centered")

    let p0 = AnnotationRenderer.viewToImage(CGPoint(x: 0, y: 50),
                imageSize: CGSize(width: 100, height: 50), viewSize: CGSize(width: 200, height: 200))
    check(p0 == CGPoint(x: 0, y: 0), "viewToImage maps frame origin to image origin")
    let p1 = AnnotationRenderer.viewToImage(CGPoint(x: 200, y: 150),
                imageSize: CGSize(width: 100, height: 50), viewSize: CGSize(width: 200, height: 200))
    check(p1 == CGPoint(x: 100, y: 50), "viewToImage maps far corner to image far corner")

    // Flatten: a red horizontal line across the middle of a 10x10 white image.
    let base = makeWhiteImage(10, 10)
    let line = Annotation(tool: .freehand,
                          points: [CGPoint(x: 0, y: 5), CGPoint(x: 9, y: 5)],
                          color: .red, thickness: 4)
    let full = AnnotationRenderer.render(base: base, annotations: [line], crop: nil)
    check(full?.width == 10 && full?.height == 10, "render returns full-size image")
    if let full = full, let px = samplePixel(full, x: 5, y: 5) {
        check(px.r > 0.6 && px.g < 0.4 && px.b < 0.4, "annotation pixel is red at the line center")
    } else {
        check(false, "could not sample rendered center pixel")
    }
    if let full = full, let corner = samplePixel(full, x: 0, y: 0) {
        check(corner.r > 0.8 && corner.g > 0.8 && corner.b > 0.8,
              "untouched corner stays white")
    } else {
        check(false, "could not sample rendered corner pixel")
    }

    // Crop changes the output size.
    let cropped = AnnotationRenderer.render(base: base, annotations: [],
                                            crop: CGRect(x: 2, y: 2, width: 4, height: 4))
    check(cropped?.width == 4 && cropped?.height == 4, "render crops to the crop rect")

    // PNG encode produces non-empty data.
    let png = AnnotationRenderer.pngData(from: base)
    check((png?.count ?? 0) > 0, "pngData returns encoded bytes")
}
```

And add the call above the marker:

```swift
testAnnotationRenderer()
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `./build.sh test`
Expected: FAIL — `cannot find 'AnnotationRenderer' in scope`.

- [ ] **Step 4: Create `Sources/AnnotationRenderer.swift`**

```swift
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

/// Coordinate mapping and flattening for annotations. Pure CoreGraphics — no
/// AppKit. The canvas view uses a flipped (y-down) coordinate space so that
/// view points and image pixels share an origin convention (top-left, y-down).
enum AnnotationRenderer {

    // MARK: - Coordinate mapping

    /// The rect (in flipped view coords) where the image is drawn, aspect-fit
    /// and centered.
    static func imageFrame(imageSize: CGSize, in viewSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / imageSize.width,
                        viewSize.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (viewSize.width - w) / 2,
                      y: (viewSize.height - h) / 2, width: w, height: h)
    }

    /// Converts a flipped (y-down) view point to image pixel coords.
    static func viewToImage(_ p: CGPoint, imageSize: CGSize, viewSize: CGSize) -> CGPoint {
        let frame = imageFrame(imageSize: imageSize, in: viewSize)
        guard frame.width > 0 else { return .zero }
        let scale = imageSize.width / frame.width
        return CGPoint(x: (p.x - frame.origin.x) * scale,
                       y: (p.y - frame.origin.y) * scale)
    }

    /// Converts an image pixel point to flipped (y-down) view coords.
    static func imageToView(_ p: CGPoint, imageSize: CGSize, viewSize: CGSize) -> CGPoint {
        let frame = imageFrame(imageSize: imageSize, in: viewSize)
        guard imageSize.width > 0 else { return .zero }
        let scale = frame.width / imageSize.width
        return CGPoint(x: frame.origin.x + p.x * scale,
                       y: frame.origin.y + p.y * scale)
    }

    // MARK: - Scene drawing

    /// Draws `base` upright and then `annotations`, all in the current y-down
    /// coordinate space (caller sets up the transform). Shared by the canvas
    /// view (on-screen) and `render` (export) so they stay WYSIWYG.
    static func drawScene(base: CGImage, annotations: [Annotation], in ctx: CGContext) {
        let w = CGFloat(base.width), h = CGFloat(base.height)
        // The surrounding space is y-down; flip again so the image draws upright.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()

        for a in annotations { drawAnnotation(a, in: ctx) }
    }

    private static func drawAnnotation(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        switch a.tool {
        case .rectangle:
            ctx.setLineWidth(a.thickness)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.stroke(a.boundingRect)
        case .ellipse:
            ctx.setLineWidth(a.thickness)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.strokeEllipse(in: a.boundingRect)
        case .freehand:
            ctx.setLineWidth(a.thickness)
            ctx.setStrokeColor(a.color.cgColor)
            strokePolyline(a.points, in: ctx)
        case .highlighter:
            // Translucent, thicker stroke for a marker effect.
            var c = a.color; c.a = 0.35
            ctx.setLineWidth(a.thickness * 2.5)
            ctx.setStrokeColor(c.cgColor)
            strokePolyline(a.points, in: ctx)
        }
        ctx.restoreGState()
    }

    private static func strokePolyline(_ points: [CGPoint], in ctx: CGContext) {
        guard let first = points.first else { return }
        ctx.move(to: first)
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
    }

    // MARK: - Flatten / export

    /// Renders `base` with `annotations` on top, optionally cropped to `crop`
    /// (image pixel coords). Returns a native-resolution CGImage.
    static func render(base: CGImage, annotations: [Annotation], crop: CGRect?) -> CGImage? {
        let w = base.width, h = base.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Establish a y-down (top-left origin) user space, then draw the scene.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        drawScene(base: base, annotations: annotations, in: ctx)

        guard let fullImage = ctx.makeImage() else { return nil }
        guard let crop = crop else { return fullImage }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let r = crop.integral.intersection(bounds)
        if r.isEmpty { return fullImage }
        return fullImage.cropping(to: r) ?? fullImage
    }

    /// Encodes a CGImage as PNG data.
    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./build.sh test`
Expected: PASS — all checks `ok`, including the red-center and white-corner pixel checks and the crop-size check.

- [ ] **Step 6: Commit**

```bash
git add build.sh Sources/AnnotationRenderer.swift Tests/run_tests.swift
git commit -m "Add AnnotationRenderer geometry, scene drawing, and flatten"
```

---

## Task 5: `AnnotationCanvasView` (AppKit)

**Files:**
- Create: `Sources/AnnotationCanvasView.swift`

This is UI; it is verified by a clean build (`./build.sh build`). It is exercised end-to-end in Task 6.

- [ ] **Step 1: Create `Sources/AnnotationCanvasView.swift`**

```swift
import AppKit
import CoreGraphics

/// A flipped (y-down) canvas that displays the base screenshot, draws the
/// annotation overlay, handles tool input, and owns snapshot-based undo.
final class AnnotationCanvasView: NSView {

    let baseImage: CGImage
    private(set) var annotations: [Annotation] = []
    private(set) var cropRect: CGRect?          // image pixel coords

    var currentTool: Annotation.Tool = .rectangle
    var currentColor: RGBAColor = .red
    var currentThickness: CGFloat = 4

    private var draft: Annotation?              // in-progress annotation while dragging
    private var draftCrop: CGRect?              // in-progress crop rect while dragging
    private var moveIndex: Int?                 // index of annotation being moved
    private var moveLast: CGPoint = .zero       // last mouse position (image coords) while moving

    private let canvasUndoManager = UndoManager()

    init(image: CGImage) {
        self.baseImage = image
        super.init(frame: NSRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { canvasUndoManager }

    private var imageSize: CGSize {
        CGSize(width: baseImage.width, height: baseImage.height)
    }

    // MARK: - Mutation with snapshot undo

    /// Applies `mutate`, registering the inverse (restore previous overlay) so
    /// that undo/redo work for adds, moves, and crops.
    private func applyChange(_ mutate: () -> Void) {
        let prevAnnotations = annotations
        let prevCrop = cropRect
        mutate()
        canvasUndoManager.registerUndo(withTarget: self) { target in
            target.applyChange {
                target.annotations = prevAnnotations
                target.cropRect = prevCrop
            }
        }
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        bounds.fill()

        let frame = AnnotationRenderer.imageFrame(imageSize: imageSize, in: bounds.size)
        guard frame.width > 0 else { return }

        var shown = annotations
        if let draft = draft { shown.append(draft) }

        ctx.saveGState()
        ctx.translateBy(x: frame.origin.x, y: frame.origin.y)
        let s = frame.width / CGFloat(baseImage.width)
        ctx.scaleBy(x: s, y: s)
        AnnotationRenderer.drawScene(base: baseImage, annotations: shown, in: ctx)
        ctx.restoreGState()

        // Crop preview: dim everything outside the (draft or committed) crop rect.
        if let crop = draftCrop ?? cropRect {
            let tl = AnnotationRenderer.imageToView(crop.origin,
                        imageSize: imageSize, viewSize: bounds.size)
            let br = AnnotationRenderer.imageToView(
                        CGPoint(x: crop.maxX, y: crop.maxY),
                        imageSize: imageSize, viewSize: bounds.size)
            let viewCrop = NSRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
            NSColor(calibratedWhite: 0, alpha: 0.45).setFill()
            for r in regionsOutside(viewCrop, within: frame) { r.fill() }
            NSColor.white.setStroke()
            NSBezierPath(rect: viewCrop).stroke()
        }
    }

    private func regionsOutside(_ inner: NSRect, within outer: NSRect) -> [NSRect] {
        [
            NSRect(x: outer.minX, y: outer.minY, width: outer.width, height: inner.minY - outer.minY),
            NSRect(x: outer.minX, y: inner.maxY, width: outer.width, height: outer.maxY - inner.maxY),
            NSRect(x: outer.minX, y: inner.minY, width: inner.minX - outer.minX, height: inner.height),
            NSRect(x: inner.maxX, y: inner.minY, width: outer.maxX - inner.maxX, height: inner.height),
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    // MARK: - Mouse handling

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return AnnotationRenderer.viewToImage(local, imageSize: imageSize, viewSize: bounds.size)
    }

    override func mouseDown(with event: NSEvent) {
        let p = imagePoint(event)
        switch currentTool {
        case .rectangle, .ellipse, .freehand, .highlighter:
            if isStrokeTool(currentTool) {
                draft = Annotation(tool: currentTool, points: [p],
                                   color: currentColor, thickness: currentThickness)
            } else {
                draft = Annotation(tool: currentTool, points: [p, p],
                                   color: currentColor, thickness: currentThickness)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        guard var d = draft else { return }
        if isStrokeTool(d.tool) {
            d.points.append(p)
        } else {
            d.points = [d.points[0], p]
        }
        draft = d
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = draft else { return }
        draft = nil
        // Ignore zero-size shapes (a click without a drag).
        if !isStrokeTool(d.tool), d.boundingRect.width < 2, d.boundingRect.height < 2 {
            needsDisplay = true
            return
        }
        applyChange { annotations.append(d) }
    }

    private func isStrokeTool(_ tool: Annotation.Tool) -> Bool {
        tool == .freehand || tool == .highlighter
    }

    // MARK: - Public actions (called by the controller)

    func setCrop(_ rect: CGRect) {
        let bounds = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
        let r = rect.integral.intersection(bounds)
        guard r.width >= 2, r.height >= 2 else { return }
        applyChange { cropRect = r }
    }

    func clearCrop() { applyChange { cropRect = nil } }

    func undo() { if canvasUndoManager.canUndo { canvasUndoManager.undo() } }
    func redo() { if canvasUndoManager.canRedo { canvasUndoManager.redo() } }

    /// Flattens the current scene (respecting crop) to a native-resolution PNG.
    func flattenedPNG() -> Data? {
        guard let image = AnnotationRenderer.render(
            base: baseImage, annotations: annotations, crop: cropRect) else { return nil }
        return AnnotationRenderer.pngData(from: image)
    }
}
```

Note: the crop tool drives `draftCrop` / `setCrop` from the controller in Task 6 (the controller switches the active tool and routes crop drags), so the canvas already exposes `setCrop`. For this task the crop tool's *drag* is handled like a rectangle draft; wiring the crop tool to call `setCrop` on mouse-up is added in Task 6 along with the toolbar that selects it.

- [ ] **Step 2: Add crop-tool drag handling to the canvas**

Replace the `mouseDown`/`mouseDragged`/`mouseUp` trio above so the crop tool tracks a `draftCrop` and commits via `setCrop`. Update `currentTool` to also allow a `.crop`-like behavior using a dedicated flag. Add this property near the other state:

```swift
    /// When true, drags define a crop rectangle instead of an annotation.
    var cropMode: Bool = false
```

And replace the three mouse methods with:

```swift
    override func mouseDown(with event: NSEvent) {
        let p = imagePoint(event)
        if cropMode {
            draftCrop = CGRect(origin: p, size: .zero)
        } else if isStrokeTool(currentTool) {
            draft = Annotation(tool: currentTool, points: [p],
                               color: currentColor, thickness: currentThickness)
        } else {
            draft = Annotation(tool: currentTool, points: [p, p],
                               color: currentColor, thickness: currentThickness)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        if cropMode, let start = draftCrop?.origin {
            draftCrop = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                               width: abs(p.x - start.x), height: abs(p.y - start.y))
        } else if var d = draft {
            if isStrokeTool(d.tool) { d.points.append(p) }
            else { d.points = [d.points[0], p] }
            draft = d
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if cropMode {
            let r = draftCrop
            draftCrop = nil
            if let r = r, r.width >= 2, r.height >= 2 { setCrop(r) }
            needsDisplay = true
            return
        }
        guard let d = draft else { return }
        draft = nil
        if !isStrokeTool(d.tool), d.boundingRect.width < 2, d.boundingRect.height < 2 {
            needsDisplay = true
            return
        }
        applyChange { annotations.append(d) }
    }
```

(The `cropMode` flag is set by the controller's Crop tool button; `draftCrop` already participates in `draw`.)

- [ ] **Step 3: Build to verify it compiles**

Run: `./build.sh build`
Expected: prints `Built build/Shotshot.app` with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnnotationCanvasView.swift
git commit -m "Add AnnotationCanvasView with tools, crop, and snapshot undo"
```

---

## Task 6: `AnnotationEditorController` (AppKit window + toolbar)

**Files:**
- Create: `Sources/AnnotationEditorController.swift`

- [ ] **Step 1: Create `Sources/AnnotationEditorController.swift`**

```swift
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Owns one annotation editor window: a top toolbar (layout B) plus the canvas.
/// Manages the app's activation policy so the menubar agent can show a real
/// window while an editor is open, then returns to `.accessory`.
final class AnnotationEditorController: NSObject, NSWindowDelegate {

    /// Number of editor windows currently open (drives activation policy).
    private static var openCount = 0

    private let window: NSWindow
    private let canvas: AnnotationCanvasView
    private let sourceURL: URL?
    private var toolButtons: [Annotation.Tool: NSButton] = [:]
    private var cropButton: NSButton?

    /// Called when the window closes so the coordinator can release this controller.
    var onClose: ((AnnotationEditorController) -> Void)?

    /// Loads `url` as a CGImage and builds the editor. Returns nil if unreadable.
    init?(imageURL url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        self.sourceURL = url
        self.canvas = AnnotationCanvasView(image: image)
        self.window = AnnotationEditorController.makeWindow(imageSize:
            CGSize(width: image.width, height: image.height))
        super.init()
        buildUI()
    }

    /// Builds an editor directly from a CGImage (used for capture-then-annotate).
    init(image: CGImage, sourceURL: URL?) {
        self.sourceURL = sourceURL
        self.canvas = AnnotationCanvasView(image: image)
        self.window = AnnotationEditorController.makeWindow(imageSize:
            CGSize(width: image.width, height: image.height))
        super.init()
        buildUI()
    }

    private static func makeWindow(imageSize: CGSize) -> NSWindow {
        // Fit the initial content to the image but cap it to a sane size.
        let maxW: CGFloat = 1100, maxH: CGFloat = 800
        let scale = min(1, min(maxW / imageSize.width, maxH / imageSize.height))
        let canvasW = max(400, imageSize.width * scale)
        let canvasH = max(300, imageSize.height * scale)
        let toolbarH: CGFloat = 44
        let actionsH: CGFloat = 48
        let content = NSRect(x: 0, y: 0, width: canvasW, height: canvasH + toolbarH + actionsH)
        let w = NSWindow(contentRect: content,
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Annotate"
        w.isReleasedWhenClosed = false
        return w
    }

    // MARK: - UI construction

    private func buildUI() {
        window.delegate = self
        guard let root = window.contentView else { return }
        root.wantsLayer = true

        let toolbarH: CGFloat = 44
        let actionsH: CGFloat = 48

        // --- Top toolbar (tools | color swatches | thickness | undo/redo) ---
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        addToolButton(to: toolbar, tool: .rectangle, title: "▭")
        addToolButton(to: toolbar, tool: .ellipse,   title: "◯")
        addToolButton(to: toolbar, tool: .freehand,  title: "✎")
        addToolButton(to: toolbar, tool: .highlighter, title: "🖍")

        let cropBtn = NSButton(title: "Crop", target: self, action: #selector(selectCrop))
        cropBtn.setButtonType(.toggle)
        cropButton = cropBtn
        toolbar.addArrangedSubview(cropBtn)

        toolbar.addArrangedSubview(makeSeparator())

        for color in RGBAColor.palette {
            toolbar.addArrangedSubview(makeColorSwatch(color))
        }

        let slider = NSSlider(value: 4, minValue: 1, maxValue: 24,
                              target: self, action: #selector(thicknessChanged(_:)))
        slider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        toolbar.addArrangedSubview(slider)

        toolbar.addArrangedSubview(makeSeparator())
        toolbar.addArrangedSubview(NSButton(title: "↶", target: self, action: #selector(undo)))
        toolbar.addArrangedSubview(NSButton(title: "↷", target: self, action: #selector(redo)))

        // --- Bottom action bar (Save copy | Copy) ---
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.alignment = .centerY
        actions.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.addArrangedSubview(NSView()) // spacer pushes buttons right
        let clearCropBtn = NSButton(title: "Reset crop", target: self, action: #selector(resetCrop))
        actions.addArrangedSubview(clearCropBtn)
        let saveBtn = NSButton(title: "Save copy", target: self, action: #selector(saveCopy))
        actions.addArrangedSubview(saveBtn)
        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyToClipboard))
        copyBtn.keyEquivalent = "\r"
        actions.addArrangedSubview(copyBtn)

        canvas.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        root.addSubview(canvas)
        root.addSubview(actions)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarH),

            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: actions.topAnchor),

            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            actions.heightAnchor.constraint(equalToConstant: actionsH),
        ])

        selectTool(.rectangle)
    }

    private func makeSeparator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 24).isActive = true
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func addToolButton(to stack: NSStackView, tool: Annotation.Tool, title: String) {
        let b = NSButton(title: title, target: self, action: #selector(toolButtonClicked(_:)))
        b.setButtonType(.pushOnPushOff)
        b.tag = toolTag(tool)
        toolButtons[tool] = b
        stack.addArrangedSubview(b)
    }

    private func toolTag(_ tool: Annotation.Tool) -> Int {
        switch tool {
        case .rectangle: return 0
        case .ellipse: return 1
        case .freehand: return 2
        case .highlighter: return 3
        }
    }

    private func toolForTag(_ tag: Int) -> Annotation.Tool {
        switch tag {
        case 1: return .ellipse
        case 2: return .freehand
        case 3: return .highlighter
        default: return .rectangle
        }
    }

    private func makeColorSwatch(_ color: RGBAColor) -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(colorClicked(_:)))
        b.wantsLayer = true
        b.isBordered = false
        b.layer?.backgroundColor = color.cgColor
        b.layer?.cornerRadius = 9
        b.widthAnchor.constraint(equalToConstant: 18).isActive = true
        b.heightAnchor.constraint(equalToConstant: 18).isActive = true
        b.identifier = NSUserInterfaceItemIdentifier(
            "\(color.r),\(color.g),\(color.b),\(color.a)")
        return b
    }

    // MARK: - Actions

    @objc private func toolButtonClicked(_ sender: NSButton) {
        selectTool(toolForTag(sender.tag))
    }

    private func selectTool(_ tool: Annotation.Tool) {
        canvas.cropMode = false
        canvas.currentTool = tool
        cropButton?.state = .off
        for (t, b) in toolButtons { b.state = (t == tool) ? .on : .off }
    }

    @objc private func selectCrop() {
        canvas.cropMode = true
        cropButton?.state = .on
        for (_, b) in toolButtons { b.state = .off }
    }

    @objc private func colorClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return }
        canvas.currentColor = RGBAColor(r: parts[0], g: parts[1], b: parts[2], a: parts[3])
    }

    @objc private func thicknessChanged(_ sender: NSSlider) {
        canvas.currentThickness = CGFloat(sender.doubleValue)
    }

    @objc private func undo() { canvas.undo() }
    @objc private func redo() { canvas.redo() }
    @objc private func resetCrop() { canvas.clearCrop() }

    @objc private func copyToClipboard() {
        guard let png = canvas.flattenedPNG() else { warn("Could not render the image."); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        pb.writeObjects([item])
    }

    @objc private func saveCopy() {
        guard let png = canvas.flattenedPNG() else { warn("Could not render the image."); return }
        let original = sourceURL
            ?? CaptureStore.directoryURL?.appendingPathComponent(
                CaptureStore.timestampedFilename(date: Date()))
        guard let original = original,
              let saved = CaptureStore.saveAnnotatedCopy(of: original, pngData: png) else {
            warn("Could not save the annotated copy.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([saved])
    }

    private func warn(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: - Presentation + lifecycle

    func showWindow() {
        AnnotationEditorController.openCount += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    func windowWillClose(_ notification: Notification) {
        AnnotationEditorController.openCount = max(0, AnnotationEditorController.openCount - 1)
        if AnnotationEditorController.openCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
        onClose?(self)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `./build.sh build`
Expected: `Built build/Shotshot.app`, no errors.

- [ ] **Step 3: Manual smoke test via a temporary debug hook**

Temporarily open an editor on launch so the UI can be exercised before the menu exists. In `Sources/AppDelegate.swift`, inside `setup()` after the existing controller setup, add (REMOVE in Step 5):

```swift
        // TEMP debug: open an editor on the first PNG in the history folder.
        if let url = CaptureStore.recent(limit: 1).first,
           let editor = AnnotationEditorController(imageURL: url) {
            self.tempEditor = editor
            editor.showWindow()
        }
```

And temporarily add a stored property to `AppDelegate`:

```swift
    var tempEditor: AnnotationEditorController?
```

If the history folder is empty, first create one image: run `./build.sh install` once, grant permissions, and take a `⌘⇧4` capture (after Task 9 this saves to disk; for now manually drop any PNG into `~/Pictures/Shotshot`, creating the folder if needed).

- [ ] **Step 4: Run and verify the editor works**

Run: `./build.sh debug`
Verify by interacting:
- Window opens showing the image.
- Each tool button (▭ ◯ ✎ 🖍) draws when you drag on the canvas; color swatches and the thickness slider change subsequent strokes.
- Crop dims outside the dragged rectangle; "Reset crop" clears it.
- ↶ / ↷ undo and redo the last change.
- "Copy" puts the flattened image on the clipboard (paste into Preview/Notes to confirm).
- "Save copy" reveals a `-annotated.png` in Finder.
- Closing the window returns the app to menubar-only (no Dock icon).

- [ ] **Step 5: Remove the temporary debug hook**

Delete the TEMP debug block and the `tempEditor` property added in Step 3 from `Sources/AppDelegate.swift`. Run `./build.sh build` again; expected `Built build/Shotshot.app`.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnnotationEditorController.swift Sources/AppDelegate.swift
git commit -m "Add AnnotationEditorController window and toolbar"
```

---

## Task 7: `Settings` + `AppDelegate` coordinator

**Files:**
- Create: `Sources/Settings.swift`
- Modify: `Sources/AppDelegate.swift`

- [ ] **Step 1: Create `Sources/Settings.swift`**

```swift
import Foundation

/// Persistent app settings backed by UserDefaults.
enum Settings {
    private static let annotateOnScreenshotKey = "annotateOnScreenshot"

    /// When true, region captures (⌘⇧S) auto-open the annotation editor.
    static var annotateOnScreenshot: Bool {
        get { UserDefaults.standard.bool(forKey: annotateOnScreenshotKey) }
        set { UserDefaults.standard.set(newValue, forKey: annotateOnScreenshotKey) }
    }
}
```

- [ ] **Step 2: Add the coordinator to `Sources/AppDelegate.swift`**

Replace the entire contents of `Sources/AppDelegate.swift` with:

```swift
import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set during setup() so menu/capture code can reach the coordinator.
    static private(set) var shared: AppDelegate?

    private var statusItemController: StatusItemController?
    private var hotkeyController: HotkeyController?
    private var editors: [AnnotationEditorController] = []

    func setup() {
        guard statusItemController == nil else { return }
        AppDelegate.shared = self
        statusItemController = StatusItemController()
        hotkeyController = HotkeyController()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setup()
    }

    func applicationWillTerminate(_ notification: Notification) {}

    // MARK: - Editor coordination

    /// Opens an editor for a file on disk. Shows an alert if it cannot be read.
    func openEditor(url: URL) {
        guard let controller = AnnotationEditorController(imageURL: url) else {
            let alert = NSAlert()
            alert.messageText = "Couldn't open that screenshot."
            alert.informativeText = url.lastPathComponent
            alert.alertStyle = .warning
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            if editors.isEmpty { NSApp.setActivationPolicy(.accessory) }
            return
        }
        present(controller)
    }

    /// Opens an editor for an in-memory image (capture-then-annotate).
    func openEditor(image: CGImage, sourceURL: URL?) {
        present(AnnotationEditorController(image: image, sourceURL: sourceURL))
    }

    private func present(_ controller: AnnotationEditorController) {
        controller.onClose = { [weak self] c in
            self?.editors.removeAll { $0 === c }
        }
        editors.append(controller)
        controller.showWindow()
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `./build.sh build`
Expected: `Built build/Shotshot.app`, no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/Settings.swift Sources/AppDelegate.swift
git commit -m "Add Settings and AppDelegate editor coordinator"
```

---

## Task 8: Menu — toggle + recent submenu

**Files:**
- Modify: `Sources/StatusItemController.swift`

- [ ] **Step 1: Replace `Sources/StatusItemController.swift`**

```swift
import AppKit

final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var recentSubmenu: NSMenu?

    override init() {
        super.init()
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            if let icon = NSImage(systemSymbolName: "camera.viewfinder",
                                  accessibilityDescription: "Shotshot") {
                icon.isTemplate = true
                button.image = icon
                button.imagePosition = .imageOnly
            } else if let icon = NSImage(named: NSImage.computerName) {
                icon.isTemplate = true
                button.image = icon
                button.imagePosition = .imageOnly
            }
        }

        let menu = NSMenu()
        menu.delegate = self

        let toggleItem = NSMenuItem(title: "Annotate on screenshot",
                                    action: #selector(toggleAnnotateOnScreenshot),
                                    keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = Settings.annotateOnScreenshot ? .on : .off
        menu.addItem(toggleItem)

        let recentItem = NSMenuItem(title: "Annotate recent screenshots",
                                    action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self
        recentItem.submenu = submenu
        recentSubmenu = submenu
        menu.addItem(recentItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Shotshot",
                                  action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === recentSubmenu {
            rebuildRecentSubmenu(menu)
        } else {
            // Keep the toggle's checkmark in sync each time the main menu opens.
            menu.items.first?.state = Settings.annotateOnScreenshot ? .on : .off
        }
    }

    private func rebuildRecentSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let recents = CaptureStore.recent(limit: 10)
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No recent screenshots", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for url in recents {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
    }

    // MARK: - Actions

    @objc private func toggleAnnotateOnScreenshot(_ sender: NSMenuItem) {
        Settings.annotateOnScreenshot.toggle()
        sender.state = Settings.annotateOnScreenshot ? .on : .off
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        AppDelegate.shared?.openEditor(url: url)
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `./build.sh build`
Expected: `Built build/Shotshot.app`, no errors.

- [ ] **Step 3: Manual test**

Run: `./build.sh install` then launch `/Applications/Shotshot.app` (grant permissions if prompted).
- Click the menubar icon: "Annotate on screenshot" toggles its checkmark and the state survives a quit + relaunch.
- "Annotate recent screenshots" lists recent PNGs from `~/Pictures/Shotshot` (or "No recent screenshots" if empty). Picking one opens the editor.

(If the folder is empty, drop a PNG into `~/Pictures/Shotshot` to verify the submenu, or proceed to Task 9 which populates it.)

- [ ] **Step 4: Commit**

```bash
git add Sources/StatusItemController.swift
git commit -m "Add annotate toggle and recent-screenshots submenu"
```

---

## Task 9: Wire capture paths to disk + auto-open

**Files:**
- Modify: `Sources/HotkeyController.swift`
- Modify: `Sources/RectSelectionController.swift`

- [ ] **Step 1: Save fullscreen captures to disk**

In `Sources/HotkeyController.swift`, in `takeScreenshot()`, after the existing clipboard write succeeds, also persist to the history folder. Replace the block starting at the clipboard write (`let pasteboard = NSPasteboard.general` … through the closing of the `if success` / `else`) with:

```swift
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        let success = pasteboard.writeObjects([item])

        if success {
            #if DEBUG
            print("Successfully wrote PNG to clipboard (\(pngData.count) bytes)")
            #endif
        } else {
            print("Failed to write PNG to clipboard")
        }

        // Persist to the history folder (fullscreen never auto-opens the editor).
        if CaptureStore.save(pngData) == nil {
            print("[capture] Failed to save fullscreen capture to disk")
        }
```

- [ ] **Step 2: Save region captures to disk and auto-open when enabled**

In `Sources/RectSelectionController.swift`, in `handleMouseUp(at:)`, replace the clipboard block (from `let pasteboard = NSPasteboard.general` to the end of the `if ok { … } else { … }`) with:

```swift
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        let ok = pasteboard.writeObjects([item])

        if ok {
            #if DEBUG
            print("[mouse] Rect capture copied to clipboard (\(pngData.count) bytes)")
            #endif
        } else {
            print("[mouse] Rect capture: failed to write to pasteboard")
        }

        // Persist to the history folder.
        let savedURL = CaptureStore.save(pngData)
        if savedURL == nil {
            print("[mouse] Failed to save region capture to disk")
        }

        // Auto-open the editor when the toggle is on.
        if Settings.annotateOnScreenshot {
            if let savedURL = savedURL {
                AppDelegate.shared?.openEditor(url: savedURL)
            } else if let cgImage = Capture.image(for: rect) {
                // Fall back to the in-memory image if the disk save failed.
                AppDelegate.shared?.openEditor(image: cgImage, sourceURL: nil)
            }
        }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `./build.sh build`
Expected: `Built build/Shotshot.app`, no errors.

- [ ] **Step 4: Manual end-to-end test**

Run: `./build.sh install` then launch `/Applications/Shotshot.app`.
- With the toggle OFF: `⌘⇧S` region capture copies to clipboard AND a new file appears in `~/Pictures/Shotshot`; the editor does NOT open.
- `⌘⇧4` fullscreen capture also writes a file; the editor never opens.
- Turn the toggle ON: `⌘⇧S` now opens the editor on the just-captured region; the file is still saved and on the clipboard.
- "Annotate recent screenshots" lists the new captures, newest first.

- [ ] **Step 5: Commit**

```bash
git add Sources/HotkeyController.swift Sources/RectSelectionController.swift
git commit -m "Persist captures to disk and auto-open editor on region capture"
```

---

## Task 10: Update the readme

**Files:**
- Modify: `readme.md`

- [ ] **Step 1: Update status and feature sections**

In `readme.md`, move annotation out of "Not Yet Implemented" and document the behavior. Under `### Working`, add:

```markdown
- Annotation editor (rectangle, ellipse, freehand, highlighter, crop, color & thickness, undo/redo)
- Every capture is saved to `~/Pictures/Shotshot` (and still copied to the clipboard)
- Menubar: "Annotate on screenshot" toggle (region captures auto-open the editor) and "Annotate recent screenshots" submenu
```

Replace the `### Not Yet Implemented` list with:

```markdown
### Not Yet Implemented
- Arrow and text annotation tools
- Blur / pixelate redaction
- Other platforms (Windows/Linux)
```

Under "Building & Running", add the test target:

```markdown
./build.sh test       # Run the unit tests (pure logic)
```

- [ ] **Step 2: Verify tests still pass and the app builds**

Run: `./build.sh test && ./build.sh build`
Expected: "All checks passed" then "Built build/Shotshot.app".

- [ ] **Step 3: Commit**

```bash
git add readme.md
git commit -m "Document annotation feature in readme"
```

---

## Self-Review Notes

- **Spec coverage:** menu toggle (Task 8) · recent submenu (Task 8) · save to `~/Pictures/Shotshot` + clipboard (Task 9) · region-only auto-open (Task 9) · editor window + layout B toolbar (Task 6) · tools rectangle/ellipse/freehand/highlighter/crop (Tasks 5–6) · color + thickness (Task 6) · undo/redo (Task 5) · Copy + Save copy, original untouched (Tasks 5–6) · vector overlay / immutable base (Tasks 4–5) · activation policy (Task 6) · error handling for unreadable files & failed saves (Tasks 7, 9) · lightweight tests for pure logic (Tasks 1–4). Arrow/Text/Blur explicitly out of scope.
- **Type consistency:** `Annotation`, `Annotation.Tool`, `RGBAColor`, `CaptureStore.save/recent/saveAnnotatedCopy`, `AnnotationRenderer.render/pngData/imageFrame/viewToImage/imageToView/drawScene`, `AnnotationCanvasView.flattenedPNG/setCrop/clearCrop/undo/redo/cropMode`, `AnnotationEditorController(imageURL:)`/`(image:sourceURL:)`, `AppDelegate.shared/openEditor`, `Settings.annotateOnScreenshot` are used consistently across tasks.
