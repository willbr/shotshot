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
