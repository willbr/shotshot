import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var hotkeyController: HotkeyController?

    /// Called from main.swift (and also from the delegate method when launched normally).
    func setup() {
        guard statusItemController == nil else { return } // already set up
        statusItemController = StatusItemController()
        hotkeyController = HotkeyController()
        // RectSelectionController is owned by HotkeyController
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setup()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup if needed
    }
}
