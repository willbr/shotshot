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

    /// Sorts capture URLs newest-first using their timestamped filenames
    /// ("Shotshot YYYY-MM-DD at HH.mm.ss.png" sorts chronologically as text).
    static func sortedNewestFirst(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

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

    /// Saves PNG data under a timestamped name in `dir`. If a file with that
    /// name already exists (two captures in the same second), a numeric suffix
    /// is added so no capture is overwritten. Returns the URL or nil.
    static func save(_ pngData: Data, in dir: URL,
                     date: Date = Date(), calendar: Calendar = .current) -> URL? {
        let name = timestampedFilename(date: date, calendar: calendar)
        let url = uniqueURL(in: dir, filename: name)
        do { try pngData.write(to: url); return url } catch { return nil }
    }

    /// Returns `dir/filename`, or `dir/<base>-N.<ext>` with the first free N ≥ 2
    /// if that name already exists.
    static func uniqueURL(in dir: URL, filename: String) -> URL {
        let fm = FileManager.default
        let candidate = dir.appendingPathComponent(filename)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        let ns = filename as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            let url = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    /// Convenience: saves into the default history directory.
    @discardableResult
    static func save(_ pngData: Data) -> URL? {
        guard let dir = directoryURL else { return nil }
        return save(pngData, in: dir)
    }

    /// Up to `limit` recent PNGs in `dir`, newest-first (by timestamped filename).
    static func recent(limit: Int, in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        let pngs = urls.filter { $0.pathExtension.lowercased() == "png" }
        return Array(sortedNewestFirst(pngs).prefix(limit))
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
}
