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
}

// === add new test calls above this line ===

testCaptureStorePure()
testCaptureStoreFilesystem()

if failures > 0 {
    print("\n\(failures) check(s) FAILED")
    exit(1)
} else {
    print("\nAll checks passed")
    exit(0)
}
