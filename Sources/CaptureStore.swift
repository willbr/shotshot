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
