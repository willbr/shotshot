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
