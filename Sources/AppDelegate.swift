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
