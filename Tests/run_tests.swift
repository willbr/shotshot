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

    let a = URL(fileURLWithPath: "/tmp/Shotshot 2026-01-01 at 00.00.00.png")
    let b = URL(fileURLWithPath: "/tmp/Shotshot 2026-01-02 at 00.00.00.png")
    check(CaptureStore.sortedNewestFirst([a, b]) == [b, a],
          "sortedNewestFirst orders newest first by filename")
}

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
    check(recent.first?.lastPathComponent == u2?.lastPathComponent,
          "recent is newest-first")

    let limited = CaptureStore.recent(limit: 1, in: tmp)
    check(limited.map { $0.lastPathComponent } == [u2?.lastPathComponent].compactMap { $0 },
          "recent respects the limit")

    let annotated = Data([1, 2, 3])
    let au = CaptureStore.saveAnnotatedCopy(of: u1!, pngData: annotated)
    check(au?.lastPathComponent == CaptureStore.annotatedName(for: u1!),
          "saveAnnotatedCopy uses the -annotated name")
    check((try? Data(contentsOf: au!)) == annotated, "annotated bytes round-trip")

    // Two captures in the same second must not overwrite each other.
    let same = makeDate(2026, 5, 31, 12, 0, 0)
    let c1 = CaptureStore.save(data, in: tmp, date: same, calendar: makeCalendar())
    let c2 = CaptureStore.save(data, in: tmp, date: same, calendar: makeCalendar())
    check(c1 != nil && c2 != nil && c1!.lastPathComponent != c2!.lastPathComponent,
          "same-second saves get distinct filenames")
}

func testAnnotationModel() {
    let a = Annotation(tool: .rectangle,
                       points: [CGPoint(x: 10, y: 20), CGPoint(x: 4, y: 8)],
                       color: .red, thickness: 3)
    check(a.boundingRect == CGRect(x: 4, y: 8, width: 6, height: 12),
          "boundingRect normalizes corner order")
}

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

    // Filled rectangle: interior pixel takes the fill color.
    let filledRect = Annotation(tool: .rectangle,
                                points: [CGPoint(x: 2, y: 2), CGPoint(x: 8, y: 8)],
                                color: .green, thickness: 2, filled: true)
    let filledImg = AnnotationRenderer.render(base: makeWhiteImage(10, 10),
                                              annotations: [filledRect], crop: nil)
    if let filledImg = filledImg, let px = samplePixel(filledImg, x: 5, y: 5) {
        check(px.g > 0.6 && px.r < 0.4, "filled rectangle interior takes the fill color")
    } else {
        check(false, "could not sample filled rectangle interior")
    }

    // Outline-only rectangle leaves its interior untouched (white).
    let outlineRect = Annotation(tool: .rectangle,
                                 points: [CGPoint(x: 2, y: 2), CGPoint(x: 8, y: 8)],
                                 color: .green, thickness: 1, filled: false)
    let outlineImg = AnnotationRenderer.render(base: makeWhiteImage(10, 10),
                                               annotations: [outlineRect], crop: nil)
    if let outlineImg = outlineImg, let px = samplePixel(outlineImg, x: 5, y: 5) {
        check(px.r > 0.8 && px.g > 0.8 && px.b > 0.8,
              "outline-only rectangle leaves its interior white")
    } else {
        check(false, "could not sample outline rectangle interior")
    }

    // Crop changes the output size.
    let cropped = AnnotationRenderer.render(base: base, annotations: [],
                                            crop: CGRect(x: 2, y: 2, width: 4, height: 4))
    check(cropped?.width == 4 && cropped?.height == 4, "render crops to the crop rect")

    // PNG encode produces non-empty data.
    let png = AnnotationRenderer.pngData(from: base)
    check((png?.count ?? 0) > 0, "pngData returns encoded bytes")
}

// === add new test calls above this line ===

testAnnotationRenderer()
testCaptureStorePure()
testCaptureStoreFilesystem()
testAnnotationModel()

if failures > 0 {
    print("\n\(failures) check(s) FAILED")
    exit(1)
} else {
    print("\nAll checks passed")
    exit(0)
}
