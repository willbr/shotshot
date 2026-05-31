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
