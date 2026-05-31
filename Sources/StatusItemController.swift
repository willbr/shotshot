import AppKit

final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var recentSubmenu: NSMenu?

    override init() {
        super.init()
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            if let icon = NSImage(systemSymbolName: "camera.viewfinder",
                                  accessibilityDescription: "Shotshot") {
                icon.isTemplate = true
                button.image = icon
                button.imagePosition = .imageOnly
            } else if let icon = NSImage(named: NSImage.computerName) {
                icon.isTemplate = true
                button.image = icon
                button.imagePosition = .imageOnly
            }
        }

        let menu = NSMenu()
        menu.delegate = self

        let toggleItem = NSMenuItem(title: "Annotate on screenshot",
                                    action: #selector(toggleAnnotateOnScreenshot),
                                    keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = Settings.annotateOnScreenshot ? .on : .off
        menu.addItem(toggleItem)

        let recentItem = NSMenuItem(title: "Annotate recent screenshots",
                                    action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self
        recentItem.submenu = submenu
        recentSubmenu = submenu
        menu.addItem(recentItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Shotshot",
                                  action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === recentSubmenu {
            rebuildRecentSubmenu(menu)
        } else {
            // Keep the toggle's checkmark in sync each time the main menu opens.
            menu.items.first?.state = Settings.annotateOnScreenshot ? .on : .off
        }
    }

    private func rebuildRecentSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let recents = CaptureStore.recent(limit: 10)
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No recent screenshots", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for url in recents {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
    }

    // MARK: - Actions

    @objc private func toggleAnnotateOnScreenshot(_ sender: NSMenuItem) {
        Settings.annotateOnScreenshot.toggle()
        sender.state = Settings.annotateOnScreenshot ? .on : .off
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        AppDelegate.shared?.openEditor(url: url)
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
