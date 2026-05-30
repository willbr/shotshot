import AppKit

final class StatusItemController {
    private var statusItem: NSStatusItem?

    init() {
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            if let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Shotshot") {
                icon.isTemplate = true
                button.image = icon
                button.imagePosition = .imageOnly
            } else {
                // Fallback for older macOS
                if let icon = NSImage(named: NSImage.computerName) {
                    icon.isTemplate = true
                    button.image = icon
                    button.imagePosition = .imageOnly
                }
            }
        }

        let menu = NSMenu()

        let quitItem = NSMenuItem(title: "Quit Shotshot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
